import "FlowTransactionScheduler"
import "FlowYieldVaultsEVMWorkerOps"

/// @title Run Scheduler Manually With Capacity
/// @notice Runs the scheduler manually with an explicit run capacity
/// @dev Test-only helper for forcing preprocessing/scheduling without waiting for recurrent runs
/// @param runCapacity The number of pending requests this manual run is allowed to preprocess
transaction(runCapacity: UInt8) {
    let schedulerHandlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>

    prepare(signer: auth(Capabilities, IssueStorageCapabilityController) &Account) {
        let existingControllers = signer.capabilities.storage.getControllers(
            forPath: FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath
        )

        if existingControllers.length > 0 {
            self.schedulerHandlerCap = existingControllers[0].capability
                as! Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
        } else {
            self.schedulerHandlerCap = signer.capabilities.storage
                .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                    FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath
                )
        }
    }

    execute {
        self.schedulerHandlerCap.borrow()!.executeTransaction(
            id: 42,
            data: runCapacity
        )
    }
}
