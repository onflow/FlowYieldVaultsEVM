// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract FalseApproveToken {
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}
