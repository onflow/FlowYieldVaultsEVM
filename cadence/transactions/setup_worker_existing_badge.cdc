import "FlowVaultsEVM"
import "FlowVaultsClosedBeta"
import "EVM"

/// Setup Worker transaction using EXISTING beta badge
/// For users who already have a beta badge capability
///
/// @param flowVaultsRequestsAddress: The EVM address of the FlowVaultsRequests contract
///
transaction(flowVaultsRequestsAddress: String) {
    prepare(signer: auth(BorrowValue, SaveValue, LoadValue, Storage, Capabilities, CopyValue) &Account) {
        
        log("=== Starting FlowVaultsEVM Worker Setup ===")
        
        // ========================================
        // Step 1: Get existing beta badge capability
        // ========================================
        
        // You have FlowVaults beta badge at this path
        let storagePath = /storage/FlowVaultsUserBetaCap_0x3bda2f90274dbc9b
        
        let betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
            from: storagePath
        ) ?? panic("Could not copy beta badge capability from storage")
        
        log("✓ Using existing beta badge capability")
        
        // Verify the capability is valid
        let betaRef = betaBadgeCap.borrow()
            ?? panic("Beta badge capability does not contain correct reference")
        log("✓ Beta badge verified for address: ".concat(betaRef.getOwner().toString()))
        
        // ========================================
        // Step 2: Setup the Worker
        // ========================================
        
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin")
        
        // Load the existing COA from standard storage path
        let coa <- signer.storage.load<@EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not load COA from /storage/evm")
        
        log("✓ Using existing COA with address: ".concat(coa.address().toString()))
        
        // Create worker with the COA and beta badge capability
        let worker <- admin.createWorker(coa: <-coa, betaBadgeCap: betaBadgeCap)
        
        // Save worker to storage
        signer.storage.save(<-worker, to: FlowVaultsEVM.WorkerStoragePath)
        log("✓ Worker created and saved to storage")
        
        // ========================================
        // Step 3: Set FlowVaultsRequests Contract Address
        // ========================================
        
        let evmAddress = EVM.addressFromString(flowVaultsRequestsAddress)
        admin.setFlowVaultsRequestsAddress(evmAddress)
        log("✓ FlowVaultsRequests address set to: ".concat(flowVaultsRequestsAddress))
    }
}
