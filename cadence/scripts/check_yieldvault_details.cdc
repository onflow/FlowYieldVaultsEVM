import "FlowYieldVaults"
import "FlowYieldVaultsEVM"

/// @title Check YieldVault Details
/// @notice Returns detailed information about YieldVaults managed by FlowYieldVaultsEVM
/// @param account The account address where FlowYieldVaultsEVM Worker is stored
/// @return Dictionary with YieldVault details and supported strategies
///
access(all) fun main(account: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}

    result["contractAddress"] = account.toString()
    result["flowYieldVaultsRequestsAddress"] = FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress()?.toString() ?? "not set"

    let yieldVaultsByEVM = FlowYieldVaultsEVM.yieldVaultsByEVMAddress
    result["totalEVMAddresses"] = yieldVaultsByEVM.keys.length

    let allYieldVaultIds: [UInt64] = []
    let evmMappings: [{String: AnyStruct}] = []

    for evmAddr in yieldVaultsByEVM.keys {
        let yieldVaults = FlowYieldVaultsEVM.getYieldVaultIdsForEVMAddress(evmAddr)
        allYieldVaultIds.appendAll(yieldVaults)

        evmMappings.append({
            "evmAddress": evmAddr,
            "yieldVaultIds": yieldVaults,
            "yieldVaultCount": yieldVaults.length
        })
    }

    result["evmMappings"] = evmMappings
    result["totalMappedYieldVaults"] = allYieldVaultIds.length
    result["allMappedYieldVaultIds"] = allYieldVaultIds

    let strategies = FlowYieldVaults.getSupportedStrategies()
    let strategyIdentifiers: [String] = []
    for strategy in strategies {
        strategyIdentifiers.append(strategy.identifier)
    }
    result["supportedStrategies"] = strategyIdentifiers
    result["totalStrategies"] = strategies.length

    return result
}
