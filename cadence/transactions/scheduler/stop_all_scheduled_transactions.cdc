import "FlowYieldVaultsEVMWorkerOps"

/// @title Stop All Scheduled Transactions
/// @notice Pauses scheduler execution and cancels tracked in-flight WorkerHandler transactions
/// @dev This will:
///      1. Pause the handler to prevent new scheduling
///      2. Cancel WorkerHandler transactions tracked in FlowYieldVaultsEVMWorkerOps.scheduledRequests
///      3. Cancel the next scheduler transaction ID stored on SchedulerHandler
///      4. Refund fees to the contract account
///      Requires Admin resource.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsEVMWorkerOps.Admin>(
            from: FlowYieldVaultsEVMWorkerOps.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.stopAll()
    }
}
