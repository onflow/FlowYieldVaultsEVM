import "FlowYieldVaultsEVMWorkerOps"

/// @title Unpause Scheduler Handler
/// @notice Unpauses the scheduler handler
/// @dev After unpausing, new requests will be scheduled.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsEVMWorkerOps.Admin>(
            from: FlowYieldVaultsEVMWorkerOps.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.unpauseScheduler()
    }
}
