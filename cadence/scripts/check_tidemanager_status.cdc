import "FlowVaults"
import "FlowVaultsEVM"

/// @title Check TideManager Status
/// @notice Returns comprehensive status and health check of the FlowVaultsEVM system
/// @param accountAddress The account address where Worker is stored
/// @return Dictionary with status, configuration, and health checks
///
access(all) fun main(accountAddress: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}
    let account = getAccount(accountAddress)

    result["contractAddress"] = accountAddress.toString()
    result["flowVaultsRequestsAddress"] = FlowVaultsEVM.getFlowVaultsRequestsAddress()?.toString() ?? "not set"

    let paths: {String: String} = {}
    paths["workerStorage"] = FlowVaultsEVM.WorkerStoragePath.toString()
    paths["adminStorage"] = FlowVaultsEVM.AdminStoragePath.toString()
    paths["tideManagerStorage"] = FlowVaults.TideManagerStoragePath.toString()
    paths["tideManagerPublic"] = FlowVaults.TideManagerPublicPath.toString()
    result["paths"] = paths

    let tidesByEVM = FlowVaultsEVM.tidesByEVMAddress
    result["totalEVMAddresses"] = tidesByEVM.keys.length

    var totalTidesMapped = 0
    let evmDetails: [{String: AnyStruct}] = []

    for evmAddr in tidesByEVM.keys {
        let tides = FlowVaultsEVM.getTideIDsForEVMAddress(evmAddr)
        totalTidesMapped = totalTidesMapped + tides.length

        evmDetails.append({
            "evmAddress": "0x".concat(evmAddr),
            "tideCount": tides.length,
            "tideIds": tides
        })
    }

    result["evmAddressDetails"] = evmDetails
    result["totalMappedTides"] = totalTidesMapped

    let strategies = FlowVaults.getSupportedStrategies()
    let strategyInfo: [{String: AnyStruct}] = []

    for strategy in strategies {
        let initVaults = FlowVaults.getSupportedInitializationVaults(forStrategy: strategy)

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

    if FlowVaultsEVM.getFlowVaultsRequestsAddress() != nil {
        healthChecks["flowVaultsRequestsAddress"] = "SET"
    } else {
        healthChecks["flowVaultsRequestsAddress"] = "NOT SET"
    }

    if strategies.length > 0 {
        healthChecks["strategies"] = strategies.length.toString().concat(" available")
    } else {
        healthChecks["strategies"] = "NO STRATEGIES"
    }

    var workerExists = false
    for path in storagePaths {
        if path.contains("FlowVaultsEVM.Worker") {
            workerExists = true
            break
        }
    }

    healthChecks["worker"] = workerExists ? "EXISTS" : "NOT FOUND"
    healthChecks["evmUsers"] = tidesByEVM.keys.length > 0 ? tidesByEVM.keys.length.toString().concat(" registered") : "NO USERS"
    healthChecks["tides"] = totalTidesMapped > 0 ? totalTidesMapped.toString().concat(" created") : "NO TIDES"

    result["healthChecks"] = healthChecks

    let criticalChecks = FlowVaultsEVM.getFlowVaultsRequestsAddress() != nil && strategies.length > 0 && workerExists

    if criticalChecks && totalTidesMapped > 0 {
        result["status"] = "OPERATIONAL"
    } else if criticalChecks {
        result["status"] = "READY"
    } else {
        result["status"] = "NEEDS CONFIGURATION"
    }

    result["summary"] = {
        "evmUsers": tidesByEVM.keys.length,
        "totalTides": totalTidesMapped,
        "strategies": strategies.length,
        "storageItems": storagePaths.length
    }

    return result
}
