import "FlowYieldVaultsTransactionHandler"

/// @title Update Execution Effort Parameters
/// @notice Updates the parameters used to calculate execution effort dynamically
/// @dev Formula: executionEffort = baseEffortPerRequest * maxRequestsPerTx + baseOverhead
///      When idle (0 pending requests), uses idleExecutionEffort with Medium priority
///
/// @param baseEffortPerRequest Effort units per request (e.g., 2000 for EVM calls)
/// @param baseOverhead Fixed overhead regardless of request count (e.g., 3000)
/// @param idleExecutionEffort Minimal effort when no pending requests (e.g., 5000 for Medium priority)
///
transaction(baseEffortPerRequest: UInt64, baseOverhead: UInt64, idleExecutionEffort: UInt64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsTransactionHandler.Admin>(
            from: FlowYieldVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.setExecutionEffortParams(
            baseEffortPerRequest: baseEffortPerRequest,
            baseOverhead: baseOverhead,
            idleExecutionEffort: idleExecutionEffort
        )
    }
}
