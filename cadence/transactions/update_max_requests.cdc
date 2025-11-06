import "FlowVaultsEVM"

/// Update the maximum number of requests to process per transaction
/// 
/// Use this to tune performance based on gas benchmarking:
/// - Lower values: More predictable gas, slower throughput
/// - Higher values: Faster throughput, risk hitting gas limits
/// 
/// Recommended range: 5-50 based on testing
/// 
/// @param newMax: The new maximum requests per transaction
///
transaction(newMax: Int) {
    prepare(signer: auth(BorrowValue) &Account) {
        
        log("=== Updating MAX_REQUESTS_PER_TX ===")
        log("Current value: ".concat(FlowVaultsEVM.MAX_REQUESTS_PER_TX.toString()))
        log("New value: ".concat(newMax.toString()))
        
        // Borrow the Admin resource
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin resource")
        
        // Update the value
        admin.updateMaxRequestsPerTx(newMax)
        
        log("✅ MAX_REQUESTS_PER_TX updated successfully")
        log("New value: ".concat(FlowVaultsEVM.MAX_REQUESTS_PER_TX.toString()))
    }
    
    post {
        FlowVaultsEVM.MAX_REQUESTS_PER_TX == newMax: "MAX_REQUESTS_PER_TX was not updated correctly"
    }
}
