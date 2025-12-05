import "FlowYieldVaultsTransactionHandler"

/// @title Check Delay for Pending Count
/// @notice Returns the scheduling delay for a given number of pending requests
/// @dev Useful for understanding the smart scheduling algorithm behavior
/// @param pendingRequests Number of pending requests to check
/// @return Dictionary with delay info and load category
///
access(all) fun main(pendingRequests: Int): {String: AnyStruct} {
    let delay = FlowYieldVaultsTransactionHandler.getDelayForPendingCount(pendingRequests)
    let defaultDelay = FlowYieldVaultsTransactionHandler.defaultDelay
    let thresholds = FlowYieldVaultsTransactionHandler.thresholdToDelay

    return {
        "pendingRequests": pendingRequests,
        "delaySeconds": delay,
        "defaultDelay": defaultDelay,
        "thresholds": thresholds,
        "loadCategory": getLoadCategory(delay)
    }
}

access(all) fun getLoadCategory(_ delay: UFix64): String {
    if delay <= 15.0 {
        return "HIGH"
    } else if delay <= 45.0 {
        return "MEDIUM"
    } else {
        return "LOW"
    }
}
