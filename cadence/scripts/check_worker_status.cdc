import "FlowVaultsEVM"
import "FlowVaults"
import "EVM"

/// @title Check Worker Status
/// @notice Returns comprehensive status of the FlowVaultsEVM Worker initialization
/// @param accountAddress The account address where Worker should be stored
/// @return Dictionary with worker status and capability health checks
///
access(all) fun main(accountAddress: Address): {String: AnyStruct} {
    let result: {String: AnyStruct} = {}
    let account = getAccount(accountAddress)

    // Check if Worker exists in storage
    var workerExists = false
    var workerType: String = ""

    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        if path == FlowVaultsEVM.WorkerStoragePath {
            workerExists = true
            workerType = type.identifier
        }
        return true
    })

    result["accountAddress"] = accountAddress.toString()
    result["workerStoragePath"] = FlowVaultsEVM.WorkerStoragePath.toString()
    result["workerExists"] = workerExists
    result["workerType"] = workerType

    // Check FlowVaultsRequests address configuration
    let flowVaultsRequestsAddress = FlowVaultsEVM.getFlowVaultsRequestsAddress()
    result["flowVaultsRequestsAddress"] = flowVaultsRequestsAddress?.toString() ?? "NOT SET"
    result["flowVaultsRequestsConfigured"] = flowVaultsRequestsAddress != nil

    // Check TideManager exists
    var tideManagerExists = false
    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        if path == FlowVaults.TideManagerStoragePath {
            tideManagerExists = true
        }
        return true
    })
    result["tideManagerExists"] = tideManagerExists

    // Check COA exists
    var coaExists = false
    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        if type.identifier.contains("CadenceOwnedAccount") {
            coaExists = true
        }
        return true
    })
    result["coaExists"] = coaExists

    // Build health checks summary
    let healthChecks: {String: String} = {}
    healthChecks["worker"] = workerExists ? "OK" : "MISSING"
    healthChecks["flowVaultsRequestsAddress"] = flowVaultsRequestsAddress != nil ? "OK" : "NOT CONFIGURED"
    healthChecks["tideManager"] = tideManagerExists ? "OK" : "MISSING"
    healthChecks["coa"] = coaExists ? "OK" : "MISSING"
    result["healthChecks"] = healthChecks

    // Determine overall status
    let allChecksPass = workerExists && flowVaultsRequestsAddress != nil && tideManagerExists && coaExists

    if allChecksPass {
        result["status"] = "INITIALIZED"
        result["message"] = "Worker is correctly initialized and ready to process requests"
    } else {
        result["status"] = "NOT INITIALIZED"
        var issues: [String] = []
        if !workerExists {
            issues.append("Worker resource not found at ".concat(FlowVaultsEVM.WorkerStoragePath.toString()))
        }
        if flowVaultsRequestsAddress == nil {
            issues.append("FlowVaultsRequests EVM address not configured")
        }
        if !tideManagerExists {
            issues.append("TideManager not found")
        }
        if !coaExists {
            issues.append("COA (Cadence Owned Account) not found")
        }
        result["issues"] = issues
        result["message"] = "Worker initialization incomplete. Run setup_worker_with_badge transaction."
    }

    return result
}
