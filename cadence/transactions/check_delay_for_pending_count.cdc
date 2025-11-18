import "FlowVaultsTransactionHandler"

/// Query what delay would be used for a given number of pending requests
/// Useful for understanding and testing the smart scheduling algorithm
///
/// Arguments:
/// - pendingRequests: Number of pending requests to check
///
/// Returns:
/// - delayLevel: Index in DELAY_LEVELS array (0-9)
/// - delaySeconds: Delay that would be used
/// - description: Human-readable description
///
access(all) fun main(pendingRequests: Int): {String: AnyStruct} {
    let delayLevel = FlowVaultsTransactionHandler.getDelayLevel(pendingRequests)
    let delay = FlowVaultsTransactionHandler.DELAY_LEVELS[delayLevel]
    
    return {
        "pendingRequests": pendingRequests,
        "delayLevel": delayLevel,
        "delaySeconds": delay,
        "description": getDescription(delayLevel),
        "loadCategory": getLoadCategory(delayLevel)
    }
}

access(all) fun getDescription(_ level: Int): String {
    switch level {
        case 0: return "Extreme Load - Process every 5 seconds"
        case 1: return "Very High Load - Process every 10 seconds"
        case 2: return "High Load - Process every 15 seconds"
        case 3: return "Medium-High Load - Process every 20 seconds"
        case 4: return "Medium Load - Process every 30 seconds"
        case 5: return "Medium-Low Load - Process every 45 seconds"
        case 6: return "Low Load - Process every 60 seconds"
        case 7: return "Very Low Load - Process every 60 seconds"
        case 8: return "Minimal Load - Process every 60 seconds"
        case 9: return "Idle - Process every 60 seconds"
        default: return "Unknown"
    }
}

access(all) fun getLoadCategory(_ level: Int): String {
    if level <= 2 {
        return "HIGH"
    } else if level <= 5 {
        return "MEDIUM"
    } else {
        return "LOW"
    }
}
