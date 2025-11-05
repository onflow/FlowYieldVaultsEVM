// check_tidemanager_status.cdc
import "TidalYield"
import "TidalEVM"

/// Script to get comprehensive TideManager status and health check
///
/// @param account: The account address where Worker is stored
/// @return Dictionary with TideManager status and diagnostics
///
access(all) fun main(accountAddress: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}
    let account = getAccount(accountAddress)
    
    // === Contract Configuration ===
    result["contractAddress"] = accountAddress.toString()
    result["tidalRequestsAddress"] = TidalEVM.getTidalRequestsAddress()?.toString() ?? "not set"
    
    // === Storage Paths ===
    let paths: {String: String} = {}
    paths["workerStorage"] = TidalEVM.WorkerStoragePath.toString()
    paths["workerPublic"] = TidalEVM.WorkerPublicPath.toString()
    paths["adminStorage"] = TidalEVM.AdminStoragePath.toString()
    paths["tideManagerStorage"] = TidalYield.TideManagerStoragePath.toString()
    paths["tideManagerPublic"] = TidalYield.TideManagerPublicPath.toString()
    result["paths"] = paths
    
    // === EVM Address Mappings ===
    let tidesByEVM = TidalEVM.tidesByEVMAddress
    result["totalEVMAddresses"] = tidesByEVM.keys.length
    
    var totalTidesMapped = 0
    let evmDetails: [{String: AnyStruct}] = []
    
    for evmAddr in tidesByEVM.keys {
        let tides = TidalEVM.getTideIDsForEVMAddress(evmAddr)
        totalTidesMapped = totalTidesMapped + tides.length
        
        evmDetails.append({
            "evmAddress": "0x".concat(evmAddr),
            "tideCount": tides.length,
            "tideIds": tides
        })
    }
    
    result["evmAddressDetails"] = evmDetails
    result["totalMappedTides"] = totalTidesMapped
    
    // === Strategy Information ===
    let strategies = TidalYield.getSupportedStrategies()
    let strategyInfo: [{String: AnyStruct}] = []
    
    for strategy in strategies {
        let initVaults = TidalYield.getSupportedInitializationVaults(forStrategy: strategy)
        
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
    
    // === Storage Inspection ===
    let storagePaths: [String] = []
    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        storagePaths.append(path.toString().concat(" -> ").concat(type.identifier))
        return true
    })
    result["storagePaths"] = storagePaths
    result["storageItemCount"] = storagePaths.length
    
    // === Public Capabilities ===
    let publicPaths: [String] = []

    let knownPublicPaths: [PublicPath] = [
        TidalEVM.WorkerPublicPath,
        TidalYield.TideManagerPublicPath
    ]

    for publicPath in knownPublicPaths {
        let cap = account.capabilities.get<&AnyResource>(publicPath)
        if cap != nil {
            publicPaths.append(publicPath.toString())
        }
    }

    result["publicPaths"] = publicPaths
    result["publicCapabilityCount"] = publicPaths.length

    
    // === Health Checks ===
    let healthChecks: {String: String} = {}
    
    // Check TidalRequests address
    if TidalEVM.getTidalRequestsAddress() != nil {
        healthChecks["tidalRequestsAddress"] = "✅ SET"
    } else {
        healthChecks["tidalRequestsAddress"] = "❌ NOT SET"
    }
    
    // Check strategies
    if strategies.length > 0 {
        healthChecks["strategies"] = "✅ ".concat(strategies.length.toString()).concat(" available")
    } else {
        healthChecks["strategies"] = "❌ NO STRATEGIES"
    }
    
    // Check Worker exists (look for Worker in storage paths)
    var workerExists = false
    for path in storagePaths {
        if path.contains("TidalEVM.Worker") {
            workerExists = true
            break
        }
    }
    
    if workerExists {
        healthChecks["worker"] = "✅ EXISTS"
    } else {
        healthChecks["worker"] = "❌ NOT FOUND"
    }
    
    // Check EVM users
    if tidesByEVM.keys.length > 0 {
        healthChecks["evmUsers"] = "✅ ".concat(tidesByEVM.keys.length.toString()).concat(" registered")
    } else {
        healthChecks["evmUsers"] = "⚠️  NO USERS YET"
    }
    
    // Check Tides
    if totalTidesMapped > 0 {
        healthChecks["tides"] = "✅ ".concat(totalTidesMapped.toString()).concat(" created")
    } else {
        healthChecks["tides"] = "⚠️  NO TIDES YET"
    }
    
    result["healthChecks"] = healthChecks
    
    // === Overall Status ===
    let criticalChecks = TidalEVM.getTidalRequestsAddress() != nil && strategies.length > 0 && workerExists
    
    if criticalChecks && totalTidesMapped > 0 {
        result["status"] = "🟢 OPERATIONAL"
        result["statusMessage"] = "Bridge is operational with active Tides"
    } else if criticalChecks {
        result["status"] = "🟡 READY"
        result["statusMessage"] = "Bridge is configured but no Tides created yet"
    } else {
        result["status"] = "🔴 NEEDS CONFIGURATION"
        result["statusMessage"] = "Critical components missing"
    }
    
    // === Summary ===
    result["summary"] = {
        "evmUsers": tidesByEVM.keys.length,
        "totalTides": totalTidesMapped,
        "strategies": strategies.length,
        "storageItems": storagePaths.length,
        "publicCapabilities": publicPaths.length
    }
    
    // === Notes ===
    result["notes"] = [
        "TideManager is embedded inside Worker resource (private access)",
        "Detailed Tide information requires transaction-based inspection",
        "EVM bridge status depends on COA authorization in Solidity contract"
    ]
    
    return result
}