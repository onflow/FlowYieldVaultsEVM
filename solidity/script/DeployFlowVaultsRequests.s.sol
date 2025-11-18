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
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        // Read COA address from environment variable
        address coa = vm.envAddress("COA_ADDRESS");
        console.log("Using COA address:", coa);

        // Start broadcast with private key
        vm.startBroadcast(deployerPrivateKey);

        FlowVaultsRequests flowVaultsRequests = new FlowVaultsRequests(coa);

        console.log(
            "FlowVaultsRequests deployed at:",
            address(flowVaultsRequests)
        );
        console.log("NATIVE_FLOW constant:", flowVaultsRequests.NATIVE_FLOW());

        vm.stopBroadcast();

        return flowVaultsRequests;
    }
}
