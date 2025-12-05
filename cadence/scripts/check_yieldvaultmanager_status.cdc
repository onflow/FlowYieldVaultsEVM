import "FlowYieldVaults"
import "FlowYieldVaultsEVM"

/// @title Check YieldVaultManager Status
/// @notice Returns comprehensive status and health check of the FlowYieldVaultsEVM system
/// @param accountAddress The account address where Worker is stored
/// @return Dictionary with status, configuration, and health checks
///
access(all) fun main(accountAddress: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}
    let account = getAccount(accountAddress)

    result["contractAddress"] = accountAddress.toString()
    result["flowYieldVaultsRequestsAddress"] = FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress()?.toString() ?? "not set"

    let paths: {String: String} = {}
    paths["workerStorage"] = FlowYieldVaultsEVM.WorkerStoragePath.toString()
    paths["adminStorage"] = FlowYieldVaultsEVM.AdminStoragePath.toString()
    paths["yieldVaultManagerStorage"] = FlowYieldVaults.YieldVaultManagerStoragePath.toString()
    paths["yieldVaultManagerPublic"] = FlowYieldVaults.YieldVaultManagerPublicPath.toString()
    result["paths"] = paths

    let yieldVaultsByEVM = FlowYieldVaultsEVM.yieldVaultsByEVMAddress
    result["totalEVMAddresses"] = yieldVaultsByEVM.keys.length

    var totalYieldVaultsMapped = 0
    let evmDetails: [{String: AnyStruct}] = []

    for evmAddr in yieldVaultsByEVM.keys {
        let yieldVaults = FlowYieldVaultsEVM.getYieldVaultIDsForEVMAddress(evmAddr)
        totalYieldVaultsMapped = totalYieldVaultsMapped + yieldVaults.length

        evmDetails.append({
            "evmAddress": "0x".concat(evmAddr),
            "yieldVaultCount": yieldVaults.length,
            "yieldVaultIds": yieldVaults
        })
    }

    result["evmAddressDetails"] = evmDetails
    result["totalMappedYieldVaults"] = totalYieldVaultsMapped

    let strategies = FlowYieldVaults.getSupportedStrategies()
    let strategyInfo: [{String: AnyStruct}] = []

    for strategy in strategies {
        let initVaults = FlowYieldVaults.getSupportedInitializationVaults(forStrategy: strategy)

        let vaultTypes: [String] = []
        for vaultType in initVaults.keys {
            if initVaults[vaultType]! {
                vaultTypes.append(vaultType.identifier)
            }
        }

        strategyInfo.append({
            "strategyType": strategy.identifier,
            "supportedInitVaults": vaultTypes,
            "vaultCount": vaultTypes.length
        })
    }

    result["strategies"] = strategyInfo
    result["totalStrategies"] = strategies.length

    let storagePaths: [String] = []
    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        storagePaths.append(path.toString().concat(" -> ").concat(type.identifier))
        return true
    })
    result["storagePaths"] = storagePaths
    result["storageItemCount"] = storagePaths.length

    let healthChecks: {String: String} = {}

    if FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress() != nil {
        healthChecks["flowYieldVaultsRequestsAddress"] = "SET"
    } else {
        healthChecks["flowYieldVaultsRequestsAddress"] = "NOT SET"
    }

    if strategies.length > 0 {
        healthChecks["strategies"] = strategies.length.toString().concat(" available")
    } else {
        healthChecks["strategies"] = "NO STRATEGIES"
    }

    var workerExists = false
    for path in storagePaths {
        if path.contains("FlowYieldVaultsEVM.Worker") {
            workerExists = true
            break
        }
    }

    healthChecks["worker"] = workerExists ? "EXISTS" : "NOT FOUND"
    healthChecks["evmUsers"] = yieldVaultsByEVM.keys.length > 0 ? yieldVaultsByEVM.keys.length.toString().concat(" registered") : "NO USERS"
    healthChecks["yieldVaults"] = totalYieldVaultsMapped > 0 ? totalYieldVaultsMapped.toString().concat(" created") : "NO YIELDVAULTS"

    result["healthChecks"] = healthChecks

    let criticalChecks = FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress() != nil && strategies.length > 0 && workerExists

    if criticalChecks && totalYieldVaultsMapped > 0 {
        result["status"] = "OPERATIONAL"
    } else if criticalChecks {
        result["status"] = "READY"
    } else {
        result["status"] = "NEEDS CONFIGURATION"
    }

    result["summary"] = {
        "evmUsers": yieldVaultsByEVM.keys.length,
        "totalYieldVaults": totalYieldVaultsMapped,
        "strategies": strategies.length,
        "storageItems": storagePaths.length
    }

    return result
}
