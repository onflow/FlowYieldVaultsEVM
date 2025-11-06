import "FlowVaultsTransactionHandler"
import "FlowVaultsEVM"
import "FlowTransactionScheduler"

/// Get statistics about the FlowVaultsTransactionHandler
/// Returns execution count, last execution time, and current delay recommendation
/// All data is read directly from the contract
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
    let workerCap = account.capabilities.get<&FlowVaultsEVM.Worker>(
        FlowVaultsEVM.WorkerPublicPath
    )
    
    var pendingRequests = 0
    var recommendedDelay: UFix64 = FlowVaultsTransactionHandler.DELAY_LEVELS[4]  // Default to slowest
    var delayLevel = 4  // Default to level 4 (very low/idle)
    
    if workerCap.check() {
        let worker = workerCap.borrow()!
        let requests = worker.getPendingRequestsFromEVM()
        pendingRequests = requests.length
        // Read delay level directly from contract function
        delayLevel = FlowVaultsTransactionHandler.getDelayLevel(pendingRequests)
        // Read recommended delay directly from contract
        recommendedDelay = FlowVaultsTransactionHandler.getDelayForPendingCount(pendingRequests)
    }
    
    // Build delay level descriptions dynamically from contract data
    let delayDescriptions: {Int: String} = {}
    var i = 0
    while i < FlowVaultsTransactionHandler.DELAY_LEVELS.length {
        let threshold = FlowVaultsTransactionHandler.LOAD_THRESHOLDS[i]
        let delay = FlowVaultsTransactionHandler.DELAY_LEVELS[i]
        let description = buildDelayDescription(level: i, threshold: threshold, delay: delay)
        delayDescriptions[i] = description
        i = i + 1
    }
    
    return {
        "handlerExists": workerCap.check(),
        "handlerAddress": accountAddress.toString(),
        "currentPendingRequests": pendingRequests,
        "recommendedDelaySeconds": recommendedDelay,
        "delayLevel": delayLevel,
        "delayLevelDescription": delayDescriptions[delayLevel] ?? "Unknown",
        "allDelayLevels": FlowVaultsTransactionHandler.DELAY_LEVELS,
        "loadThresholds": FlowVaultsTransactionHandler.LOAD_THRESHOLDS,
        "allDelayDescriptions": delayDescriptions
    }
}

access(all) fun buildDelayDescription(level: Int, threshold: Int, delay: UFix64): String {
    let levelName = getLevelName(level)
    let thresholdText = getThresholdText(level, threshold)
    return levelName.concat(" ").concat(thresholdText).concat(" - ").concat(delay.toString()).concat("s")
}

access(all) fun getLevelName(_ level: Int): String {
    switch level {
        case 0: return "High Load"
        case 1: return "Medium-High Load"
        case 2: return "Medium Load"
        case 3: return "Low Load"
        case 4: return "Very Low/Idle"
        default: return "Unknown Level"
    }
}

access(all) fun getThresholdText(_ level: Int, _ threshold: Int): String {
    if level == 4 {
        return "(<".concat(FlowVaultsTransactionHandler.LOAD_THRESHOLDS[3].toString()).concat(" requests)")
    }
    return "(>=".concat(threshold.toString()).concat(" requests)")
}
