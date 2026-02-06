import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowToken"
import "FungibleToken"
import "FlowYieldVaultsEVMWorkerOps"
import "FlowYieldVaultsEVM"

/// @title Initialize Handlers and Schedule First Execution
/// @notice Creates the WorkerHandler and SchedulerHandler and schedules the first executions
/// @dev Flow:
///      1. Initialize the manager if it doesn't exist
///      2. Initialize the WorkerHandler if it doesn't exist
///      3. Initialize the SchedulerHandler if it doesn't exist
///      4. Schedule the first dummy WorkerHandler transaction to register the WorkerHandler in the manager
///      5. Schedule the scheduler
///
transaction {

    let workerHandlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
    let schedulerHandlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
    let manager: auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}
    let feeVaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability) &Account) {
        pre {
            signer.storage.borrow<&FlowYieldVaultsEVM.Admin>(from: FlowYieldVaultsEVM.AdminStoragePath) != nil:
                "FlowYieldVaultsEVM Admin not found."
            signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(from: FlowYieldVaultsEVM.WorkerStoragePath) != nil:
                "FlowYieldVaultsEVM Worker not found."
        }

        // Initialize the manager if it doesn't exist
        if signer.storage.borrow<&AnyResource>(from: FlowTransactionSchedulerUtils.managerStoragePath) == nil {
            let manager <- FlowTransactionSchedulerUtils.createManager()
            signer.storage.save(<-manager, to: FlowTransactionSchedulerUtils.managerStoragePath)

            let managerCapPublic = signer.capabilities.storage
                .issue<&{FlowTransactionSchedulerUtils.Manager}>(FlowTransactionSchedulerUtils.managerStoragePath)
            signer.capabilities.publish(managerCapPublic, at: FlowTransactionSchedulerUtils.managerPublicPath)
        }

        // Load manager
        self.manager = signer.storage
            .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                from: FlowTransactionSchedulerUtils.managerStoragePath
            ) ?? panic("Could not borrow Manager reference")

        // Load WorkerOps Admin
        let opsAdmin = signer.storage
            .borrow<&FlowYieldVaultsEVMWorkerOps.Admin>
            (from: FlowYieldVaultsEVMWorkerOps.AdminStoragePath)
            ?? panic("Could not borrow FlowYieldVaultsEVMWorkerOps Admin")

        // Issue the worker capability for WorkerHandler resources
        let workerCap = signer.capabilities.storage
            .issue<&FlowYieldVaultsEVM.Worker>(FlowYieldVaultsEVM.WorkerStoragePath)

        // Initialize SchedulerHandler resource if it doesn't exist
        if signer.storage.borrow<&AnyResource>(from: FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath) == nil {
            let handler <- opsAdmin.createSchedulerHandler(workerCap: workerCap)
            signer.storage.save(<-handler, to: FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath)
        }

        // Initialize WorkerHandler resource if it doesn't exist
        if signer.storage.borrow<&AnyResource>(from: FlowYieldVaultsEVMWorkerOps.WorkerHandlerStoragePath) == nil {
            let handler <- opsAdmin.createWorkerHandler(workerCap: workerCap)
            signer.storage.save(<-handler, to: FlowYieldVaultsEVMWorkerOps.WorkerHandlerStoragePath)
        }

        // Issue capability to SchedulerHandler for scheduling
        self.schedulerHandlerCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath
            )

        // Issue capability to WorkerHandler for scheduling
        self.workerHandlerCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowYieldVaultsEVMWorkerOps.WorkerHandlerStoragePath
            )

        // Load FlowToken vault for fees
        self.feeVaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Missing FlowToken vault")

    }

    execute {

        // Schedule first dummy WorkerHandler transaction to register the WorkerHandler in the manager
        let transactionId = _scheduleTransaction(
            manager: self.manager,
            handlerCap: self.workerHandlerCap,
            feeVaultRef: self.feeVaultRef
        )

        // Schedule scheduler
        let schedulerTransactionId = _scheduleTransaction(
            manager: self.manager,
            handlerCap: self.schedulerHandlerCap,
            feeVaultRef: self.feeVaultRef
        )

    }

}

/// @notice Helper function to schedule a transaction
/// @dev Flow:
///      1. Calculate the target execution timestamp
///      2. Estimate fees and withdraw payment
///      3. Schedule the transaction
/// @param manager The manager
/// @param handlerCap The capability to the handler
/// @param feeVaultRef The vault to withdraw fees from
/// @return The transaction ID
access(self) fun _scheduleTransaction(
    manager: auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager},
    handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
    feeVaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault,
): UInt64 {
    // Calculate the target execution timestamp
    let future = getCurrentBlock().timestamp + 1.0

    // Estimate fees and withdraw payment
    let estimate = FlowTransactionScheduler.estimate(
        data: nil,
        timestamp: future,
        priority: FlowTransactionScheduler.Priority.Medium,
        executionEffort: 7500
    )
    let fees <- feeVaultRef.withdraw(amount: estimate.flowFee ?? 0.0) as! @FlowToken.Vault

    // Schedule the next execution
    let transactionId = manager.schedule(
        handlerCap: handlerCap,
        data: nil,
        timestamp: future,
        priority: FlowTransactionScheduler.Priority.Medium,
        executionEffort: 7500,
        fees: <-fees
    )

    return transactionId
}
