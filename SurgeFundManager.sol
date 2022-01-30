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

    // initial amount of BNB needed to pay back
    uint256 public initialPaybackAmount = 5850000 * 10**18;

    // Total Amount of USD Needed To Give Back
    uint256 public totalShares;

    // cost of BNB + 10% at the time of hack
    uint256 public constant BNB_PRICE_PLUS_TWO_PERCENT = 424;

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

    // cost inflator for switching to BUSD rewards
    uint256 public inflator = 1;

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

    /** How Much BNB This User Has Left To Claim */
    function BNBToClaimForVictim(address victim) external view returns (uint256) {
        return victims[victim].totalToClaim;
    }

    /** If Sender Has BNB Left To Claim */
    function isVictim(address user) external view returns (bool) {
        return victims[user].totalToClaim > 0;
    }

}
