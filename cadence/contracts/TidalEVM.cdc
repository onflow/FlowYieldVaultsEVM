import "FungibleToken"
import "FlowToken"
import "EVM"

import "TidalYield"
import "TidalYieldClosedBeta"

/// TidalEVM: Bridge contract that processes requests from EVM users
/// and manages their Tide positions in Cadence
/// 
/// Security Model:
/// - Singleton pattern: Worker created in init() and stored in contract account
/// - Only contract account can set TidalRequests address
/// - Only contract account can create/access Worker
access(all) contract TidalEVM {
    
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
    access(all) event RequestFailed(requestId: UInt256, reason: String)

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
        access(all) let message: String
        
        init(
            id: UInt256,
            user: EVM.EVMAddress,
            requestType: UInt8,
            status: UInt8,
            tokenAddress: EVM.EVMAddress,
            amount: UInt256,
            tideId: UInt64,
            timestamp: UInt256,
            message: String
        ) {
            self.id = id
            self.user = user
            self.requestType = requestType
            self.status = status
            self.tokenAddress = tokenAddress
            self.amount = amount
            self.tideId = tideId
            self.timestamp = timestamp
            self.message = message
        }
    }
    
    access(all) struct ProcessResult {
        access(all) let success: Bool
        access(all) let tideId: UInt64
        access(all) let message: String
        
        init(success: Bool, tideId: UInt64, message: String) {
            self.success = success
            self.tideId = tideId
            self.message = message
        }
    }
    
    // ========================================
    // Admin Resource
    // ========================================
    
    /// Admin capability for managing the bridge
    /// Only the contract account should hold this
    access(all) resource Admin {
        access(all) fun setTidalRequestsAddress(_ address: EVM.EVMAddress) {
            pre {
                TidalEVM.tidalRequestsAddress == nil: "TidalRequests address already set"
            }
            TidalEVM.tidalRequestsAddress = address
            emit TidalRequestsAddressSet(address: address.toString())
        }

        access(all) fun updateTidalRequestsAddress(_ address: EVM.EVMAddress) {
            // Pas de précondition - permet la mise à jour
            TidalEVM.tidalRequestsAddress = address
            emit TidalRequestsAddressSet(address: address.toString())
        }
        
        /// Create a new Worker with a capability instead of reference
        access(all) fun createWorker(
            coa: @EVM.CadenceOwnedAccount, 
            betaBadgeCap: Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>
        ): @Worker {
            let worker <- create Worker(coa: <-coa, betaBadgeCap: betaBadgeCap)
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
        
        /// Capability to beta badge (instead of reference)
        access(self) let betaBadgeCap: Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>
        
        init(
            coa: @EVM.CadenceOwnedAccount, 
            betaBadgeCap: Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>
        ) {
            self.coa <- coa
            self.betaBadgeCap = betaBadgeCap
            
            // Borrow the beta badge to create TideManager
            let betaBadge = betaBadgeCap.borrow()
                ?? panic("Could not borrow beta badge capability")
            
            // Create TideManager for holding EVM user Tides
            self.tideManager <- TidalYield.createTideManager(betaRef: betaBadge)
        }
        
        /// Get beta reference by borrowing from capability
        access(self) fun getBetaReference(): auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge {
            return self.betaBadgeCap.borrow()
                ?? panic("Could not borrow beta badge capability")
        }
        
        /// Get COA's EVM address as string
        access(all) fun getCOAAddressString(): String {
            return self.coa.address().toString()
        }
        
        /// Process all pending requests from TidalRequests contract
        access(all) fun processRequests() {
            pre {
                TidalEVM.tidalRequestsAddress != nil: "TidalRequests address not set"
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
                // log the request details in the same order as EVM struct
                log("Processing request: ".concat(request.id.toString()))
                log("Request type: ".concat(request.requestType.toString()))
                log("User: ".concat(request.user.toString()))
                log("Amount: ".concat(request.amount.toString()))
                log("Status: ".concat(request.status.toString()))
                log("Token Address: ".concat(request.tokenAddress.toString()))
                log("Tide ID: ".concat(request.tideId.toString()))
                log("Timestamp: ".concat(request.timestamp.toString()))
                log("Message: ".concat(request.message))

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
                tideId: 0,
                message: "Processing request"
            )
            
            // Try to process based on type
            var success = false
            var tideId: UInt64 = 0
            var message = ""
            
            switch request.requestType {
                case 0: // CREATE_TIDE
                    let result = self.processCreateTide(request)
                    success = result.success
                    tideId = result.tideId
                    message = result.message
                case 3: // CLOSE_TIDE
                    let result = self.processCloseTideWithMessage(request)
                    success = result.success
                    tideId = request.tideId
                    message = result.message
                default:
                    // Other types not implemented yet
                    success = false
                    message = "Request type not implemented"
            }
            
            // Update request status
            let finalStatus = success ? 2 : 3 // COMPLETED : FAILED
            self.updateRequestStatus(
                requestId: request.id,
                status: UInt8(finalStatus),
                tideId: tideId,
                message: message
            )
            
            if !success {
                // emit RequestFailed(requestId: request.id, reason: message)
                panic("Request Processing Failed\n"
                    .concat("Request ID: ").concat(request.id.toString())
                    .concat("\nRequest Type: ").concat(request.requestType.toString())
                    .concat("\nUser: ").concat(request.user.toString())
                    .concat("\nAmount: ").concat(request.amount.toString())
                    .concat("\nReason: ").concat(message))
            }
            
            return success
        }
        
        /// Process CREATE_TIDE request
        access(self) fun processCreateTide(_ request: EVMRequest): ProcessResult {
            // 1. Parse strategy and vault identifiers from request
            // For now, hardcode FlowToken vault identifier
            // In production, you'd encode these in the EVM request or have a mapping

            // TODO - Pass those params more elegantly
            // // testnet
            let vaultIdentifier = "A.7e60df042a9c0868.FlowToken.Vault"
            let strategyIdentifier = "A.d27920b6384e2a78.TidalYieldStrategies.TracerStrategy"

            // emulator
            // let vaultIdentifier = "A.0ae53cb6e3f42a79.FlowToken.Vault"
            // let strategyIdentifier = "A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategy"

            // 2. Convert amount from UInt256 to UFix64
            let amount = TidalEVM.ufix64FromUInt256(request.amount)
            log("Creating Tide for amount: ".concat(amount.toString()))
            
            // 3. Withdraw funds from TidalRequests
            let vault <- self.withdrawFundsFromEVM(amount: amount)

            // 4. Validate vault type matches vaultIdentifier
            let vaultType = vault.getType()
            if vaultType.identifier != vaultIdentifier {
                destroy vault
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "Vault type mismatch: expected ".concat(vaultIdentifier).concat(" but got ").concat(vaultType.identifier)
                )
            }
            
            // 5. Create the Strategy Type
            let strategyType = CompositeType(strategyIdentifier)
            if strategyType == nil {
                destroy vault
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "Invalid strategyIdentifier: ".concat(strategyIdentifier)
                )
            }
            
            // 6. Get beta reference
            let betaRef = self.getBetaReference()
            
            // 7. Get current tide IDs before creating new tide
            let tidesBeforeCreate = self.tideManager.getIDs()
            
            // 8. Create Tide with proper parameters matching the transaction
            // Note: createTide returns Void, so we need to find the new tide ID
            self.tideManager.createTide(
                betaRef: betaRef,
                strategyType: strategyType!,
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
            
            if tideId == UInt64.max {
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "Failed to find newly created Tide ID"
                )
            }
            
            // 10. Store mapping
            let evmAddr = request.user.toString()
            if TidalEVM.tidesByEVMAddress[evmAddr] == nil {
                TidalEVM.tidesByEVMAddress[evmAddr] = []
            }
            TidalEVM.tidesByEVMAddress[evmAddr]!.append(tideId)
            
            // 11. Update user balance in TidalRequests
            self.updateUserBalance(
                user: request.user,
                tokenAddress: request.tokenAddress,
                newBalance: 0 // All funds moved to Tide
            )
            
            emit TideCreatedForEVMUser(evmAddress: evmAddr, tideId: tideId, amount: amount)
            
            return ProcessResult(
                success: true, 
                tideId: tideId, 
                message: "Tide created successfully"
            )
        }
        
        /// Process CLOSE_TIDE request with message support
        access(self) fun processCloseTideWithMessage(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()
            
            // 1. Verify user owns this Tide
            if let userTides = TidalEVM.tidesByEVMAddress[evmAddr] {
                if !userTides.contains(request.tideId) {
                    return ProcessResult(
                        success: false, 
                        tideId: 0, 
                        message: "User does not own Tide ID ".concat(request.tideId.toString())
                    )
                }
            } else {
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "User has no Tides"
                )
            }
            
            // 2. Close Tide and get vault
            let vault <- self.tideManager.closeTide(request.tideId)
            let amount = vault.balance
            
            // 3. Bridge funds back to EVM user
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user)
            
            // 4. Remove from mapping
            if let index = TidalEVM.tidesByEVMAddress[evmAddr]!.firstIndex(of: request.tideId) {
                TidalEVM.tidesByEVMAddress[evmAddr]!.remove(at: index)
            }
            
            emit TideClosedForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amountReturned: amount)
            
            return ProcessResult(
                success: true, 
                tideId: request.tideId, 
                message: "Tide closed successfully, returned ".concat(amount.toString()).concat(" FLOW")
            )
        }
        
        /// Withdraw funds from TidalRequests contract via COA
        access(self) fun withdrawFundsFromEVM(amount: UFix64): @{FungibleToken.Vault} {
            let amountUInt256 = TidalEVM.uint256FromUFix64(amount)
            let nativeFlowAddress = EVM.addressFromString("0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF")
            
            let calldata = EVM.encodeABIWithSignature(
                "withdrawFunds(address,uint256)",
                [nativeFlowAddress, amountUInt256]
            )
            
            let result = self.coa.call(
                to: TidalEVM.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 100000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "withdrawFunds call failed")
            
            // FIX: Proper conversion to attoflow
            // UFix64 uses 8 decimals, attoflow uses 18 decimals
            // Multiply by 10^10 to go from UFix64 to attoflow
            let rawUFix64 = UInt64(amount * 100_000_000.0) // Get raw 8-decimal value
            let attoflowAmount = UInt(rawUFix64) * 10_000_000_000 // Scale to 18 decimals
            
            let balance = EVM.Balance(attoflow: attoflowAmount)
            let vault <- self.coa.withdraw(balance: balance) as! @FlowToken.Vault
            
            return <-vault
        }
        
        /// Bridge funds from Cadence back to EVM user (atomic)
        access(self) fun bridgeFundsToEVMUser(vault: @{FungibleToken.Vault}, recipient: EVM.EVMAddress) {
            // Get amount before destroying vault
            let amount = vault.balance
            
            // Convert UFix64 to attoflow properly
            let rawUFix64 = UInt64(amount * 100_000_000.0) // Get raw 8-decimal value
            let attoflowAmount = UInt(rawUFix64) * 10_000_000_000 // Scale to 18 decimals
            
            // Deposit the vault into COA first
            self.coa.deposit(from: <-vault as! @FlowToken.Vault)
            
            // Then withdraw and send to recipient
            let balance = EVM.Balance(attoflow: attoflowAmount)
            recipient.deposit(from: <-self.coa.withdraw(balance: balance))
        }
        
        /// Update request status in TidalRequests
        access(self) fun updateRequestStatus(requestId: UInt256, status: UInt8, tideId: UInt64, message: String) {
            let calldata = EVM.encodeABIWithSignature(
                "updateRequestStatus(uint256,uint8,uint64,string)",
                [requestId, status, tideId, message]
            )
            
            let result = self.coa.call(
                to: TidalEVM.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 150000, // Increased for string parameter
                value: EVM.Balance(attoflow: 0)
            )
            
            // If failed, try to decode the revert reason
            var revertReason = ""
            if result.status != EVM.Status.successful && result.data.length > 0 {
                // Try to decode Error(string) which is the standard revert format
                // Error selector is 0x08c379a0
                if result.data.length >= 4 {
                    let decodedRevert = EVM.decodeABI(types: [Type<String>()], data: result.data.slice(from: 4, upTo: result.data.length))
                    if decodedRevert.length > 0 {
                        revertReason = " - Revert Reason: ".concat(decodedRevert[0] as? String ?? "unable to decode")
                    }
                }
            }
            
            assert(
                result.status == EVM.Status.successful, 
                message: "updateRequestStatus call failed - Error Code: "
                    .concat(result.errorCode.toString())
                    .concat(", Error Message: ")
                    .concat(result.errorMessage)
                    .concat(", Gas Used: ")
                    .concat(result.gasUsed.toString())
                    .concat(revertReason)
            )
            
            log("Request status updated successfully: ".concat(message))
        }
        
        /// Update user balance in TidalRequests
        access(self) fun updateUserBalance(user: EVM.EVMAddress, tokenAddress: EVM.EVMAddress, newBalance: UInt256) {
            let calldata = EVM.encodeABIWithSignature(
                "updateUserBalance(address,address,uint256)",
                [user, tokenAddress, newBalance]
            )
            
            let result = self.coa.call(
                to: TidalEVM.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 100000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "updateUserBalance call failed")
        }
        
        /// Get pending requests from TidalRequests contract
        access(all) fun getPendingRequestsFromEVM(): [EVMRequest] {
            // Call TidalRequests.getPendingRequestsUnpacked()
            let calldata = EVM.encodeABIWithSignature("getPendingRequestsUnpacked()", [])
            
            let callResult = self.coa.dryCall(
                to: TidalEVM.tidalRequestsAddress!,
                data: calldata,
                gasLimit: 15_000_000,
                value: EVM.Balance(attoflow: 0)
            )

            log("=== EVM Call Result ===")
            log("Status: ".concat(callResult.status == EVM.Status.successful ? "SUCCESSFUL" : "FAILED"))
            log("Error Code: ".concat(callResult.errorCode.toString()))
            log("Error Message: ".concat(callResult.errorMessage))
            log("Gas Used: ".concat(callResult.gasUsed.toString()))
            log("Data Length: ".concat(callResult.data.length.toString()))

            assert(callResult.status == EVM.Status.successful, message: "getPendingRequestsUnpacked call failed")
            
            // Decode 9 separate arrays (one for each field in Request struct)
            let decoded = EVM.decodeABI(
                types: [
                    Type<[UInt256]>(),      // ids
                    Type<[EVM.EVMAddress]>(), // users
                    Type<[UInt8]>(),        // requestTypes
                    Type<[UInt8]>(),        // statuses
                    Type<[EVM.EVMAddress]>(), // tokenAddresses
                    Type<[UInt256]>(),      // amounts
                    Type<[UInt64]>(),       // tideIds
                    Type<[UInt256]>(),      // timestamps
                    Type<[String]>()        // messages
                ],
                data: callResult.data
            )

            log("Decoded result length: ".concat(decoded.length.toString()))
            
            // Extract arrays from decoded result
            let ids = decoded[0] as! [UInt256]
            let users = decoded[1] as! [EVM.EVMAddress]
            let requestTypes = decoded[2] as! [UInt8]
            let statuses = decoded[3] as! [UInt8]
            let tokenAddresses = decoded[4] as! [EVM.EVMAddress]
            let amounts = decoded[5] as! [UInt256]
            let tideIds = decoded[6] as! [UInt64]
            let timestamps = decoded[7] as! [UInt256]
            let messages = decoded[8] as! [String]
            
            // Reconstruct EVMRequest structs
            let requests: [EVMRequest] = []
            var i = 0
            while i < ids.length {
                let request = EVMRequest(
                    id: ids[i],
                    user: users[i],
                    requestType: requestTypes[i],
                    status: statuses[i],
                    tokenAddress: tokenAddresses[i],
                    amount: amounts[i],
                    tideId: tideIds[i],
                    timestamp: timestamps[i],
                    message: messages[i]
                )
                requests.append(request)
                i = i + 1
            }
            
            log("Successfully reconstructed ".concat(requests.length.toString()).concat(" requests"))
            
            return requests
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
        let scaled = value / 10_000_000_000 // Remove 10 decimals (18 -> 8)
        return UFix64(scaled) / 100_000_000.0
    }

    /// Helper: Convert UFix64 (8 decimals) to UInt256 (18 decimals)
    access(self) fun uint256FromUFix64(_ value: UFix64): UInt256 {
        // UFix64 internally stores as integer with 8 decimal places
        // Get raw integer value by multiplying by 10^8
        let rawValue = UInt64(value * 100_000_000.0)
        // Scale up by 10^10 to get 18 decimals
        return UInt256(rawValue) * 10_000_000_000
    }
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        // Setup paths
        self.WorkerStoragePath = /storage/tidalEVM
        self.WorkerPublicPath = /public/tidalEVM
        self.AdminStoragePath = /storage/tidalEVMAdmin
        
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