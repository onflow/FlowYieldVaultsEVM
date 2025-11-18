import "FlowVaultsTransactionHandler"

/// Check if the transaction handler is paused
access(all) fun main(): Bool {
    return FlowVaultsTransactionHandler.isPausedState()
}
