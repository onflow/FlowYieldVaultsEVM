import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowToken"
import "FungibleToken"
import "FlowVaultsTransactionHandler"
import "FlowVaultsEVM"

/// Schedule the first FlowVaultsEVM request processing execution
/// After this, the handler will automatically schedule subsequent executions
/// based on the smart scheduling algorithm
///
/// Arguments:
/// - delaySeconds: Initial delay before first execution (e.g., 5.0 for 5 seconds)
/// - priority: 0=High, 1=Medium, 2=Low (recommend Medium for automated processing)
/// - executionEffort: Computation units (recommend 6000+ for safety)
///
transaction(
    delaySeconds: UFix64,
    priority: UInt8,
    executionEffort: UInt64
) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, GetStorageCapabilityController, PublishCapability) &Account) {        
        // Calculate future timestamp
        let future = getCurrentBlock().timestamp + delaySeconds

        // Convert priority
        let pr = priority == 0
            ? FlowTransactionScheduler.Priority.High
            : priority == 1
                ? FlowTransactionScheduler.Priority.Medium
                : FlowTransactionScheduler.Priority.Low

        // Get the entitled handler capability
        var handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? = nil
        let controllers = signer.capabilities.storage.getControllers(forPath: FlowVaultsTransactionHandler.HandlerStoragePath)
        
        for controller in controllers {
            if let cap = controller.capability as? Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}> {
                handlerCap = cap
                break
            }
        }
        
        if handlerCap == nil {
            panic("Could not find entitled handler capability. Please run InitFlowVaultsTransactionHandler.cdc first.")
        }

        // Initialize scheduler manager if not present
        if signer.storage.borrow<&AnyResource>(from: FlowTransactionSchedulerUtils.managerStoragePath) == nil {
            let manager <- FlowTransactionSchedulerUtils.createManager()
            signer.storage.save(<-manager, to: FlowTransactionSchedulerUtils.managerStoragePath)

            let managerCapPublic = signer.capabilities.storage
                .issue<&{FlowTransactionSchedulerUtils.Manager}>(FlowTransactionSchedulerUtils.managerStoragePath)
            signer.capabilities.publish(managerCapPublic, at: FlowTransactionSchedulerUtils.managerPublicPath)
        }

        // Borrow the manager
        let manager = signer.storage
            .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                from: FlowTransactionSchedulerUtils.managerStoragePath
            ) ?? panic("Could not borrow Manager reference")

        // Estimate fees
        let est = FlowTransactionScheduler.estimate(
            data: nil,
            timestamp: future,
            priority: pr,
            executionEffort: executionEffort
        )
        
        let estimatedFee = est.flowFee ?? 0.0
        
        if est.timestamp == nil && pr != FlowTransactionScheduler.Priority.Low {
            let errorMsg = est.error ?? "estimation failed"
            panic("Fee estimation failed: ".concat(errorMsg))
        }

        // Withdraw fees from vault
        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Missing FlowToken vault")
        
        let fees <- vaultRef.withdraw(amount: estimatedFee) as! @FlowToken.Vault

        // Schedule the transaction
        let transactionId = manager.schedule(
            handlerCap: handlerCap!,
            data: nil,
            timestamp: future,
            priority: pr,
            executionEffort: executionEffort,
            fees: <-fees
        )
    }
}
