import "FlowVaultsEVM"
import "EVM"

/// Extract and then immediately re-inject the COA back into the Worker
/// This is a demonstration/test transaction showing both operations work
transaction() {
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow the Worker from storage
        let worker = signer.storage.borrow<&FlowVaultsEVM.Worker>(
            from: FlowVaultsEVM.WorkerStoragePath
        ) ?? panic("Worker not found in storage")
        
        log("Step 1: Getting COA address before extraction")
        let coaAddressBefore = worker.getCOAAddressString()
        log("COA Address: ".concat(coaAddressBefore))
        
        log("Step 2: Extracting COA from Worker")
        let coa <- worker.extractCOA()
        log("COA extracted successfully")
        
        log("Step 3: Re-injecting COA back into Worker")
        worker.injectCOA(coa: <-coa)
        log("COA re-injected successfully")
        
        log("Step 4: Verifying COA address after re-injection")
        let coaAddressAfter = worker.getCOAAddressString()
        log("COA Address: ".concat(coaAddressAfter))
        
        assert(coaAddressBefore == coaAddressAfter, message: "COA address mismatch!")
        log("Success! COA extraction and injection work correctly")
    }
}
