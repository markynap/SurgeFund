//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./SafeMath.sol";
import "./Address.sol";
import "./IERC20.sol";
import "./ISurgeFund.sol";
import "./ISurgeFundV2.sol";


/**
    Manage All Victim Data, So Relaunching is free
    Add Way To Manually Convert Owed Balances Into BUSD Amounts (BNB_Amount x 424 )
    Allow one upgradable SurgeFundToken contract to update Manager State
 */
contract SurgeFundManager {

    address public SurgeFundToken;

    // old surge fund to pull data from
    ISurgeFund oldFund = ISurgeFund(0x8078380508c16C9F122D62771714701612Eb3fa8);

    // victim structure
    struct Victim {
        uint256 bracket;
        uint256 lastClaim;
        uint256 totalToClaim;
        uint256 totalExcluded;
        uint256 arrayIndex;
    }

    // Victims
    mapping ( address => Victim ) public victims;
    address[] public victims;

    // Repayment Brackets Weighted By Amount Lost
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

    constructor() {
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        owner = msg.sender;
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


    /** Adds Victims To The Fund, Cannot Be Accessed If Function is Locked */
    function pullVictims(address[] calldata _victims) external onlyOwner {
        for (uint i = 0; i < _victims.length; i++) {
            uint256 claim_ = oldFund.remainingBnbToClaimForVictim(_victims[i]);
            if (claim_ > 0 && victims[_victims[i]].totalToClaim == 0) {
                addVictim(_victims[i], claim_);
            }
        }
    }


    /** Adds Victim To The List Of Victims If Contract Is Unlocked */
    function addVictim(address victim, uint256 victimClaim) private {
        
        if (victims[victim].totalToClaim > 0 || victimClaim == 0) {
            return;
        }

        for (uint i = 0; i < nBrackets; i++) {
            if (victimClaim >= brackets[i].lowerBound &&
                victimClaim < brackets[i].upperBound) {
                    victims[victim].bracket = i;
                    brackets[i].nVictims++;
                    brackets[i].totalSharesPerBracket += victimClaim;
                    break;
                }
        }

        totalShares = totalShares.add(victimClaim);

        victims[victim].totalToClaim = victimClaim;
        victims[victim].totalExcluded = currentDividends(victimClaim);
        emit Transfer(address(0), victim, victimClaim);
    }


    /** Opts Out Of Surge Fund Rewards */
    function optOut(uint256 percent) external {
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


}

contract SurgeFund is ReentrancyGuard, IERC20, ISurgeFundV2 {
    
    using SafeMath for uint256;
    using Address for address;

    SurgeFundManager manager = SurgeFundManager();

    // Dividend Precision To Avoid Round-Off Error
    uint256 precision = 10**18;

    // minimum claim $1
    uint256 public minimumClaim = 10**18;

    // LOCKS Certain Functions
    bool public isLocked = false;
    address public owner;

    // converts donations into desired token and deposits into SF
    address public paymentConverter;

    modifier onlyOwner() {require(msg.sender == owner, 'Only Owner'); _;}
    modifier onlyCaller() {require(functionCaller[msg.sender], 'Only Function Caller'); _;}
    modifier notLocked() { require(!isLocked, 'Function Is Locked'); _; }
    
    constructor() {
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        owner = msg.sender;
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

    function totalSupply() external view override returns (uint256) { return manager.totalLocked(); }
    function balanceOf(address account) public view override returns (uint256) { return usersCurrentClaim(account); }
    function allowance(address holder, address spender) external pure override returns (uint256) { return holder == spender ? 0 : 1; }
    
    function name() public pure override returns (string memory) {
        return "SurgeFundToken";
    }

    function symbol() public pure override returns (string memory) {
        return "SFT";
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

    // EXTERNAL FUNCTIONS

    function deposit(uint256 amount) external override {

        uint256 before = IERC20(busd).balanceOf(address(this));
        bool s = IERC20(busd).transferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(busd).balanceOf(address(this)) - before;
        require(received > 0 && received <= amount && s);

        _distributeShares(received);
    }

    function claim() external {
        _claim(msg.sender);
    }

    function withdrawToReceiverToLiquify(address token) external {
        IERC20(token).transfer(paymentReceiver, IERC20(token).balanceOf(address(this)));
    }

    // OWNER FUNCTIONS

    function transferOwnership(address newOwner) external notLocked onlyOwner {
        owner = newOwner;
        emit TransferOwnership(newOwner);
    }

    function setMinimumClaim(uint256 minClaim) external notLocked onlyOwner {
        minimumClaim = minClaim;
    }

    /** Adds Victims To The Fund, Cannot Be Accessed If Function is Locked */
    function pullVictims(address[] calldata _victims) external onlyOwner {
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

        if (pending > 0 && totalShares > 0) {
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





    // INTERNAL FUNCTIONS


    function _reduceShare(address user, uint256 amount) internal {

        // reduce victim claim amount
        victims[user].totalToClaim = victims[user].totalToClaim.sub(toClaim, 'totalToClaim underflow');

        // reduce global total + bracket totoal
        totalShares = totalShares.sub(toClaim, 'totalShares underflow');
        brackets[victims[user].bracket].totalSharesPerBracket = brackets[victims[user].bracket].totalSharesPerBracket.sub(toClaim, 'bracket underflow');

        // re-assign rewards
        victims[victim].totalExcluded = currentDividends(victims[victim].bracket, newClaim);
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

            // user's current claim amount
            uint256 prevClaim = victims[user].totalToClaim;

            // only claim total amount, reflect the rest
            _reduceShare(user, prevClaim);

            // amount to reflect
            uint256 diff = toClaim - prevClaim;

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
            _reduceShare(user, toClaim);

            // Remove Rest Of Claim If Below Minimum
            if (victims[user].totalToClaim < minimumClaim) {
                toClaim += victims[user].totalToClaim;
                _reduceShare(user, victims[user].totalToClaim);
            }
        }

        // Send Amount To User
        _sendToUser(user, toClaim);

        // check brackets
        _checkBrackets();

        // emit events
        emit Transfer(user, address(0), toClaim);
        emit Claim(user, toClaim);
    }

    function _sendToUser(address user, uint256 claim) internal returns (bool s) {
        if (inflator == 1) {
            (s,) = payable(user).call{value: claim}("");
            require(s, 'BNB Transfer Failed');
        } else {
            s = IERC20(busd).transfer(user, claim);
            require(s, 'BUSD Transfer Failed');
        }
    }
    
    /** Adds Victim To The List Of Victims If Contract Is Unlocked */
    function addVictim(address victim, uint256 victimClaim) private {
        
        if (victims[victim].totalToClaim > 0 || victimClaim == 0) {
            return;
        }

        for (uint i = 0; i < nBrackets; i++) {
            if (victimClaim >= brackets[i].lowerBound &&
                victimClaim < brackets[i].upperBound) {
                    victims[victim].bracket = i;
                    brackets[i].nVictims++;
                    brackets[i].totalSharesPerBracket += victimClaim;
                    break;
                }
        }

        totalShares = totalShares.add(victimClaim);

        victims[victim].totalToClaim = victimClaim;
        victims[victim].totalExcluded = currentDividends(victimClaim);
        emit Transfer(address(0), victim, victimClaim);
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
    
    function usersCurrentClaim(address user) internal view returns (uint256) {
        uint256 amount = victims[user].totalToClaim;
        if(amount == 0){ return 0; }

        uint256 shareholderTotalDividends = currentDividends(victims[user].bracket, amount);
        uint256 shareholderTotalExcluded = victims[user].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    
    /** Register Donation On Receive */
    receive() external payable {
        if (manager.inflator() == 1) {
            // reflect bnb rewards
            return;
        }
        (bool s,) = payable(address(manager)).call{value: address(this).balance}("");
        require(s);
    }
    
    // EVENTS
    event OptOut(address generousUser, uint256 rewardGivenUp);
    event LockedContract(uint256 timestamp, uint256 blockNumber);
    event FundMigration(bool migratedBNB, uint256 amount, address token, address recipient);
    event Claim(address claimer, uint256 amountBNB);
    event SetSurgeBNBAddress(address newSurgeBNB);
    event TransferOwnership(address newOwner);

}
