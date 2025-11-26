import "FlowVaults"
import "FlowVaultsEVM"

/// @title Check Tide Details
/// @notice Returns detailed information about Tides managed by FlowVaultsEVM
/// @param account The account address where FlowVaultsEVM Worker is stored
/// @return Dictionary with Tide details and supported strategies
///
access(all) fun main(account: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}

    result["contractAddress"] = account.toString()
    result["flowVaultsRequestsAddress"] = FlowVaultsEVM.getFlowVaultsRequestsAddress()?.toString() ?? "not set"

    let tidesByEVM = FlowVaultsEVM.tidesByEVMAddress
    result["totalEVMAddresses"] = tidesByEVM.keys.length

    let allTideIds: [UInt64] = []
    let evmMappings: [{String: AnyStruct}] = []

    for evmAddr in tidesByEVM.keys {
        let tides = FlowVaultsEVM.getTideIDsForEVMAddress(evmAddr)
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

    let strategies = FlowVaults.getSupportedStrategies()
    let strategyIdentifiers: [String] = []
    for strategy in strategies {
        strategyIdentifiers.append(strategy.identifier)
    }
    result["supportedStrategies"] = strategyIdentifiers
    result["totalStrategies"] = strategies.length

    return result
}
