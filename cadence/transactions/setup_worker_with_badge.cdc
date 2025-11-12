import "FlowVaultsEVM"
import "FlowVaultsClosedBeta"
import "EVM"

/// Setup Worker transaction for FlowVaultsEVM Intermediate Package
/// Handles both new beta badge creation and existing beta badge usage
///
/// @param flowVaultsRequestsAddress: The EVM address of the FlowVaultsRequests contract
///
transaction(flowVaultsRequestsAddress: String) {
    prepare(signer: auth(BorrowValue, SaveValue, LoadValue, Storage, Capabilities, CopyValue, IssueStorageCapabilityController) &Account) {
        
        log("=== Starting FlowVaultsEVM Worker Setup ===")
        
        // ========================================
        // Step 1: Get or create beta badge capability
        // ========================================
        
        var betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>? = nil
        
        // First, try to find existing beta badge in standard storage path
        let standardStoragePath = FlowVaultsClosedBeta.UserBetaCapStoragePath
        if signer.storage.type(at: standardStoragePath) != nil {
            betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
                from: standardStoragePath
            )
            log("✓ Using existing beta badge capability from standard path")
        }
        
        // If not found in standard path, try the specific user path
        if betaBadgeCap == nil {
            let userSpecificPath = /storage/FlowVaultsUserBetaCap_0x3bda2f90274dbc9b
            if signer.storage.type(at: userSpecificPath) != nil {
                betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
                    from: userSpecificPath
                )
                log("✓ Using existing beta badge capability from user-specific path")
            }
        }
        
        // If still no beta badge found, create a new one (requires Admin)
        if betaBadgeCap == nil {
            log("• No existing beta badge found. Granting new beta badge...")
            
            let betaAdminHandle = signer.storage.borrow<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>(
                from: FlowVaultsClosedBeta.AdminHandleStoragePath
            ) ?? panic("Could not borrow AdminHandle - you need admin access or an existing beta badge")
            
            betaBadgeCap = betaAdminHandle.grantBeta(addr: signer.address)
            signer.storage.save(betaBadgeCap!, to: standardStoragePath)
            log("✓ Beta badge capability created and saved")
        }
        
        // Verify the capability is valid
        let betaRef = betaBadgeCap!.borrow()
            ?? panic("Beta badge capability does not contain correct reference")
        log("✓ Beta badge verified for address: ".concat(betaRef.getOwner().toString()))
        
        // ========================================
        // Step 2: Setup COA capability
        // ========================================
        
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin")
        
        // Issue a storage capability to the COA at /storage/evm
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount>(
            /storage/evm
        )
        
        // Verify the capability works
        let coaRef = coaCap.borrow()
            ?? panic("Could not borrow COA capability from /storage/evm")
        log("✓ Using COA with address: ".concat(coaRef.address().toString()))
        
        // Create worker with the COA capability and beta badge capability
        let worker <- admin.createWorker(coaCap: coaCap, betaBadgeCap: betaBadgeCap!)
        
        // Save worker to storage
        signer.storage.save(<-worker, to: FlowVaultsEVM.WorkerStoragePath)
        log("✓ Worker created and saved to storage")
        
        // ========================================
        // Step 3: Set FlowVaultsRequests Contract Address
        // ========================================
        
        let evmAddress = EVM.addressFromString(flowVaultsRequestsAddress)
        admin.setFlowVaultsRequestsAddress(evmAddress)
        log("✓ FlowVaultsRequests address set to: ".concat(flowVaultsRequestsAddress))
        
        log("=== FlowVaultsEVM Worker Setup Complete ===")
    }
}