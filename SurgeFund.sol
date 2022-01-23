//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./SafeMath.sol";
import "./Address.sol";
import "./IERC20.sol";
import "./ReentrantGuard.sol";
import "./IUniswapV2Router02.sol";
import "./ISurgeFund.sol";
import "./ISurge.sol";

contract SurgeFund is ReentrancyGuard, IERC20 {
    
    using SafeMath for uint256;
    using Address for address;
    
    // PCS Router
    IUniswapV2Router02 router;

    // initial amount of BNB needed to pay back
    uint256 public initialPaybackAmount = 5850000 * 10**18;

    // Total Amount of USD Needed To Give Back
    uint256 public totalShares;

    // cost of BNB + 10% at the time of hack
    uint256 public constant BNB_PRICE_PLUS_TEN_PERCENT = 455;

    // victim structure
    struct Victim {
        uint256 bracket;
        uint256 lastClaim;
        uint256 totalToClaim;
        uint256 totalExcluded;
    }

    // Victims
    mapping ( address => Victim ) public victims;
    mapping ( address => bool ) functionCaller;
    mapping ( address => address ) surgeToUnderlying;
    address[] surges;

    struct Bracket {
        uint256 lowerBound;
        uint256 upperBound;
        uint256 ratio;
        uint256 dividendPerShare;
        uint256 totalSharesPerBracket;
        uint256 nVictims;
    }
    mapping ( uint256 => Bracket ) public brackets;
    uint256 constant nBrackets = 5; 
    
    // Total Dividends Per Share
    uint256 dividends;
    uint256 precision = 10**18;

    // minimum claim $1
    uint256 public minimumClaim = 10**18;

    // LOCKS Certain Functions
    bool public isLocked = false;
    address public owner;

    modifier onlyOwner() {require(msg.sender == owner, 'Only Owner'); _;}
    modifier onlyCaller() {require(functionCaller[msg.sender], 'Only Function Caller'); _;}
    modifier notLocked() { require(!isLocked, 'Function Is Locked'); _; }

    bool receiveDisabled;

    ISurgeFund oldFund = ISurgeFund(0x8078380508c16C9F122D62771714701612Eb3fa8);
    
    constructor() {
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        owner = msg.sender;
        functionCaller[msg.sender] = true;

        _addSurgeToken(0xb68c9D9BD82BdF4EeEcB22CAa7F3Ab94393108a1, 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
        _addSurgeToken(0xbF6bB9b8004942DFb3C1cDE3Cb950AF78ab8A5AF, 0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47);
        _addSurgeToken(0x254246331cacbC0b2ea12bEF6632E4C6075f60e2, 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

        _initBrackets();
    }

    function _initBrackets() {
        brackets[0] = Bracket({
            lowerBound: 0,
            upperBound: 10**17,
            ratio: 25,
        });
        brackets[1] = Bracket({
            lowerBound: 10**17,
            upperBound: 10**18,
            ratio: 30
        });
        brackets[2] = Bracket({
            lowerBound: 10**18,
            upperBound: 5 * 10**18,
            ratio: 20
        });
        brackets[3] = Bracket({
            lowerBound: 5 * 10**18,
            upperBound: 25 * 10**18,
            ratio: 15
        });
        brackets[4] = Bracket({
            lowerBound: 25 * 10**18,
            upperBound: 25000 * 10**18,
            ratio: 10
        });
    }

    function totalSupply() external view override returns (uint256) { return totalShares; }
    function balanceOf(address account) public view override returns (uint256) { return usersCurrentClaim(account); }
    function allowance(address holder, address spender) external pure override returns (uint256) { return holder == spender ? 0 : 1; }
    
    function name() public pure override returns (string memory) {
        return "SurgeFund";
    }

    function symbol() public pure override returns (string memory) {
        return "SurgeFund";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function approve(address spender, uint256 amount) public view override returns (bool) {
        return spender != msg.sender && amount > 0;
    }
  
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _claim(recipient);
        return recipient == msg.sender || amount > 0;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external pure override returns (bool) {
        return sender != recipient || amount > 0;
    }


    // CONTROL FUNCTIONS

    function transferOwnership(address newOwner) external notLocked onlyOwner {
        owner = newOwner;
        emit TransferOwnership(newOwner);
    }

    function setMinimumClaim(uint256 minClaim) external notLocked onlyOwner {
        minimumClaim = minClaim;
    }

    function setFunctionCaller(address user, bool isCaller) external notLocked onlyOwner {
        functionCaller[user] = isCaller;
    }

    function addSurgeToken(address token, address underlying) external onlyOwner {
        _addSurgeToken(token, underlying);
    }

    /** Adds Victims To The Fund, Cannot Be Accessed If Function is Locked */
    function pullVictims(address[] calldata _victims) external notLocked onlyOwner {
        for (uint i = 0; i < _victims.length; i++) {

            uint256 claim_ = oldFund.remainingBnbToClaimForVictim(_victims[i]);
            if (claim_ > 0 && victims[_victims[i]].totalToClaim == 0) {
                addVictim(_victims[i], claim_);
            }
        }
    }

    function migrateVictim(address old, address newVictim) external notLocked onlyOwner {
        require(victims[newVictim].totalToClaim == 0, 'NewVictim Already Victim');
        require(victims[old].totalToClaim > 0, 'Old Victim Not A Victim');

        victims[newVictim].totalToClaim = victims[old].totalToClaim;
        victims[newVictim].totalExcluded = victims[old].totalExcluded;
        victims[newVictim].bracket = victims[old].bracket;

        delete victims[old];
        emit Transfer(old, newVictim, victims[newVictim].totalToClaim);
    }

    function adjustVictim(address victim, uint256 newClaim) external notLocked onlyOwner {

        uint256 previousClaim = victims[victim].totalToClaim;
        uint256 pending = usersCurrentClaim(victim);
        totalShares = totalShares.add(newClaim).sub(previousClaim);

        victims[victim].totalToClaim = newClaim;

        if (pending > 0) {
            _distributeShares(pending);
        }

        victims[victim].totalExcluded = currentDividends(victims[victim].bracket, newClaim);

        if (previousClaim > newClaim) {
            emit Transfer(victim, address(0), (previousClaim - newClaim));
        } else {
            emit Transfer(address(0), victim, (newClaim - previousClaim));
        }

    }
    
    /** Locks Out Specific Functions From Being Called */
    function LockTheContract() external locked onlyOwner {
        isLocked = true;
        emit LockedContract(block.timestamp, block.number);
    }

    function sellAllTokenForBNB(address token) external onlyCaller {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, 'cannot sell zero tokens');
        _sellTokenForBNB(token, tokenBalance);
    }
    
    function sellAllTokenForBNBSupportingFees(address token) external onlyCaller {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, 'cannot sell zero tokens');
        _sellTokenForBNBSupportingTransferFees(token, tokenBalance);
    }
    
    function sellTokenForBNB(address token, uint256 tokenBalance) external onlyCaller {
        require(tokenBalance > 0 && tokenBalance <= IERC20(token).balanceOf(address(this)), 'invalid token amount');
        _sellTokenForBNB(token, tokenBalance);
    }
    
    function sellTokenForBNBSupportingFees(address token, uint256 tokenBalance) external onlyCaller {
        require(tokenBalance > 0 && tokenBalance <= IERC20(token).balanceOf(address(this)), 'invalid token amount');
        _sellTokenForBNBSupportingTransferFees(token, tokenBalance);
    }

    function sellSurgeTokenForBNB(address surgetoken) external onlyCaller {

        address underlying = surgeToUnderlying[surgetoken];
        require(underlying != address(0), 'Zero Underlying');

        _sellSurgeTokenForBNB(surgetoken, underlying);
    }

    function sellSurgeTokenForBNB(address surgetoken, address underlying) external onlyCaller {
        _sellSurgeTokenForBNB(surgetoken, underlying);
    }

    function sellAllSurgesForBNB() external onlyCaller {
        for (uint i = 0; i < surges.length; i++) {
            _sellSurgeTokenForBNB(surges[i], surgeToUnderlying[surges[i]]);
        }
    }

    /** Sells Surge Tokens For Their Underlying Asset To Be Converted Into BNB */
    function sellSurgeTokenForUnderlyingAsset(address surgeToken) external onlyCaller {
        require(surgeToken != SBNB, 'Call SellSurgeBNB() function specifically');
        uint256 bal = IERC20(surgeToken).balanceOf(address(this));
        if (bal > 0) {
            ISurge(payable(surgeToken)).sell(bal);
        }
    }
    
    /** Sets The SurgeBNB Contract Address */
    function setSurgeBNBAddress(address _sbnb) external onlyOwner {
        require(SBNB == address(0), 'SBNB already set');
        SBNB = _sbnb;
        emit SetSurgeBNBAddress(_sbnb);
    }
    
    /** In The Case Of A Fund Migration (due to error) Migrates Funds To Another Fund, CANNOT be Called If Locked */
    function migrateToNewFundIfUnlocked(bool migrateBNB, address token, address recipient) external locked onlyOwner {
        bool success;
        uint256 amount = migrateBNB ? address(this).balance : IERC20(token).balanceOf(address(this));
        // migrate bnb or tokens to new fund
        if (migrateBNB) {
            (success,) = payable(recipient).call{value: amount}("");
            require(success);
        } else {
            (success) = IERC20(token).transfer(recipient, amount);
            // ensure migration worked
            require(success, 'Withdrawal Failed');
        }

        // tell blockchain
        emit FundMigration(migrateBNB, amount, token, recipient);
    }

    
    /** Opts Out Of Surge Fund Rewards */
    function optOut(uint256 percent) external nonReentrant {
        require(victims[msg.sender].totalToClaim > 0, 'No Funds To Opt Out');
        require(percent <= 100 && percent > 0, 'Invalid Percent');

        // quantity user could have claimed
        uint256 donation = victims[msg.sender].totalToClaim.mul(percent).div(100);

        // pending rewards for user
        uint256 pending = usersCurrentClaim(msg.sender);

        // decrement total shares
        totalShares = totalShares.sub(donation);

        if (percent == 100) {
            // delete struct
            delete victims[msg.sender];

            if (pending > 0 && totalShares > 0) {
                _distributeShares(pending);
            }

        } else {
            victims[msg.sender].totalToClaim -= donation;

            if (pending > 0 && totalShares > 0) {
                _distributeShares(pending);
            }

            victims[msg.sender].totalExcluded = currentDividends(victims[msg.sender].bracket, victims[msg.sender].totalToClaim);
        }
        emit Transfer(msg.sender, address(0), donation);
        // check brackets
        _checkBrackets();
        // Tell Blockchain
        emit OptOut(msg.sender, donation);
    }

    function claim() external nonReentrant {
        _claim(msg.sender);
    }

    /** Claims Holdings Specific User Has Access To */
    function _claim(address user) internal {

        // Amount of BNB Sender Can Claim
        uint256 toClaim = usersCurrentClaim(user);

        // Make Sure We Sender Can Claim 
        require(victims[user].totalToClaim > 0, 'No Claims To Make');
        // Make Sure Enough Time Has Passed
        require(victims[user].lastClaim < block.number, 'Same Block Entry');
        // Make Sure We Can Claim Above The Minimum Amount
        require(toClaim >= minimumClaim, 'Below Minimum Claim');

        // update claim block
        victims[user].lastClaim = block.number;

        if (toClaim > victims[user].totalToClaim) {
            // only claim total amount, reflect the rest
            uint256 prevClaim = victims[user].totalToClaim;

            // amount to reflect
            uint256 diff = toClaim - prevClaim;

            // subtract from total shares
            totalShares = totalShares.sub(prevClaim);

            // subtract from brackets shares
            brackets[victims[user].bracket].totalSharesPerBracket = brackets[victims[user].bracket].totalSharesPerBracket.sub(prevClaim);

            if (totalShares > 0) {
                // distribute difference
                _distributeShares(diff);
            }

            // delete victims mapping
            delete victims[user];
            
            // update claim amount
            toClaim = prevClaim;
        
        } else {

            // Subtract Claim Amount From Sender
            victims[user].totalToClaim = victims[user].totalToClaim.sub(toClaim, 'subtraction underflow on victim claims');
            totalShares = totalShares.sub(toClaim);
            brackets[victims[user].bracket].totalSharesPerBracket = brackets[victims[user].bracket].totalSharesPerBracket.sub(toClaim);

            // Remove Rest Of Claim If Below Minimum
            if (victims[user].totalToClaim < minimumClaim) {
            
                uint256 remainingClaim = victims[user].totalToClaim;
                if (remainingClaim > 0) {
                    toClaim += remainingClaim;
                    victims[user].totalToClaim = victims[user].totalToClaim.sub(toClaim, 'subtraction underflow on victim claims');
                    totalShares = totalShares.sub(remainingClaim);
                    brackets[victims[user].bracket].totalSharesPerBracket = brackets[victims[user].bracket].totalSharesPerBracket.sub(remainingClaim);
                }      
            }

            // update excluded rewards
            victims[user].totalExcluded = currentDividends(victims[user].bracket, victims[user].totalToClaim);
        }

        // Send BUSD To Victim
        bool successful = IERC20(busd).transfer(user, toClaim);
        require(successful, 'BNB Transfer Failed');

        // check brackets
        _checkBrackets();

        emit Transfer(user, address(0), toClaim);
        // Tell Blockchain
        emit Claim(user, toClaim);
    }
    
    /** Adds Victim To The List Of Victims If Contract Is Unlocked */
    function addVictim(address victim, uint256 victimClaim) private {
        
        if (victims[victim].totalToClaim > 0 || victimClaim == 0) {
            return;
        }

        uint256 valOfClaim = victimClaim * BNB_PRICE_PLUS_TEN_PERCENT;

        for (uint i = 0; i < nBrackets; i++) {
            if (victimClaim >= brackets[i].lowerBound &&
                victimClaim < brackets[i].upperBound) {
                    victims[victim].bracket = i;
                    brackets[i].nVictims++;
                    brackets[i].totalSharesPerBracket += valOfClaim;
                    break;
                }
        }

        totalShares = totalShares.add(valOfClaim);

        victims[victim].totalToClaim = valOfClaim;
        victims[victim].totalExcluded = currentDividends(valOfClaim);
        emit Transfer(address(0), victim, valOfClaim);
    }
    
    /** How Much BNB This User Has Left To Claim */
    function USDToClaimForVictim(address victim) external view returns (uint256) {
        return victims[victim].totalToClaim;
    }

    /** If Sender Has BNB Left To Claim */
    function isVictim(address user) external view returns (bool) {
        return victims[user].totalToClaim > 0;
    }

     function _addSurgeToken(address token, address underlying) internal {
        surgeToUnderlying[token] = underlying;
        surges.push(token);
    }

    function _sellSurgeTokenForBNB(address surgeToken, address underlyingAsset) internal {
        require(surgeToken != SBNB, 'Call SellSurgeBNB() function specifically');
        uint256 bal = IERC20(surgeToken).balanceOf(address(this));
        if (bal > 0) {
            ISurge(payable(surgeToken)).sell(bal);
        }
        uint256 tokenBalance = IERC20(underlyingAsset).balanceOf(address(this));
        _sellTokenForBNBSupportingTransferFees(underlyingAsset, tokenBalance);
    }
    
    /** Sell Donation Tokens For BNB */
    function _sellTokenForBNB(address token, uint256 tokenBalance) private {
        // path from TOKEN -> BNB
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = router.WETH();
        // bnb balance before swap
        uint256 before = address(this).balance;
        // approve router
        IERC20(token).approve(address(router), tokenBalance);

        receiveDisabled = true;

        // make the swap
        router.swapExactTokensForETH(
            tokenBalance,
            0,
            path,
            address(this),
            block.timestamp.add(30)
        );
        // how much BNB received from swap
        uint256 bnbAdded = address(this).balance - before;

        receiveDisabled = false;
        if (totalShares > 0) {
            _distributeShares(bnbAdded);
        }
    }
    
    /** Sell Donation Tokens For BNB If Token Has Transfer Fee */
    function _sellTokenForBNBSupportingTransferFees(address token, uint256 tokenBalance) private {

        // path from TOKEN -> BNB
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = router.WETH();
        // bnb balance before swap
        uint256 before = address(this).balance;
        // approve router
        IERC20(token).approve(address(router), tokenBalance);

        receiveDisabled = true;

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenBalance,
            0,
            path,
            address(this),
            block.timestamp.add(30)
        );

        // how much BNB received from swap
        uint256 bnbAdded = address(this).balance.sub(before);
        
        receiveDisabled = false;
        _distributeShares(bnbAdded);
    }


    function _distributeShares(uint256 numShares) internal {

        uint256[] memory amounts = new uint256[](nBrackets);
        uint256 total;
        for (uint i = 0; i < nBrackets; i++) {
            if (brackets[i].ratio == 0 || brackets[i].nVictims == 0) {
                continue;
            }
            amounts[i] = ( numShares * brackets[i].ratio ) / 100;
            total += amounts[i];
        }
        if (total > numShares) {
            amounts[nBrackets - 1] -= ( total - numShares );
        } else if (total < numShares) {
            amounts[nBrackets - 1] += ( numShares - total );
        }

        for (uint i = 0; i < nBrackets; i++) {
            if (brackets[i].ratio > 0 || brackets[i].nVictims > 0) {
                brackets[i].dividendsPerShare += ( amounts[i] * precision ) / brackets[i].totalSharesPerBracket;
            }
        }

        delete amounts;
    }

    function _checkBrackets() internal {

        for (uint i = 0; i < nBrackets; i++) {

            if (brackets[i].nVictims == 0) {
                if (brackets[i].ratio > 0) {
                    // needs to be distributed
                    _distributeRatio(i);
                }
            }

        }

    }

    function _distributeRatio(uint256 whichBracket) internal {

        uint256 rat = brackets[whichBracket].ratio;
        brackets[whichBracket].ratio = 0;

        uint256 divisor;
        for (uint i = 0; i < nBrackets; i++) {
            if (i == whichBracket) continue;
            if (brackets[i].nVictims > 0 && brackets[i].ratio > 0) {
                divisor++;
            }
        }

        if (divisor == 0) return;

        uint256 amountPer = rat / divisor;

        uint256 totalRatio;
        for (uint i = 0; i < nBrackets; i++) {
            if (i == whichBracket) continue;

            if (brackets[i].nVictims > 0 && brackets[i].ratio > 0) {
                brackets[i].ratio += amountPer;
                totalRatio += brackets[i].ratio;
            }
        }

        if (totalRatio > 100) {
            brackets[nBrackets - 1].ratio -= (totalRatio - 100);
        } else if (totalRatio < 100) {
            brackets[nBrackets - 1].ratio += (100 - totalRatio);
        }
    }
    
    function currentDividends(uint256 bracket, uint256 share) internal view returns (uint256) {
        return share.mul(brackets[bracket].dividendsPerShare).div(precision);
    }

    function totalBNBPaidBack() external view returns (uint256) {
        return initialPaybackAmount - totalShares;
    }
    
    function usersCurrentClaim(address user) internal view returns (uint256) {
        uint256 amount = victims[user].totalToClaim;
        if(amount == 0){ return 0; }

        uint256 shareholderTotalDividends = currentDividends(victims[user].bracket, amount);
        uint256 shareholderTotalExcluded = victims[user].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function _convertBUSD() internal returns (uint256) {
        uint256 before = IERC20(busd).balanceOf(address(this));
        router.swapExactETHForTokens{value: address(this).balance}(
            0,
            path,
            address(this),
            block.timestamp + 300
        );
        return IERC20(busd).balanceOf(address(this)).sub(before, 'Underflow');
    }
    
    /** Register Donation On Receive */
    receive() external payable {

        if (receiveDisabled || msg.sender == address(router)) {
            return;
        }

        uint256 received = _convertBUSD();
        require(received > 0);
        _distributeShares(received);
    }
    
    // EVENTS
    event OptOut(address generousUser, uint256 rewardGivenUp);
    event LockedContract(uint256 timestamp, uint256 blockNumber);
    event FundMigration(bool migratedBNB, uint256 amount, address token, address recipient);
    event Claim(address claimer, uint256 amountBNB);
    event SetSurgeBNBAddress(address newSurgeBNB);
    event TransferOwnership(address newOwner);

}