import "FlowTransactionScheduler"
import "FlowYieldVaultsEVMWorkerOps"

/// @title Run Scheduler Manually
/// @notice Runs the scheduler manually
/// @dev Flow:
///      1. Issue a storage capability to the SchedulerHandler resource
///      2. Borrow the SchedulerHandler resource and call executeTransaction
///
transaction {
    let schedulerHandlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.schedulerHandlerCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath
            )
    }

    execute {
        self.schedulerHandlerCap.borrow()!.executeTransaction(
            id: 42,
            data: nil
        )
    }
}