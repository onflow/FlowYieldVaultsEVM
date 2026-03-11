import "FlowYieldVaultsEVMWorkerOps"

/// @title Set Scheduler Wakeup Interval
/// @notice Sets the recurrent wakeup interval for the SchedulerHandler
/// @dev Only the account with the Admin resource stored can execute this transaction.
///
/// @param schedulerWakeupInterval The delay in seconds between scheduler runs
///
transaction(schedulerWakeupInterval: UFix64) {
    let admin: &FlowYieldVaultsEVMWorkerOps.Admin

    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage.borrow<&FlowYieldVaultsEVMWorkerOps.Admin>(
            from: FlowYieldVaultsEVMWorkerOps.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
    }

    execute {
        self.admin.setSchedulerWakeupInterval(schedulerWakeupInterval: schedulerWakeupInterval)
    }
}
