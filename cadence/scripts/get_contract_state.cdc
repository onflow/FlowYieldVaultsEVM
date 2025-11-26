import "FlowVaultsEVM"

/// @title Get Contract State
/// @notice Returns the current state of the FlowVaultsEVM contract
/// @param contractAddress The address where FlowVaultsEVM is deployed (unused but kept for compatibility)
/// @return Dictionary containing contract configuration and statistics
///
access(all) fun main(contractAddress: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}

    result["flowVaultsRequestsAddress"] = FlowVaultsEVM.getFlowVaultsRequestsAddress()?.toString() ?? "Not set"
    result["maxRequestsPerTx"] = FlowVaultsEVM.maxRequestsPerTx
    result["tidesByEVMAddress"] = FlowVaultsEVM.tidesByEVMAddress

    result["WorkerStoragePath"] = FlowVaultsEVM.WorkerStoragePath.toString()
    result["AdminStoragePath"] = FlowVaultsEVM.AdminStoragePath.toString()

    var totalTides = 0
    var totalEVMAddresses = 0
    for evmAddress in FlowVaultsEVM.tidesByEVMAddress.keys {
        totalEVMAddresses = totalEVMAddresses + 1
        let tideIds = FlowVaultsEVM.tidesByEVMAddress[evmAddress]!
        totalTides = totalTides + tideIds.length
    }

    result["totalEVMAddresses"] = totalEVMAddresses
    result["totalTides"] = totalTides

    let evmAddressDetails: {String: Int} = {}
    for evmAddress in FlowVaultsEVM.tidesByEVMAddress.keys {
        evmAddressDetails[evmAddress] = FlowVaultsEVM.tidesByEVMAddress[evmAddress]!.length
    }
    result["evmAddressDetails"] = evmAddressDetails

    return result
}
