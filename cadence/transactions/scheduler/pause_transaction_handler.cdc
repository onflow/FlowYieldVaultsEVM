import "FlowYieldVaultsEVMWorkerOps"

/// @title Pause Scheduler Handler
/// @notice Pauses the scheduler handler
/// @dev When paused, no new requests will be scheduled.
///      Requires Admin resource.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsEVMWorkerOps.Admin>(
            from: FlowYieldVaultsEVMWorkerOps.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.pauseScheduler()
    }
}
