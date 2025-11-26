// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FlowVaultsRequests} from "../src/FlowVaultsRequests.sol";

/**
 * @title DeployFlowVaultsRequests
 * @notice Deployment script for the FlowVaultsRequests contract
 * @dev Deploys the contract with a specified COA address from environment variables
 *
 * Usage:
 *   forge script script/DeployFlowVaultsRequests.s.sol:DeployFlowVaultsRequests \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment (required for mainnet/testnet)
 *   - COA_ADDRESS: Address of the authorized COA (required)
 */
contract DeployFlowVaultsRequests is Script {
    function run() external returns (FlowVaultsRequests) {
        uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0x2));
        address coaAddress = vm.envAddress("COA_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        FlowVaultsRequests flowVaultsRequests = new FlowVaultsRequests(coaAddress);

        vm.stopBroadcast();

        console.log("FlowVaultsRequests deployed at:", address(flowVaultsRequests));
        console.log("Authorized COA:", coaAddress);
        console.log("Owner:", flowVaultsRequests.owner());

        return flowVaultsRequests;
    }
}
