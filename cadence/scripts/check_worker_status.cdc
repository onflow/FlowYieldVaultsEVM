import "FlowYieldVaultsEVM"
import "FlowYieldVaults"
import "EVM"

/// @title Check Worker Status
/// @notice Returns comprehensive status of the FlowYieldVaultsEVM Worker initialization
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
        if path == FlowYieldVaultsEVM.WorkerStoragePath {
            workerExists = true
            workerType = type.identifier
        }
        return true
    })

    result["accountAddress"] = accountAddress.toString()
    result["workerStoragePath"] = FlowYieldVaultsEVM.WorkerStoragePath.toString()
    result["workerExists"] = workerExists
    result["workerType"] = workerType

    // Check FlowYieldVaultsRequests address configuration
    let flowYieldVaultsRequestsAddress = FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress()
    result["flowYieldVaultsRequestsAddress"] = flowYieldVaultsRequestsAddress?.toString() ?? "NOT SET"
    result["flowYieldVaultsRequestsConfigured"] = flowYieldVaultsRequestsAddress != nil

    // Check YieldVaultManager exists
    var yieldVaultManagerExists = false
    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        if path == FlowYieldVaults.YieldVaultManagerStoragePath {
            yieldVaultManagerExists = true
        }
        return true
    })
    result["yieldVaultManagerExists"] = yieldVaultManagerExists

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
    healthChecks["flowYieldVaultsRequestsAddress"] = flowYieldVaultsRequestsAddress != nil ? "OK" : "NOT CONFIGURED"
    healthChecks["yieldVaultManager"] = yieldVaultManagerExists ? "OK" : "MISSING"
    healthChecks["coa"] = coaExists ? "OK" : "MISSING"
    result["healthChecks"] = healthChecks

    // Determine overall status
    let allChecksPass = workerExists && flowYieldVaultsRequestsAddress != nil && yieldVaultManagerExists && coaExists

    if allChecksPass {
        result["status"] = "INITIALIZED"
        result["message"] = "Worker is correctly initialized and ready to process requests"
    } else {
        result["status"] = "NOT INITIALIZED"
        var issues: [String] = []
        if !workerExists {
            issues.append("Worker resource not found at ".concat(FlowYieldVaultsEVM.WorkerStoragePath.toString()))
        }
        if flowYieldVaultsRequestsAddress == nil {
            issues.append("FlowYieldVaultsRequests EVM address not configured")
        }
        if !yieldVaultManagerExists {
            issues.append("YieldVaultManager not found")
        }
        if !coaExists {
            issues.append("COA (Cadence Owned Account) not found")
        }
        result["issues"] = issues
        result["message"] = "Worker initialization incomplete. Run setup_worker_with_badge transaction."
    }

    return result
}
