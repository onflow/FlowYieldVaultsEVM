// check_tide_details.cdc
import "TidalYield"
import "TidalEVM"
import "DeFiActions"

/// Script to get detailed information about specific Tides in the Worker's TideManager
///
/// @param account: The account address where TidalEVM Worker is stored
/// @return Dictionary with comprehensive Tide details
///
access(all) fun main(account: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}
    
    // Get contract-level information
    result["contractAddress"] = account.toString()
    result["tidalRequestsAddress"] = TidalEVM.getTidalRequestsAddress()?.toString() ?? "not set"
    
    // Get all EVM address mappings from TidalEVM
    let tidesByEVM= TidalEVM.tidesByEVMAddress
    result["totalEVMAddresses"] = tidesByEVM.keys.length
    
    let allTideIds: [UInt64] = []
    let evmMappings: [{String: AnyStruct}] = []
    
    for evmAddr in tidesByEVM.keys {
        let tides = TidalEVM.getTideIDsForEVMAddress(evmAddr)
        allTideIds.appendAll(tides)
        
        evmMappings.append({
            "evmAddress": evmAddr,
            "tideIds": tides,
            "tideCount": tides.length
        })
    }
    
    result["evmMappings"] = evmMappings
    result["totalMappedTides"] = allTideIds.length
    result["allMappedTideIds"] = allTideIds
    
    // Note: Cannot access TideManager directly from script as it's private in Worker
    result["note"] = "TideManager is embedded in Worker resource - detailed Tide info requires transaction access"
    
    // Get supported strategies from TidalYield
    let strategies = TidalYield.getSupportedStrategies()
    let strategyIdentifiers: [String] = []
    for strategy in strategies {
        strategyIdentifiers.append(strategy.identifier)
    }
    result["supportedStrategies"] = strategyIdentifiers
    result["totalStrategies"] = strategies.length
    
    return result
}