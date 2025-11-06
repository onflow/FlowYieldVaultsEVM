import "FlowVaultsTransactionHandler"
import "FlowVaultsEVM"

/// Get statistics about the FlowVaultsTransactionHandler
/// Returns execution count, last execution time, and current delay recommendation
///
access(all) fun main(accountAddress: Address): {String: AnyStruct} {
    let account = getAccount(accountAddress)
    
    // Get handler capability
    let handlerCap = account.capabilities.get<&{FlowTransactionScheduler.TransactionHandler}>(
        FlowVaultsTransactionHandler.HandlerPublicPath
    )
    
    if !handlerCap.check() {
        return {
            "error": "Handler not found or capability invalid",
            "handlerExists": false
        }
    }
    
    let handler = handlerCap.borrow()!
    
    // Get worker to check pending requests
    let workerCap = account.capabilities.storage.borrow<&FlowVaultsEVM.Worker>(
        from: FlowVaultsEVM.WorkerStoragePath
    )
    
    var pendingRequests = 0
    var recommendedDelay: UFix64 = 60.0
    var delayLevel = 9
    
    if workerCap != nil {
        let requests = workerCap!.getPendingRequestsFromEVM()
        pendingRequests = requests.length
        delayLevel = FlowVaultsTransactionHandler.getDelayLevel(pendingRequests)
        recommendedDelay = FlowVaultsTransactionHandler.DELAY_LEVELS[delayLevel]
    }
    
    return {
        "handlerExists": true,
        "handlerAddress": accountAddress.toString(),
        "currentPendingRequests": pendingRequests,
        "recommendedDelaySeconds": recommendedDelay,
        "delayLevel": delayLevel,
        "delayLevelDescription": getDelayLevelDescription(delayLevel),
        "allDelayLevels": FlowVaultsTransactionHandler.DELAY_LEVELS,
        "loadThresholds": FlowVaultsTransactionHandler.LOAD_THRESHOLDS
    }
}

access(all) fun getDelayLevelDescription(_ level: Int): String {
    switch level {
        case 0: return "Extreme Load (>=100 requests) - 5s"
        case 1: return "Very High Load (>=80 requests) - 10s"
        case 2: return "High Load (>=60 requests) - 15s"
        case 3: return "Medium-High Load (>=40 requests) - 20s"
        case 4: return "Medium Load (>=25 requests) - 30s"
        case 5: return "Medium-Low Load (>=15 requests) - 45s"
        case 6: return "Low Load (>=10 requests) - 60s"
        case 7: return "Very Low Load (>=5 requests) - 60s"
        case 8: return "Minimal Load (>=1 request) - 60s"
        case 9: return "Idle (0 requests) - 60s"
        default: return "Unknown"
    }
}
