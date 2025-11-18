import "FlowVaultsEVM"

access(all) fun main(contractAddress: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}
    
    // Get all public state variables
    result["flowVaultsRequestsAddress"] = FlowVaultsEVM.getFlowVaultsRequestsAddress()?.toString() ?? "Not set"
    result["tidesByEVMAddress"] = FlowVaultsEVM.tidesByEVMAddress
    
    // Get all public paths
    result["WorkerStoragePath"] = FlowVaultsEVM.WorkerStoragePath.toString()
    result["WorkerPublicPath"] = FlowVaultsEVM.WorkerPublicPath.toString()
    result["AdminStoragePath"] = FlowVaultsEVM.AdminStoragePath.toString()
    
    // Count total tides across all EVM addresses
    var totalTides = 0
    var totalEVMAddresses = 0
    for evmAddress in FlowVaultsEVM.tidesByEVMAddress.keys {
        totalEVMAddresses = totalEVMAddresses + 1
        let tideIds = FlowVaultsEVM.tidesByEVMAddress[evmAddress]!
        totalTides = totalTides + tideIds.length
    }
    
    result["totalEVMAddresses"] = totalEVMAddresses
    result["totalTides"] = totalTides
    
    // List all EVM addresses with their tide counts
    let evmAddressDetails: {String: Int} = {}
    for evmAddress in FlowVaultsEVM.tidesByEVMAddress.keys {
        evmAddressDetails[evmAddress] = FlowVaultsEVM.tidesByEVMAddress[evmAddress]!.length
    }
    result["evmAddressDetails"] = evmAddressDetails
    
    return result
}