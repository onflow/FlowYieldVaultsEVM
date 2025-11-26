import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowToken"
import "FungibleToken"
import "FlowVaultsTransactionHandler"
import "FlowVaultsEVM"

/// @title Initialize Handler and Schedule First Execution
/// @notice Creates the transaction handler and schedules the first automated execution
/// @dev Combines init_flow_vaults_transaction_handler and schedule_initial_flow_vaults_execution.
///      Safe to run multiple times - will skip already-configured resources.
///
/// @param delaySeconds Initial delay before first execution (e.g., 5.0)
/// @param priority 0=High, 1=Medium, 2=Low (recommend Medium)
/// @param executionEffort Computation units (max 7499)
///
transaction(
    delaySeconds: UFix64,
    priority: UInt8,
    executionEffort: UInt64
) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability) &Account) {
        if signer.storage.borrow<&FlowVaultsEVM.Worker>(from: FlowVaultsEVM.WorkerStoragePath) == nil {
            panic("FlowVaultsEVM Worker not found. Please initialize Worker first.")
        }

        if signer.storage.borrow<&AnyResource>(from: FlowVaultsTransactionHandler.HandlerStoragePath) == nil {
            let workerCap = signer.capabilities.storage
                .issue<&FlowVaultsEVM.Worker>(FlowVaultsEVM.WorkerStoragePath)
            let handler <- FlowVaultsTransactionHandler.createHandler(workerCap: workerCap)
            signer.storage.save(<-handler, to: FlowVaultsTransactionHandler.HandlerStoragePath)
        }

        let handlerCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowVaultsTransactionHandler.HandlerStoragePath
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

        let pr = priority == 0
            ? FlowTransactionScheduler.Priority.High
            : priority == 1
                ? FlowTransactionScheduler.Priority.Medium
                : FlowTransactionScheduler.Priority.Low

        let schedulingData: [AnyStruct] = [priority, executionEffort]

        let est = FlowTransactionScheduler.estimate(
            data: schedulingData,
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
            data: schedulingData,
            timestamp: future,
            priority: pr,
            executionEffort: executionEffort,
            fees: <-fees
        )
    }
}
