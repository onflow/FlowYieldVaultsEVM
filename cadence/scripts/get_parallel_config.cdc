import "FlowVaultsTransactionHandler"
import "FlowVaultsEVM"

/// @title Get Parallel Config
/// @notice Returns the current parallel transaction configuration
/// @return Dictionary with maxParallelTxn, maxRequestsPerTx, and processing capacity
///
access(all) fun main(): {String: AnyStruct} {
    let maxParallelTxn = FlowVaultsTransactionHandler.maxParallelTransactions
    let maxRequestsPerTx = FlowVaultsEVM.maxRequestsPerTx
    let maxRequestsPerBatch = maxParallelTxn * maxRequestsPerTx

    return {
        "maxParallelTxn": maxParallelTxn,
        "maxRequestsPerTx": maxRequestsPerTx,
        "maxRequestsPerBatch": maxRequestsPerBatch,
        "isPaused": FlowVaultsTransactionHandler.isPaused
    }
}
