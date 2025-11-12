import "FlowVaultsEVM"
import "EVM"

/// Extract the COA from the Worker resource
/// WARNING: After extraction, the Worker will no longer be functional
/// This is an emergency function to recover the COA if needed
///
/// The COA will be saved to a new storage path for manual management
transaction(newCOAStoragePath: String) {
    
    prepare(signer: auth(Storage, SaveValue, LoadValue) &Account) {
        // Load the Worker from storage
        let worker <- signer.storage.load<@FlowVaultsEVM.Worker>(
            from: FlowVaultsEVM.WorkerStoragePath
        ) ?? panic("Worker not found in storage")
        
        // Extract the COA from the Worker
        let coa <- worker.extractCOA()
        
        // Destroy the Worker (it's no longer functional without a COA)
        destroy worker
        
        // Save the COA to the new storage path
        let storagePath = StoragePath(identifier: newCOAStoragePath)
            ?? panic("Invalid storage path identifier")
        
        signer.storage.save(<-coa, to: storagePath)
        
        log("COA extracted and saved to: ".concat(storagePath.toString()))
        log("Worker destroyed (no longer functional)")
    }
}
