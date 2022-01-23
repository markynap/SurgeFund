//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

/**
 * Exempt Surge Interface
 */
interface ISurge {
    function sell(uint256 amount) external;
    function getUnderlyingAsset() external returns(address);
}