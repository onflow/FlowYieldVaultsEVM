// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FlowYieldVaultsRequests} from "../src/FlowYieldVaultsRequests.sol";
import {FlowYieldVaultsAdmin} from "../src/FlowYieldVaultsAdmin.sol";

/**
 * @title DeployFlowYieldVaultsRequests
 * @notice Deployment script for the FlowYieldVaultsRequests contract
 * @dev Deploys the contract with a specified COA address from environment variables
 *
 * Usage:
 *   forge script script/DeployFlowYieldVaultsRequests.s.sol:DeployFlowYieldVaultsRequests \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment (required for mainnet/testnet)
 *   - COA_ADDRESS: Address of the authorized COA (required)
 *   - WFLOW_ADDRESS: Address of the WFLOW token (optional, use address(0) to disable)
 */
contract DeployFlowYieldVaultsRequests is Script {
    function run() external returns (FlowYieldVaultsRequests) {
        uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0x2));
        address coaAddress = vm.envAddress("COA_ADDRESS");
        address wflowAddress = vm.envOr("WFLOW_ADDRESS", address(0));

        vm.startBroadcast(deployerPrivateKey);

        FlowYieldVaultsAdmin fyvAdmin = new FlowYieldVaultsAdmin(coaAddress, wflowAddress);
        FlowYieldVaultsRequests flowYieldVaultsRequests = new FlowYieldVaultsRequests(wflowAddress, address(fyvAdmin));

        vm.stopBroadcast();

        console.log("FlowYieldVaultsRequests deployed at:", address(flowYieldVaultsRequests));
        console.log("Authorized COA:", coaAddress);
        console.log("WFLOW Address:", wflowAddress);
        console.log("Owner:", flowYieldVaultsRequests.owner());

        return flowYieldVaultsRequests;
    }
}
