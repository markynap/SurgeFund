//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

/**
 * Exempt Surge Interface
 */
interface ISurgeFund {
    function remainingBnbToClaimForVictim(address victim) external view returns (uint256);
}