// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import "../src/FlowVaultsRequests.sol";

contract DeployFlowVaultsRequests is Script {
    function run() external returns (FlowVaultsRequests) {
        uint256 deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0x2)
        );

        address deployer = vm.addr(deployerPrivateKey);

        // Read COA address from environment variable
        address coa = vm.envAddress("COA_ADDRESS");

        // Start broadcast with private key
        vm.startBroadcast(deployerPrivateKey);

        FlowVaultsRequests flowVaultsRequests = new FlowVaultsRequests(coa);

        vm.stopBroadcast();

        return flowVaultsRequests;
    }
}
