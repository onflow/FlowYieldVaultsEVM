import "FlowVaultsEVM"
import "EVM"

/// Inject a COA into an existing Worker resource
/// This allows re-enabling a Worker after COA extraction or replacing a COA
///
/// The COA will be loaded from the specified storage path and injected into the Worker
transaction(coaStoragePath: String) {
    
    prepare(signer: auth(Storage, LoadValue) &Account) {
        // Load the COA from storage
        let storagePath = StoragePath(identifier: coaStoragePath)
            ?? panic("Invalid storage path identifier")
        
        let coa <- signer.storage.load<@EVM.CadenceOwnedAccount>(from: storagePath)
            ?? panic("COA not found at specified storage path")
        
        // Borrow the Worker from storage
        let worker = signer.storage.borrow<&FlowVaultsEVM.Worker>(
            from: FlowVaultsEVM.WorkerStoragePath
        ) ?? panic("Worker not found in storage")
        
        // Inject the COA into the Worker
        worker.injectCOA(coa: <-coa)
        
        log("COA injected into Worker successfully")
        log("Worker is now functional again")
    }
}
