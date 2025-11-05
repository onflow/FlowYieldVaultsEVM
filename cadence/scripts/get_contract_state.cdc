import "TidalEVM"

access(all) fun main(contractAddress: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}
    
    // Get all public state variables
    result["tidalRequestsAddress"] = TidalEVM.getTidalRequestsAddress()?.toString() ?? "Not set"
    result["tidesByEVMAddress"] = TidalEVM.tidesByEVMAddress
    
    // Get all public paths
    result["WorkerStoragePath"] = TidalEVM.WorkerStoragePath.toString()
    result["WorkerPublicPath"] = TidalEVM.WorkerPublicPath.toString()
    result["AdminStoragePath"] = TidalEVM.AdminStoragePath.toString()
    
    // Count total tides across all EVM addresses
    var totalTides = 0
    var totalEVMAddresses = 0
    for evmAddress in TidalEVM.tidesByEVMAddress.keys {
        totalEVMAddresses = totalEVMAddresses + 1
        let tideIds = TidalEVM.tidesByEVMAddress[evmAddress]!
        totalTides = totalTides + tideIds.length
    }
    
    result["totalEVMAddresses"] = totalEVMAddresses
    result["totalTides"] = totalTides
    
    // List all EVM addresses with their tide counts
    let evmAddressDetails: {String: Int} = {}
    for evmAddress in TidalEVM.tidesByEVMAddress.keys {
        evmAddressDetails[evmAddress] = TidalEVM.tidesByEVMAddress[evmAddress]!.length
    }
    result["evmAddressDetails"] = evmAddressDetails
    
    return result
}