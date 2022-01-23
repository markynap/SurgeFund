//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./IERC20.sol";
import "./ISurgeFund.sol";

contract SurgeFundRepayment is IERC20{

    struct Victim {
        uint256 claim;
        uint256 index;
    }

    mapping ( address => Victim ) victim;
    address[] public victims;

    ISurgeFund oldFund = ISurgeFund(0x8078380508c16C9F122D62771714701612Eb3fa8);

    uint256 public totalClaim;

    address owner;
    modifier onlyOwner(){require(msg.sender == owner, 'Only Owner'); _;}

    constructor() {
        owner = msg.sender;
    }

    event VictimAdded(address victim);
    event VictimRepaid(address victim, uint256 amount);

    function totalSupply() external view override returns (uint256) { return totalClaim; }
    function balanceOf(address account) public view override returns (uint256) { return victim[account].claim; }
    function allowance(address holder, address spender) external pure override returns (uint256) { return holder == spender ? 0 : 1; }
    
    function name() public pure override returns (string memory) {
        return "SurgeFund REPAYMENT";
    }

    function symbol() public pure override returns (string memory) {
        return "SURGE REPAYMENT";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function approve(address spender, uint256 amount) public view override returns (bool) {
        return spender != msg.sender && amount > 0;
    }
  
    function transfer(address recipient, uint256 amount) external view override returns (bool) {
        return recipient == msg.sender || amount > 0;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external pure override returns (bool) {
        return sender != recipient || amount > 0;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function registerVictims(address[] calldata iVictims) external onlyOwner {
        
        for (uint i = 0; i < iVictims.length; i++) {
            uint256 old = oldFund.remainingBnbToClaimForVictim(iVictims[i]);
            if (old > 0) {
                _addVictim(iVictims[i], old);
            }
        }

    }

    function withdraw() external onlyOwner {
        (bool s,) = payable(msg.sender).call{value: address(this).balance}("");
        require(s);
    }

    receive() external payable {}

    function iterateThrough(uint256 length) external onlyOwner {
        
        for (uint i = 0; i < length; i++) {

            if (victims.length == 0) return;

            uint256 amount = victim[victims[0]].claim;
            uint256 bal = address(this).balance;

            if (amount == 0) {
                _removeVictim(victims[0]);
                return;
            }

            if (amount > bal) return;

            payable(victims[0]).transfer(amount);
            emit Transfer(address(0), victims[0], amount);        
            _removeVictim(victims[0]);
        }

    }

    function _addVictim(address _victim, uint256 claim) internal {
        require(victim[_victim].claim == 0, 'Victim Exists');

        victim[_victim].claim = claim;
        victim[_victim].index = victims.length;

        victims.push(_victim);

        totalClaim += claim;
        emit VictimAdded(_victim);
    }

    function _removeVictim(address victim_) internal {

        uint256 victimRemovedIndex = victim[victim_].index;
        uint256 share = victim[victim_].claim;

        if (victimRemovedIndex == 0) {
            if (victim_ != victims[0]) return;
        }

        address lastVictim = victims[victims.length - 1];

        totalClaim -= share;

        victims[victimRemovedIndex] = lastVictim;
        victim[lastVictim].index = victimRemovedIndex;
        victims.pop();
        delete victim[victim_];
        emit VictimRepaid(victim_, share);
    }

}