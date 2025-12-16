import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowToken"
import "FungibleToken"
import "FlowYieldVaultsTransactionHandler"
import "FlowYieldVaultsEVM"

/// @title Initialize Handler and Schedule First Execution
/// @notice Creates the transaction handler and schedules the first automated execution
/// @dev Combines init_flow_vaults_transaction_handler and schedule_initial_flow_vaults_execution.
///      Safe to run multiple times - will skip already-configured resources.
///      Execution effort and priority are calculated dynamically based on FlowYieldVaultsEVM.maxRequestsPerTx.
///
/// @param delaySeconds Initial delay before first execution (e.g., 5.0)
///
transaction(
    delaySeconds: UFix64
) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability) &Account) {
        if signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(from: FlowYieldVaultsEVM.WorkerStoragePath) == nil {
            panic("FlowYieldVaultsEVM Worker not found. Please initialize Worker first.")
        }

        if signer.storage.borrow<&AnyResource>(from: FlowYieldVaultsTransactionHandler.HandlerStoragePath) == nil {
            let workerCap = signer.capabilities.storage
                .issue<&FlowYieldVaultsEVM.Worker>(FlowYieldVaultsEVM.WorkerStoragePath)
            let handler <- FlowYieldVaultsTransactionHandler.createHandler(workerCap: workerCap)
            signer.storage.save(<-handler, to: FlowYieldVaultsTransactionHandler.HandlerStoragePath)
        }

        let handlerCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowYieldVaultsTransactionHandler.HandlerStoragePath
            )

        if signer.storage.borrow<&AnyResource>(from: FlowTransactionSchedulerUtils.managerStoragePath) == nil {
            let manager <- FlowTransactionSchedulerUtils.createManager()
            signer.storage.save(<-manager, to: FlowTransactionSchedulerUtils.managerStoragePath)

            let managerCapPublic = signer.capabilities.storage
                .issue<&{FlowTransactionSchedulerUtils.Manager}>(FlowTransactionSchedulerUtils.managerStoragePath)
            signer.capabilities.publish(managerCapPublic, at: FlowTransactionSchedulerUtils.managerPublicPath)
        }

        let manager = signer.storage
            .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                from: FlowTransactionSchedulerUtils.managerStoragePath
            ) ?? panic("Could not borrow Manager reference")

        let future = getCurrentBlock().timestamp + delaySeconds

        // Calculate execution effort and priority dynamically based on maxRequestsPerTx
        let maxRequestsPerTx = FlowYieldVaultsEVM.getMaxRequestsPerTx()
        let effortAndPriority = FlowYieldVaultsTransactionHandler.calculateExecutionEffortAndPriority(maxRequestsPerTx)
        let executionEffort = effortAndPriority["effort"]! as! UInt64
        let priorityRaw = effortAndPriority["priority"]! as! UInt8
        
        let pr = priorityRaw == 0
            ? FlowTransactionScheduler.Priority.High
            : FlowTransactionScheduler.Priority.Medium

        let est = FlowTransactionScheduler.estimate(
            data: [],
            timestamp: future,
            priority: pr,
            executionEffort: executionEffort
        )

        let estimatedFee = est.flowFee ?? 0.0

        if est.timestamp == nil && pr != FlowTransactionScheduler.Priority.Low {
            let errorMsg = est.error ?? "estimation failed"
            panic("Fee estimation failed: ".concat(errorMsg))
        }

        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Missing FlowToken vault")

        let fees <- vaultRef.withdraw(amount: estimatedFee) as! @FlowToken.Vault

        let transactionId = manager.schedule(
            handlerCap: handlerCap,
            data: [],
            timestamp: future,
            priority: pr,
            executionEffort: executionEffort,
            fees: <-fees
        )
    }
}
