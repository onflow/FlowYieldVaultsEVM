// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlowYieldVaultsRequests} from "../src/FlowYieldVaultsRequests.sol";

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
        FlowYieldVaultsRequests fyvImplementation = new FlowYieldVaultsRequests();

        ERC1967Proxy fyvProxy = new ERC1967Proxy(
            address(fyvImplementation),
            abi.encodeCall(FlowYieldVaultsRequests.initialize, (coaAddress, wflowAddress))
        );
        vm.stopBroadcast();

        FlowYieldVaultsRequests flowYieldVaultsRequests = FlowYieldVaultsRequests(address(fyvProxy));

        console.log("FlowYieldVaultsRequests proxy deployed at:", address(flowYieldVaultsRequests));
        console.log("FlowYieldVaultsRequests implementation at:", address(fyvImplementation));
        console.log("Authorized COA:", coaAddress);
        console.log("WFLOW Address:", wflowAddress);
        console.log("Owner:", flowYieldVaultsRequests.owner());

        return flowYieldVaultsRequests;
    }
}
