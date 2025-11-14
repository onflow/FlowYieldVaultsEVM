import "FungibleToken"
import "FlowToken"
import "EVM"

import "FlowVaults"
import "FlowVaultsClosedBeta"

/// FlowVaultsEVM: Bridge contract that processes requests from EVM users
/// and manages their Tide positions in Cadence
access(all) contract FlowVaultsEVM {
    
    // ========================================
    // Constants
    // ========================================
    
    /// Maximum requests to process per transaction
    /// Updatable by Admin for performance tuning
    access(all) var MAX_REQUESTS_PER_TX: Int
    
    // ========================================
    // Paths
    // ========================================
    
    access(all) let WorkerStoragePath: StoragePath
    access(all) let WorkerPublicPath: PublicPath
    access(all) let AdminStoragePath: StoragePath
    
    // ========================================
    // State
    // ========================================
    
    access(all) let tidesByEVMAddress: {String: [UInt64]}
    access(all) var flowVaultsRequestsAddress: EVM.EVMAddress?
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event WorkerInitialized(coaAddress: String)
    access(all) event FlowVaultsRequestsAddressSet(address: String)
    access(all) event RequestsProcessed(count: Int, successful: Int, failed: Int)
    access(all) event TideCreatedForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)
    access(all) event TideDepositedForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)
    access(all) event TideWithdrawnForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)
    access(all) event TideClosedForEVMUser(evmAddress: String, tideId: UInt64, amountReturned: UFix64)
    access(all) event RequestFailed(requestId: UInt256, reason: String)
    access(all) event MaxRequestsPerTxUpdated(oldValue: Int, newValue: Int)

    // ========================================
    // Structs
    // ========================================
    
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
        access(all) let vaultIdentifier: String
        access(all) let strategyIdentifier: String
        
        init(
            id: UInt256,
            user: EVM.EVMAddress,
            requestType: UInt8,
            status: UInt8,
            tokenAddress: EVM.EVMAddress,
            amount: UInt256,
            tideId: UInt64,
            timestamp: UInt256,
            message: String,
            vaultIdentifier: String,
            strategyIdentifier: String
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
            self.vaultIdentifier = vaultIdentifier
            self.strategyIdentifier = strategyIdentifier
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
    
    access(all) resource Admin {
        access(all) fun setFlowVaultsRequestsAddress(_ address: EVM.EVMAddress) {
            pre {
                FlowVaultsEVM.flowVaultsRequestsAddress == nil: "FlowVaultsRequests address already set"
            }
            FlowVaultsEVM.flowVaultsRequestsAddress = address
            emit FlowVaultsRequestsAddressSet(address: address.toString())
        }

        access(all) fun updateFlowVaultsRequestsAddress(_ address: EVM.EVMAddress) {
            FlowVaultsEVM.flowVaultsRequestsAddress = address
            emit FlowVaultsRequestsAddressSet(address: address.toString())
        }
        
        /// Update the maximum number of requests to process per transaction
        /// NEW: Allows runtime tuning without redeployment
        access(all) fun updateMaxRequestsPerTx(_ newMax: Int) {
            pre {
                newMax > 0: "MAX_REQUESTS_PER_TX must be greater than 0"
                newMax <= 100: "MAX_REQUESTS_PER_TX should not exceed 100 for gas safety"
            }
            
            let oldMax = FlowVaultsEVM.MAX_REQUESTS_PER_TX
            FlowVaultsEVM.MAX_REQUESTS_PER_TX = newMax
            
            emit MaxRequestsPerTxUpdated(oldValue: oldMax, newValue: newMax)
        }
        
        access(all) fun createWorker(
            coaCap: Capability<auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount>, 
            betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>
        ): @Worker {
            let worker <- create Worker(
                coaCap: coaCap,
                betaBadgeCap: betaBadgeCap
            )
            emit WorkerInitialized(coaAddress: worker.getCOAAddressString())
            return <-worker
        }
    }
    
    // ========================================
    // Worker Resource
    // ========================================
    
    access(all) resource Worker {
        access(self) let coaCap: Capability<auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount>
        access(self) let tideManager: @FlowVaults.TideManager
        access(self) let betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>
        
        init(
            coaCap: Capability<auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount>,
            betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>
        ) {
            pre {
                coaCap.check(): "COA capability is invalid"
            }
            
            self.coaCap = coaCap
            self.betaBadgeCap = betaBadgeCap
            
            let betaBadge = betaBadgeCap.borrow()
                ?? panic("Could not borrow beta badge capability")
            
            self.tideManager <- FlowVaults.createTideManager(betaRef: betaBadge)
        }
        
        /// Get reference to COA
        access(self) fun getCOARef(): auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount {
            return self.coaCap.borrow()
                ?? panic("Could not borrow COA capability")
        }
        
        access(self) fun getBetaReference(): auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge {
            return self.betaBadgeCap.borrow()
                ?? panic("Could not borrow beta badge capability")
        }
        
        access(all) fun getCOAAddressString(): String {
            return self.getCOARef().address().toString()
        }
        
        /// Process pending requests (up to MAX_REQUESTS_PER_TX)
        /// External handler manages scheduling
        access(all) fun processRequests() {
            pre {
                FlowVaultsEVM.flowVaultsRequestsAddress != nil: "FlowVaultsRequests address not set"
            }
            
            // 1. Get count of pending requests (lightweight)
            let pendingIds = self.getPendingRequestIdsFromEVM()
            let totalPending = pendingIds.length
            
            log("Total pending requests: ".concat(totalPending.toString()))
            
            // 2. Fetch only the batch we'll process (up to MAX_REQUESTS_PER_TX)
            let requestsToProcess = self.getPendingRequestsFromEVM()
            let batchSize = requestsToProcess.length
            
            log("Batch size to process: ".concat(batchSize.toString()))
            
            if batchSize == 0 {
                emit RequestsProcessed(count: 0, successful: 0, failed: 0)
                return
            }
            
            var successCount = 0
            var failCount = 0
            var i = 0
            
            while i < batchSize {
                let request = requestsToProcess[i]
                
                log("Processing request: ".concat(request.id.toString()))
                log("Request type: ".concat(request.requestType.toString()))
                log("User: ".concat(request.user.toString()))
                log("Amount: ".concat(request.amount.toString()))

                let success = self.processRequestSafely(request)
                if success {
                    successCount = successCount + 1
                } else {
                    failCount = failCount + 1
                }
                i = i + 1
            }
            
            emit RequestsProcessed(count: batchSize, successful: successCount, failed: failCount)
        }
        
        access(self) fun processRequestSafely(_ request: EVMRequest): Bool {
            self.updateRequestStatus(
                requestId: request.id,
                status: 1,
                tideId: 0,
                message: "Processing request"
            )
            
            var success = false
            var tideId: UInt64 = 0
            var message = ""
            
            switch request.requestType {
                case 0:  // CREATE_TIDE
                    let result = self.processCreateTide(request)
                    success = result.success
                    tideId = result.tideId
                    message = result.message
                case 1:  // DEPOSIT_TO_TIDE
                    let result = self.processDepositToTide(request)
                    success = result.success
                    tideId = request.tideId
                    message = result.message
                case 2:  // WITHDRAW_FROM_TIDE
                    let result = self.processWithdrawFromTide(request)
                    success = result.success
                    tideId = request.tideId
                    message = result.message
                case 3:  // CLOSE_TIDE
                    let result = self.processCloseTideWithMessage(request)
                    success = result.success
                    tideId = request.tideId
                    message = result.message
                default:
                    success = false
                    message = "Request type not implemented"
            }
            
            let finalStatus = success ? 2 : 3
            self.updateRequestStatus(
                requestId: request.id,
                status: UInt8(finalStatus),
                tideId: tideId,
                message: message
            )
            
            if !success {
                emit RequestFailed(requestId: request.id, reason: message)
            }
            
            return success
        }
        
        access(self) fun processCreateTide(_ request: EVMRequest): ProcessResult {
            let vaultIdentifier = request.vaultIdentifier
            let strategyIdentifier = request.strategyIdentifier

            let amount = FlowVaultsEVM.ufix64FromUInt256(request.amount)
            log("Creating Tide for amount: ".concat(amount.toString()))
            
            let vault <- self.withdrawFundsFromEVM(amount: amount)

            let vaultType = vault.getType()
            if vaultType.identifier != vaultIdentifier {
                destroy vault
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "Vault type mismatch"
                )
            }
            
            let strategyType = CompositeType(strategyIdentifier)
            if strategyType == nil {
                destroy vault
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "Invalid strategyIdentifier"
                )
            }
            
            let betaRef = self.getBetaReference()
            let tidesBeforeCreate = self.tideManager.getIDs()
            
            self.tideManager.createTide(
                betaRef: betaRef,
                strategyType: strategyType!,
                withVault: <-vault
            )
            
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
            
            let evmAddr = request.user.toString()
            if FlowVaultsEVM.tidesByEVMAddress[evmAddr] == nil {
                FlowVaultsEVM.tidesByEVMAddress[evmAddr] = []
            }
            FlowVaultsEVM.tidesByEVMAddress[evmAddr]!.append(tideId)
            
            self.updateUserBalance(
                user: request.user,
                tokenAddress: request.tokenAddress,
                newBalance: 0
            )
            
            emit TideCreatedForEVMUser(evmAddress: evmAddr, tideId: tideId, amount: amount)
            
            return ProcessResult(
                success: true, 
                tideId: tideId, 
                message: "Tide created successfully"
            )
        }
        
        access(self) fun processCloseTideWithMessage(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()
            
            if let userTides = FlowVaultsEVM.tidesByEVMAddress[evmAddr] {
                if !userTides.contains(request.tideId) {
                    return ProcessResult(
                        success: false, 
                        tideId: 0, 
                        message: "User does not own Tide"
                    )
                }
            } else {
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "User has no Tides"
                )
            }
            
            let vault <- self.tideManager.closeTide(request.tideId)
            let amount = vault.balance
            
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user)
            
            if let index = FlowVaultsEVM.tidesByEVMAddress[evmAddr]!.firstIndex(of: request.tideId) {
                let _ = FlowVaultsEVM.tidesByEVMAddress[evmAddr]!.remove(at: index)
            }
            
            emit TideClosedForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amountReturned: amount)
            
            return ProcessResult(
                success: true, 
                tideId: request.tideId, 
                message: "Tide closed successfully"
            )
        }
        
        access(self) fun processDepositToTide(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()
            
            // 1. Verify user owns the Tide
            if let userTides = FlowVaultsEVM.tidesByEVMAddress[evmAddr] {
                if !userTides.contains(request.tideId) {
                    return ProcessResult(
                        success: false, 
                        tideId: 0, 
                        message: "User does not own Tide"
                    )
                }
            } else {
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "User has no Tides"
                )
            }
            
            // 2. Withdraw funds from EVM
            let amount = FlowVaultsEVM.ufix64FromUInt256(request.amount)
            log("Depositing to Tide for amount: ".concat(amount.toString()))
            
            let vault <- self.withdrawFundsFromEVM(amount: amount)
            
            // 3. Deposit to existing Tide
            let betaRef = self.getBetaReference()
            self.tideManager.depositToTide(betaRef: betaRef, request.tideId, from: <-vault)
            
            // 4. Update user balance to 0 (funds now in Tide)
            self.updateUserBalance(
                user: request.user,
                tokenAddress: request.tokenAddress,
                newBalance: 0
            )
            
            emit TideDepositedForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amount: amount)
            
            return ProcessResult(
                success: true, 
                tideId: request.tideId, 
                message: "Deposit successful"
            )
        }
        
        access(self) fun processWithdrawFromTide(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()
            
            // 1. Verify user owns the Tide
            if let userTides = FlowVaultsEVM.tidesByEVMAddress[evmAddr] {
                if !userTides.contains(request.tideId) {
                    return ProcessResult(
                        success: false, 
                        tideId: 0, 
                        message: "User does not own Tide"
                    )
                }
            } else {
                return ProcessResult(
                    success: false, 
                    tideId: 0, 
                    message: "User has no Tides"
                )
            }
            
            // 2. Withdraw from Tide
            let amount = FlowVaultsEVM.ufix64FromUInt256(request.amount)
            log("Withdrawing from Tide for amount: ".concat(amount.toString()))
            
            let vault <- self.tideManager.withdrawFromTide(request.tideId, amount: amount)
            
            // 3. Bridge funds back to EVM user
            let actualAmount = vault.balance
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user)
            
            emit TideWithdrawnForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amount: actualAmount)
            
            return ProcessResult(
                success: true, 
                tideId: request.tideId, 
                message: "Withdrawal successful"
            )
        }
        
        access(self) fun withdrawFundsFromEVM(amount: UFix64): @{FungibleToken.Vault} {
            let amountUInt256 = FlowVaultsEVM.uint256FromUFix64(amount)
            let nativeFlowAddress = EVM.addressFromString("0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF")
            
            let calldata = EVM.encodeABIWithSignature(
                "withdrawFunds(address,uint256)",
                [nativeFlowAddress, amountUInt256]
            )
            
            let result = self.getCOARef().call(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100000,
                value: EVM.Balance(attoflow: 0)
            )
            
            // If EVM call fails, decode error and panic
            // This causes the entire transaction to revert
            if result.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(result.data)
                panic("withdrawFunds call failed: ".concat(errorMsg))
            }
            
            // Convert UFix64 amount to attoflow (10^18) for EVM.Balance
            let balance = FlowVaultsEVM.balanceFromUFix64(amount)
            let vault <- self.getCOARef().withdraw(balance: balance)
            
            return <-vault
        }
        
        access(self) fun bridgeFundsToEVMUser(vault: @{FungibleToken.Vault}, recipient: EVM.EVMAddress) {
            let amount = vault.balance
            
            // Deposit vault to COA first
            self.getCOARef().deposit(from: <-vault as! @FlowToken.Vault)
            
            // Convert UFix64 amount to attoflow (10^18) and withdraw as EVM balance
            let balance = FlowVaultsEVM.balanceFromUFix64(amount)
            recipient.deposit(from: <-self.getCOARef().withdraw(balance: balance))
        }
        
        access(self) fun updateRequestStatus(requestId: UInt256, status: UInt8, tideId: UInt64, message: String) {
            let calldata = EVM.encodeABIWithSignature(
                "updateRequestStatus(uint256,uint8,uint64,string)",
                [requestId, status, tideId, message]
            )
            
            let result = self.getCOARef().call(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 1_000_000,
                value: EVM.Balance(attoflow: 0)
            )
            
            // If EVM call fails, decode error and panic
            // This causes the entire transaction to revert
            if result.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(result.data)
                panic("updateRequestStatus call failed: ".concat(errorMsg))
            }
        }
        
        access(self) fun updateUserBalance(user: EVM.EVMAddress, tokenAddress: EVM.EVMAddress, newBalance: UInt256) {
            let calldata = EVM.encodeABIWithSignature(
                "updateUserBalance(address,address,uint256)",
                [user, tokenAddress, newBalance]
            )
            
            let result = self.getCOARef().call(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100000,
                value: EVM.Balance(attoflow: 0)
            )
            
            // If EVM call fails, decode error and panic
            // This causes the entire transaction to revert
            if result.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(result.data)
                panic("updateUserBalance call failed: ".concat(errorMsg))
            }
        }
        
        /// Get pending request IDs from FlowVaultsRequests contract (lightweight)
        /// Used for counting total pending requests without fetching full data
        access(all) fun getPendingRequestIdsFromEVM(): [UInt256] {
            let calldata = EVM.encodeABIWithSignature("getPendingRequestIds()", [])
            
            let callResult = self.getCOARef().dryCall(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 500000,
                value: EVM.Balance(attoflow: 0)
            )
            
            // If EVM call fails, decode error and panic
            if callResult.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(callResult.data)
                panic("getPendingRequestIds call failed: ".concat(errorMsg))
            }
            
            let decoded = EVM.decodeABI(
                types: [Type<[UInt256]>()],
                data: callResult.data
            )
            
            return decoded[0] as! [UInt256]
        }
        
        /// Get pending requests from FlowVaultsRequests contract
        /// Now fetches only up to MAX_REQUESTS_PER_TX for efficiency
        access(all) fun getPendingRequestsFromEVM(): [EVMRequest] {
            // Call with limit parameter to only fetch what we'll process
            let limit = UInt256(FlowVaultsEVM.MAX_REQUESTS_PER_TX)
            let calldata = EVM.encodeABIWithSignature("getPendingRequestsUnpacked(uint256)", [limit])
            
            let callResult = self.getCOARef().dryCall(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 15_000_000,
                value: EVM.Balance(attoflow: 0)
            )

            log("=== EVM Call Result ===")
            log("Status: ".concat(callResult.status == EVM.Status.successful ? "SUCCESSFUL" : "FAILED"))
            log("Requested limit: ".concat(limit.toString()))
            log("Gas Used: ".concat(callResult.gasUsed.toString()))
            log("Data Length: ".concat(callResult.data.length.toString()))

            // If EVM call fails, decode error and panic
            if callResult.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(callResult.data)
                panic("getPendingRequestsUnpacked call failed: ".concat(errorMsg))
            }
            
            let decoded = EVM.decodeABI(
                types: [
                    Type<[UInt256]>(),
                    Type<[EVM.EVMAddress]>(),
                    Type<[UInt8]>(),
                    Type<[UInt8]>(),
                    Type<[EVM.EVMAddress]>(),
                    Type<[UInt256]>(),
                    Type<[UInt64]>(),
                    Type<[UInt256]>(),
                    Type<[String]>(),
                    Type<[String]>(),
                    Type<[String]>()
                ],
                data: callResult.data
            )
            
            let ids = decoded[0] as! [UInt256]
            let users = decoded[1] as! [EVM.EVMAddress]
            let requestTypes = decoded[2] as! [UInt8]
            let statuses = decoded[3] as! [UInt8]
            let tokenAddresses = decoded[4] as! [EVM.EVMAddress]
            let amounts = decoded[5] as! [UInt256]
            let tideIds = decoded[6] as! [UInt64]
            let timestamps = decoded[7] as! [UInt256]
            let messages = decoded[8] as! [String]
            let vaultIdentifiers = decoded[9] as! [String]
            let strategyIdentifiers = decoded[10] as! [String]
            
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
                    message: messages[i],
                    vaultIdentifier: vaultIdentifiers[i],
                    strategyIdentifier: strategyIdentifiers[i]
                )
                requests.append(request)
                i = i + 1
            }
            
            return requests
        }
    }
    
    // ========================================
    // Public Functions
    // ========================================
    
    access(all) fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64] {
        return self.tidesByEVMAddress[evmAddress] ?? []
    }
    
    access(all) fun getFlowVaultsRequestsAddress(): EVM.EVMAddress? {
        return self.flowVaultsRequestsAddress
    }

    access(self) fun ufix64FromUInt256(_ value: UInt256): UFix64 {
        let scaled = value / 10_000_000_000
        return UFix64(scaled) / 100_000_000.0
    }

    access(self) fun uint256FromUFix64(_ value: UFix64): UInt256 {
        let rawValue = UInt64(value * 100_000_000.0)
        return UInt256(rawValue) * 10_000_000_000
    }

    /// Convert UFix64 (8 decimals) to EVM.Balance (attoflow, 18 decimals)
    /// UFix64: 1.0 = 1 FLOW with 8 decimal places
    /// Attoflow: 1 FLOW = 10^18 attoflow
    access(self) fun balanceFromUFix64(_ value: UFix64): EVM.Balance {
        // Convert UFix64 to its base unit representation (8 decimals)
        let flowUnits = UInt64(value * 100_000_000.0)
        // Scale from 8 decimals to 18 decimals (attoflow)
        let attoflowAmount = UInt(flowUnits) * 10_000_000_000
        return EVM.Balance(attoflow: attoflowAmount)
    }

    /// Decode error message from EVM revert data
    /// EVM reverts typically encode as: Error(string) selector (0x08c379a0) + ABI-encoded string
    access(self) fun decodeEVMError(_ data: [UInt8]): String {
        // Check if data starts with Error(string) selector: 0x08c379a0
        if data.length >= 4 {
            let selector = (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
            if selector == 0x08c379a0 && data.length > 4 {
                // Try to decode the ABI-encoded string
                let payload = data.slice(from: 4, upTo: data.length)
                let decoded = EVM.decodeABI(types: [Type<String>()], data: payload)
                if decoded.length > 0 {
                    if let errorMsg = decoded[0] as? String {
                        return errorMsg
                    }
                }
            }
        }
        // Fallback: return hex representation of revert data
        return "EVM revert data: 0x".concat(String.encodeHex(data))
    }
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        self.WorkerStoragePath = /storage/flowVaultsEVM
        self.WorkerPublicPath = /public/flowVaultsEVM
        self.AdminStoragePath = /storage/flowVaultsEVMAdmin
        
        // Initialize with conservative batch size
        self.MAX_REQUESTS_PER_TX = 1
        
        self.tidesByEVMAddress = {}
        self.flowVaultsRequestsAddress = nil
        
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
