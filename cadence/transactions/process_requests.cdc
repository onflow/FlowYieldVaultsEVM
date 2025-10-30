// process_requests.cdc
import "TidalEVMWorker"

/// Transaction to process all pending requests from TidalRequests contract
/// This will create Tides for any pending CREATE_TIDE requests
///
/// Run this after users have created requests on the EVM side
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        
        // Borrow the Worker from storage
        let worker = signer.storage.borrow<&TidalEVMWorker.Worker>(
            from: TidalEVMWorker.WorkerStoragePath
        ) ?? panic("Could not borrow Worker from storage")
        
        log("=== Processing Pending Requests ===")
        log("Worker COA address: ".concat(worker.getCOAAddressString()))
        
        // Process all pending requests
        worker.processRequests()
        
        log("=== Processing Complete ===")
    }
}
