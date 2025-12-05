import "FlowYieldVaultsTransactionHandler"
import "FlowYieldVaultsEVM"

/// @title Get Parallel Config
/// @notice Returns the current parallel transaction configuration
/// @return Dictionary with maxParallelTxn, maxRequestsPerTx, and processing capacity
///
access(all) fun main(): {String: AnyStruct} {
    let maxParallelTxn = FlowYieldVaultsTransactionHandler.maxParallelTransactions
    let maxRequestsPerTx = FlowYieldVaultsEVM.maxRequestsPerTx
    let maxRequestsPerBatch = maxParallelTxn * maxRequestsPerTx

    return {
        "maxParallelTxn": maxParallelTxn,
        "maxRequestsPerTx": maxRequestsPerTx,
        "maxRequestsPerBatch": maxRequestsPerBatch,
        "isPaused": FlowYieldVaultsTransactionHandler.isPaused
    }
}
