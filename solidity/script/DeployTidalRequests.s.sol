// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import "../src/TidalRequests.sol";

contract DeployTidalRequests is Script {
    function run() external returns (TidalRequests) {
        vm.startBroadcast();

        address coa = 0x0000000000000000000000000000000000000001; // replace with your desired
        TidalRequests tidalRequests = new TidalRequests(coa);

        console.log("TidalRequests deployed at:", address(tidalRequests));
        console.log("NATIVE_FLOW constant:", tidalRequests.NATIVE_FLOW());

        vm.stopBroadcast();

        return tidalRequests;
    }
}
