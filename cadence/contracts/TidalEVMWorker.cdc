import "FungibleToken"
import "FlowToken"
import "EVM"

import "TidalYield"
import "TidalYieldClosedBeta"

/// TidalEVMWorker: Bridge contract that processes requests from EVM users
/// and manages their Tide positions in Cadence
/// 
/// Security Model:
/// - Singleton pattern: Worker created in init() and stored in contract account
/// - Only contract account can set TidalRequests address
/// - Only contract account can create/access Worker
access(all) contract TidalEVMWorker {
    
    // ========================================
    // Paths
    // ========================================
    
    access(all) let WorkerStoragePath: StoragePath
    access(all) let WorkerPublicPath: PublicPath
    access(all) let AdminStoragePath: StoragePath
    
    // ========================================
    // State
    // ========================================
    
    /// Mapping of EVM addresses (as hex strings) to their Tide IDs
    /// Example: "0x1234..." => [1, 5, 12]
    access(all) let tidesByEVMAddress: {String: [UInt64]}
    
    /// TidalRequests contract address on EVM side
    /// Can only be set by Admin
    access(all) var tidalRequestsAddress: EVM.EVMAddress?
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event WorkerInitialized(coaAddress: String)
    access(all) event TidalRequestsAddressSet(address: String)
    access(all) event RequestsProcessed(count: Int, successful: Int, failed: Int)
    access(all) event TideCreatedForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)
    access(all) event TideClosedForEVMUser(evmAddress: String, tideId: UInt64, amountReturned: UFix64)

    // ========================================
    // Structs
    // ========================================
    
    /// Represents a request from EVM side
    access(all) struct EVMRequest {
        access(all) let id: UInt256
        access(all) let user: EVM.EVMAddress
        access(all) let requestType: UInt8
        access(all) let status: UInt8
        access(all) let tokenAddress: EVM.EVMAddress
        access(all) let amount: UInt256
        access(all) let tideId: UInt64
        access(all) let timestamp: UInt256
        
        init(
            id: UInt256,
            user: EVM.EVMAddress,
            requestType: UInt8,
            status: UInt8,
            tokenAddress: EVM.EVMAddress,
            amount: UInt256,
            tideId: UInt64,
            timestamp: UInt256
        ) {
            self.id = id
            self.user = user
            self.requestType = requestType
            self.status = status
            self.tokenAddress = tokenAddress
            self.amount = amount
            self.tideId = tideId
            self.timestamp = timestamp
        }
    }
    
    access(all) struct ProcessResult {
        access(all) let success: Bool
        access(all) let tideId: UInt64
        
        init(success: Bool, tideId: UInt64) {
            self.success = success
            self.tideId = tideId
        }
    }
    
    // ========================================
    // Admin Resource
    // ========================================
    
    /// Admin capability for managing the bridge
    /// Only the contract account should hold this
    access(all) resource Admin {
        
        /// Set the TidalRequests contract address (one-time only for security)
        access(all) fun setTidalRequestsAddress(_ address: EVM.EVMAddress) {
            pre {
                TidalEVMWorker.tidalRequestsAddress == nil: "TidalRequests address already set"
            }
            TidalEVMWorker.tidalRequestsAddress = address
            emit TidalRequestsAddressSet(address: address.toString())
        }
        
        /// Create a new Worker (can only be called by Admin)
        /// This is used during setup after beta access is granted
        access(all) fun createWorker(
            coa: @EVM.CadenceOwnedAccount, 
            betaBadge: auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge
        ): @Worker {
            let worker <- create Worker(coa: <-coa, betaBadge: betaBadge)
            emit WorkerInitialized(coaAddress: worker.getCOAAddressString())
            return <-worker
        }
    }
    
    // ========================================
    // Worker Resource
    // ========================================
    
    access(all) resource Worker {
        /// COA resource for cross-VM operations
        access(self) let coa: @EVM.CadenceOwnedAccount
        
        /// TideManager to hold Tides for EVM users
        access(self) let tideManager: @TidalYield.TideManager
        
        /// Beta badge reference for creating Tides
        access(self) let betaBadgeRef: auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge
        
        init(coa: @EVM.CadenceOwnedAccount, betaBadge: auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge) {
            self.coa <- coa
            self.betaBadgeRef = betaBadge
            
            // Create TideManager for holding EVM user Tides
            self.tideManager <- TidalYield.createTideManager(betaRef: betaBadge)
        }
        
        /// Get beta reference for creating Tides
        access(self) fun getBetaReference(): auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge {
            return self.betaBadgeRef
        }
        
        /// Get COA's EVM address as string
        access(all) fun getCOAAddressString(): String {
            return self.coa.address().toString()
        }
        
        /// Process all pending requests from TidalRequests contract
        access(all) fun processRequests() {
            pre {
                TidalEVMWorker.tidalRequestsAddress != nil: "TidalRequests address not set"
            }
            
            // 1. Get pending requests from TidalRequests
            let requests = self.getPendingRequestsFromEVM()
            
            if requests.length == 0 {
                emit RequestsProcessed(count: 0, successful: 0, failed: 0)
                return
            }
            
            var successCount = 0
            var failCount = 0
            
            // 2. Process each request
            for request in requests {
                let success = self.processRequestSafely(request)
                if success {
                    successCount = successCount + 1
                } else {
                    failCount = failCount + 1
                }
            }
            
            emit RequestsProcessed(count: requests.length, successful: successCount, failed: failCount)
        }
        
        /// Safely process a single request with error handling
        access(self) fun processRequestSafely(_ request: EVMRequest): Bool {
            // Mark as PROCESSING
            self.updateRequestStatus(
                requestId: request.id,
                status: 1, // PROCESSING
                tideId: 0
            )
            
            // Try to process based on type
            var success = false
            var tideId: UInt64 = 0
            
            switch request.requestType {
                case 0: // CREATE_TIDE
                    let result = self.processCreateTide(request)
                    success = result.success
                    tideId = result.tideId
                case 3: // CLOSE_TIDE
                    success = self.processCloseTide(request)
                    tideId = request.tideId
                default:
                    // Other types not implemented yet
                    success = false
            }
            
            // Update request status
            let finalStatus = success ? 2 : 3 // COMPLETED : FAILED
            self.updateRequestStatus(
                requestId: request.id,
                status: UInt8(finalStatus),
                tideId: tideId
            )
            
            return success
        }
        
        /// Process CREATE_TIDE request
        access(self) fun processCreateTide(_ request: EVMRequest): ProcessResult {
            // 1. Parse strategy and vault identifiers from request
            // For now, hardcode FlowToken vault identifier
            // In production, you'd encode these in the EVM request or have a mapping

            // TODO - Pass those params more elegantly
            let vaultIdentifier = "A.7e60df042a9c0868.FlowToken.Vault"
            let strategyIdentifier = "A.d27920b6384e2a78.TidalYieldStrategies.TracerStrategy"

            // 2. Convert amount from UInt256 to UFix64
            let amount = TidalEVMWorker.ufix64FromUInt256(request.amount)
            
            // 3. Withdraw funds from TidalRequests
            let vault <- self.withdrawFundsFromEVM(amount: amount)
            
            // 4. Validate vault type matches vaultIdentifier
            let vaultType = vault.getType()
            assert(
                vaultType.identifier == vaultIdentifier,
                message: "Vault type mismatch: expected ".concat(vaultIdentifier).concat(" but got ").concat(vaultType.identifier)
            )
            
            // 5. Create the Strategy Type
            let strategyType = CompositeType(strategyIdentifier)
                ?? panic("Invalid strategyIdentifier ".concat(strategyIdentifier))
            
            // 6. Get beta reference
            let betaRef = self.getBetaReference()
            
             // 7. Get current tide IDs before creating new tide
            let tidesBeforeCreate = self.tideManager.getIDs()
            
            // 8. Create Tide with proper parameters matching the transaction
            // Note: createTide returns Void, so we need to find the new tide ID
            self.tideManager.createTide(
                betaRef: betaRef,
                strategyType: strategyType,
                withVault: <-vault
            )
            
            // 9. Get the new tide ID by finding the difference
            let tidesAfterCreate = self.tideManager.getIDs()
            var tideId = UInt64.max
            for id in tidesAfterCreate {
                if !tidesBeforeCreate.contains(id) {
                    tideId = id
                    break
                }
            }
            
            assert(tideId != UInt64.max, message: "Failed to find newly created Tide ID")
            
            // 10. Store mapping
            let evmAddr = request.user.toString()
            if TidalEVMWorker.tidesByEVMAddress[evmAddr] == nil {
                TidalEVMWorker.tidesByEVMAddress[evmAddr] = []
            }
            TidalEVMWorker.tidesByEVMAddress[evmAddr]!.append(tideId)
            
            // 11. Update user balance in TidalRequests
            self.updateUserBalance(
                user: request.user,
                tokenAddress: request.tokenAddress,
                newBalance: 0 // All funds moved to Tide
            )
            
            emit TideCreatedForEVMUser(evmAddress: evmAddr, tideId: tideId, amount: amount)
            
            return ProcessResult(success: true, tideId: tideId)
        }
        
        /// Process CLOSE_TIDE request
        access(self) fun processCloseTide(_ request: EVMRequest): Bool {
            let evmAddr = request.user.toString()
            
            // 1. Verify user owns this Tide
            if let userTides = TidalEVMWorker.tidesByEVMAddress[evmAddr] {
                if !userTides.contains(request.tideId) {
                    return false // User doesn't own this Tide
                }
            } else {
                return false // User has no Tides
            }
            
            // 2. Close Tide and get vault
            let vault <- self.tideManager.closeTide(request.tideId)
            let amount = vault.balance
            
            // 3. Bridge funds back to EVM user
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user)
            
            // 4. Remove from mapping
            if let index = TidalEVMWorker.tidesByEVMAddress[evmAddr]!.firstIndex(of: request.tideId) {
                TidalEVMWorker.tidesByEVMAddress[evmAddr]!.remove(at: index)
            }
            
            emit TideClosedForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amountReturned: amount)
            
            return true
        }
        
        /// Withdraw funds from TidalRequests contract via COA
        access(self) fun withdrawFundsFromEVM(amount: UFix64): @{FungibleToken.Vault} {
            // Call TidalRequests.withdrawFunds(NATIVE_FLOW, amount)
            // This transfers FLOW from TidalRequests to COA's EVM address
            
            let amountUInt256 = TidalEVMWorker.uint256FromUFix64(amount)
            let nativeFlowAddress = EVM.addressFromString("0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF")
            
            // Encode function call: withdrawFunds(address,uint256)
            let calldata = EVM.encodeABIWithSignature(
                "withdrawFunds(address,uint256)",
                [nativeFlowAddress, amountUInt256]
            )
            
            let result = self.coa.call(
                to: TidalEVMWorker.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 100000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "withdrawFunds call failed")
            
            // Now withdraw from COA to get Cadence vault
            // TODO - fix amount conversion to not be greater than UFix64 max
            let balance = EVM.Balance(attoflow: UInt(amount * 1_000_000_000.0))
            let vault <- self.coa.withdraw(balance: balance) as! @FlowToken.Vault
            
            return <-vault
        }
        
        /// Bridge funds from Cadence back to EVM user (atomic)
        access(self) fun bridgeFundsToEVMUser(vault: @{FungibleToken.Vault}, recipient: EVM.EVMAddress) {
            // Convert to EVM balance
            // TODO - fix amount conversion to not be greater than UFix64 max
            let balance = EVM.Balance(attoflow: UInt(vault.balance * 1_000_000_000.0))
            destroy vault
            
            // Deposit directly to recipient's EVM address (atomic!)
            recipient.deposit(from: <-self.coa.withdraw(balance: balance))
        }
        
        /// Update request status in TidalRequests
        access(self) fun updateRequestStatus(requestId: UInt256, status: UInt8, tideId: UInt64) {
            let calldata = EVM.encodeABIWithSignature(
                "updateRequestStatus(uint256,uint8,uint64)",
                [requestId, status, tideId]
            )
            
            let result = self.coa.call(
                to: TidalEVMWorker.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 100000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "updateRequestStatus call failed")
        }
        
        /// Update user balance in TidalRequests
        access(self) fun updateUserBalance(user: EVM.EVMAddress, tokenAddress: EVM.EVMAddress, newBalance: UInt256) {
            let calldata = EVM.encodeABIWithSignature(
                "updateUserBalance(address,address,uint256)",
                [user, tokenAddress, newBalance]
            )
            
            let result = self.coa.call(
                to: TidalEVMWorker.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 100000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "updateUserBalance call failed")
        }
        
        /// Get pending requests from TidalRequests contract
        access(self) fun getPendingRequestsFromEVM(): [EVMRequest] {
            // Call TidalRequests.getPendingRequests()
            let calldata = EVM.encodeABIWithSignature("getPendingRequests()", [])
            
            let result = self.coa.call(
                to: TidalEVMWorker.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 500000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "getPendingRequests call failed")
            
            // Decode result - this is simplified, you'll need proper ABI decoding
            // For PoC, return empty array and test with manual calls
            return []
        }
    }
    
    // ========================================
    // Public Functions
    // ========================================
    
    /// Get Tide IDs for an EVM address
    access(all) fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64] {
        return self.tidesByEVMAddress[evmAddress] ?? []
    }
    
    /// Get TidalRequests address (read-only)
    access(all) fun getTidalRequestsAddress(): EVM.EVMAddress? {
        return self.tidalRequestsAddress
    }

    /// Helper: Convert UInt256 (18 decimals) to UFix64 (8 decimals)
    access(self) fun ufix64FromUInt256(_ value: UInt256): UFix64 {
        // Divide by 10^10 to go from 18 decimals to 8 decimals
        let scaled = value / 10_000_000_000
        // Convert to UFix64 (which interprets as value * 10^-8)
        return UFix64(scaled)
    }

    /// Helper: Convert UFix64 (8 decimals) to UInt256 (18 decimals)
    access(self) fun uint256FromUFix64(_ value: UFix64): UInt256 {
        // Get the raw fixed-point value (multiply by 10^8)
        let raw = UInt64(value * 100_000_000.0)
        // Scale up by 10^10 to get 18 decimals
        return UInt256(raw) * 10_000_000_000
    }
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        // Setup paths
        self.WorkerStoragePath = /storage/tidalEVMWorker
        self.WorkerPublicPath = /public/tidalEVMWorker
        self.AdminStoragePath = /storage/tidalEVMWorkerAdmin
        
        // Initialize state
        self.tidesByEVMAddress = {}
        self.tidalRequestsAddress = nil
        
        // Create and save Admin resource (singleton)
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
        
        // Note: Worker will be created via setup transaction
        // This allows proper initialization with COA and BetaBadge
    }
}
