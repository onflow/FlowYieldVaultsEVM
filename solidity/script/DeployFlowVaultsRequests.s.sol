// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import "../src/FlowVaultsRequests.sol";

contract DeployFlowVaultsRequests is Script {
    function run() external returns (FlowVaultsRequests) {
        // IMPORTANT: Get the private key for broadcasting
        uint256 deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0x2)
        );

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer); //0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF
        console.log("Deployer balance:", deployer.balance);

        // Start broadcast with private key
        vm.startBroadcast(deployerPrivateKey);

        address coa = 0x000000000000000000000002f595dA99775532Ee;
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
