// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract FalseApproveToken {
    // Minimal weird-token fixture: the call succeeds at the EVM level but returns
    // `false`, which is the exact behavior the Cadence regression test needs.
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}
