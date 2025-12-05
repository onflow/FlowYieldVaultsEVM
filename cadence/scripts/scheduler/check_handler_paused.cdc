import "FlowYieldVaultsTransactionHandler"

/// @title Check Handler Paused
/// @notice Returns whether the transaction handler is currently paused
/// @return True if paused, false otherwise
///
access(all) fun main(): Bool {
    return FlowYieldVaultsTransactionHandler.isPaused
}
