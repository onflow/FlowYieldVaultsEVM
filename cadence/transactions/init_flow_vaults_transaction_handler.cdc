import "FlowVaultsTransactionHandler"
import "FlowTransactionScheduler"
import "FlowVaultsEVM"

/// Initialize the FlowVaultsTransactionHandler
/// This should be run once after FlowVaultsEVM Worker is set up
///
/// This transaction:
/// 1. Creates a capability to the FlowVaultsEVM Worker
/// 2. Creates and saves the Handler resource
/// 3. Issues both entitled and public capabilities for the handler
///
transaction() {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability) &Account) {        
        // Check if Worker exists
        if signer.storage.borrow<&FlowVaultsEVM.Worker>(from: FlowVaultsEVM.WorkerStoragePath) == nil {
            panic("FlowVaultsEVM Worker not found. Please initialize Worker first.")
        }
        
        // Create a capability to the Worker
        let workerCap = signer.capabilities.storage
            .issue<&FlowVaultsEVM.Worker>(FlowVaultsEVM.WorkerStoragePath)
                
        // Create and save the handler with the worker capability
        if signer.storage.borrow<&AnyResource>(from: FlowVaultsTransactionHandler.HandlerStoragePath) == nil {
            let handler <- FlowVaultsTransactionHandler.createHandler(workerCap: workerCap)
            signer.storage.save(<-handler, to: FlowVaultsTransactionHandler.HandlerStoragePath)
        }

        // Issue an entitled capability for the scheduler to call executeTransaction - VALIDATION for future calls
        let entitledCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(
                FlowVaultsTransactionHandler.HandlerStoragePath
            )

        // Issue a public capability for general access
        let publicCap = signer.capabilities.storage
            .issue<&{FlowTransactionScheduler.TransactionHandler}>(
                FlowVaultsTransactionHandler.HandlerStoragePath
            )
        signer.capabilities.publish(publicCap, at: FlowVaultsTransactionHandler.HandlerPublicPath)
    }
}
