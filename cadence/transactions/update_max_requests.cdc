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
        
        // Borrow the Admin resource
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin resource")
        // Update the value
        admin.updateMaxRequestsPerTx(newMax)
    }
    
    post {
        FlowVaultsEVM.MAX_REQUESTS_PER_TX == newMax: "MAX_REQUESTS_PER_TX was not updated correctly"
    }
}
