import "FlowVaultsTransactionHandler"
import "FlowTransactionScheduler"
import "FlowVaultsEVM"

/// @title Initialize FlowVaults Transaction Handler
/// @notice Creates and configures the automated transaction handler
/// @dev Run once after FlowVaultsEVM Worker is set up. Creates Handler resource
///      and issues both entitled and public capabilities for scheduling.
///
transaction() {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability) &Account) {
        if signer.storage.borrow<&FlowVaultsEVM.Worker>(from: FlowVaultsEVM.WorkerStoragePath) == nil {
            panic("FlowVaultsEVM Worker not found. Please initialize Worker first.")
        }

        let workerCap = signer.capabilities.storage
            .issue<&FlowVaultsEVM.Worker>(FlowVaultsEVM.WorkerStoragePath)

        if signer.storage.borrow<&AnyResource>(from: FlowVaultsTransactionHandler.HandlerStoragePath) == nil {
            let handler <- FlowVaultsTransactionHandler.createHandler(workerCap: workerCap)
            signer.storage.save(<-handler, to: FlowVaultsTransactionHandler.HandlerStoragePath)
        }

        let entitledCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowVaultsTransactionHandler.HandlerStoragePath
            )

        let publicCap = signer.capabilities.storage
            .issue<&{FlowTransactionScheduler.TransactionHandler}>(
                FlowVaultsTransactionHandler.HandlerStoragePath
            )
        signer.capabilities.publish(publicCap, at: FlowVaultsTransactionHandler.HandlerPublicPath)
    }
}
