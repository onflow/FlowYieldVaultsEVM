import "FlowYieldVaultsEVM"

/// @title Get Contract State
/// @notice Returns the current state of the FlowYieldVaultsEVM contract
/// @param contractAddress The address where FlowYieldVaultsEVM is deployed (unused but kept for compatibility)
/// @return Dictionary containing contract configuration and statistics
///
access(all) fun main(): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}

    result["flowYieldVaultsRequestsAddress"] = FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress()?.toString() ?? "Not set"
    result["yieldVaultRegistry"] = FlowYieldVaultsEVM.yieldVaultRegistry

    result["WorkerStoragePath"] = FlowYieldVaultsEVM.WorkerStoragePath.toString()
    result["AdminStoragePath"] = FlowYieldVaultsEVM.AdminStoragePath.toString()

    var totalYieldVaults = 0
    var totalEVMAddresses = 0
    for evmAddress in FlowYieldVaultsEVM.yieldVaultRegistry.keys {
        totalEVMAddresses = totalEVMAddresses + 1
        let yieldVaultOwnershipMap = FlowYieldVaultsEVM.yieldVaultRegistry[evmAddress]!
        totalYieldVaults = totalYieldVaults + yieldVaultOwnershipMap.keys.length
    }

    result["totalEVMAddresses"] = totalEVMAddresses
    result["totalYieldVaults"] = totalYieldVaults

    let evmAddressDetails: {String: Int} = {}
    for evmAddress in FlowYieldVaultsEVM.yieldVaultRegistry.keys {
        evmAddressDetails[evmAddress] = FlowYieldVaultsEVM.yieldVaultRegistry[evmAddress]!.length
    }
    result["evmAddressDetails"] = evmAddressDetails

    return result
}
