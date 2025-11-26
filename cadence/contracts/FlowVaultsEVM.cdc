import "FungibleToken"
import "FlowToken"
import "EVM"
import "Burner"

import "FlowVaults"
import "FlowVaultsClosedBeta"
import "FlowEVMBridgeUtils"
import "FlowEVMBridgeConfig"

/// @title FlowVaultsEVM
/// @author Flow Vaults Team
/// @notice Bridge contract that processes requests from EVM users and manages their Tide positions in Cadence.
/// @dev This contract serves as the Cadence-side processor for cross-VM operations. It reads pending
///      requests from the FlowVaultsRequests Solidity contract, executes the corresponding Flow Vaults
///      operations (create/deposit/withdraw/close Tide), and updates request status back on EVM.
///
///      Key architecture:
///      - Worker resource: Holds COA capability and TideManager, processes requests
///      - Admin resource: Manages contract configuration (requests address, batch size)
///      - Two-phase commit: Uses startProcessing() and completeProcessing() for atomic state management
///
///      Request flow:
///      1. Worker fetches pending requests from FlowVaultsRequests (EVM)
///      2. For each request, calls startProcessing() to mark as PROCESSING and deduct balance
///      3. Executes Cadence-side operation (create/deposit/withdraw/close Tide)
///      4. Calls completeProcessing() to mark as COMPLETED or FAILED (with refund on failure)
access(all) contract FlowVaultsEVM {

    // ============================================
    // Type Declarations
    // ============================================

    /// @notice Request types matching the Solidity RequestType enum
    /// @dev Must stay synchronized with FlowVaultsRequests.sol RequestType enum
    access(all) enum RequestType: UInt8 {
        access(all) case CREATE_TIDE
        access(all) case DEPOSIT_TO_TIDE
        access(all) case WITHDRAW_FROM_TIDE
        access(all) case CLOSE_TIDE
    }

    /// @notice Request status matching the Solidity RequestStatus enum
    /// @dev Must stay synchronized with FlowVaultsRequests.sol RequestStatus enum
    access(all) enum RequestStatus: UInt8 {
        access(all) case PENDING
        access(all) case PROCESSING
        access(all) case COMPLETED
        access(all) case FAILED
    }

    /// @notice Decoded request data from EVM contract
    /// @dev Mirrors the Request struct in FlowVaultsRequests.sol for cross-VM communication
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
            pre {
                requestType >= FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue &&
                requestType <= FlowVaultsEVM.RequestType.CLOSE_TIDE.rawValue:
                    "Invalid request type: must be between 0 (CREATE_TIDE) and 3 (CLOSE_TIDE)"

                status >= FlowVaultsEVM.RequestStatus.PENDING.rawValue &&
                status <= FlowVaultsEVM.RequestStatus.FAILED.rawValue:
                    "Invalid status: must be between 0 (PENDING) and 3 (FAILED)"

                requestType == FlowVaultsEVM.RequestType.CLOSE_TIDE.rawValue || amount > 0:
                    "Amount must be greater than 0 for CREATE_TIDE, DEPOSIT_TO_TIDE, and WITHDRAW_FROM_TIDE operations"
            }
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

    /// @notice Sentinel value for "no tide" in ProcessResult
    /// @dev Uses UInt64.max as sentinel since tideId can legitimately be 0
    access(all) let noTideId: UInt64

    /// @notice Result of processing a single request
    /// @dev tideId uses UInt64.max as sentinel for "no tide" since valid IDs can be 0
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

    // ============================================
    // State Variables
    // ============================================

    /// @notice Sentinel address representing native $FLOW in EVM
    /// @dev Uses recognizable pattern (all F's) matching FlowVaultsRequests.sol NATIVE_FLOW constant
    access(all) let nativeFlowEVMAddress: EVM.EVMAddress

    /// @notice Maximum requests to process per transaction
    /// @dev Configurable by Admin for performance tuning. Higher values increase throughput
    ///      but risk hitting gas limits. Recommended range: 5-50.
    access(all) var maxRequestsPerTx: Int

    /// @notice Storage path for Worker resource
    access(all) let WorkerStoragePath: StoragePath

    /// @notice Storage path for Admin resource
    access(all) let AdminStoragePath: StoragePath

    /// @notice Tide IDs owned by each EVM address
    /// @dev Maps EVM address string to array of owned Tide IDs for public queries
    access(all) let tidesByEVMAddress: {String: [UInt64]}

    /// @notice O(1) lookup for tide ownership verification
    /// @dev Maps EVM address string to {tideId: true} for fast ownership checks
    access(all) let tideOwnershipLookup: {String: {UInt64: Bool}}

    /// @notice Address of the FlowVaultsRequests contract on EVM
    access(all) var flowVaultsRequestsAddress: EVM.EVMAddress?

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when a Worker is initialized
    /// @param coaAddress The COA address associated with the Worker
    access(all) event WorkerInitialized(coaAddress: String)

    /// @notice Emitted when the FlowVaultsRequests address is set
    /// @param address The EVM address of the FlowVaultsRequests contract
    access(all) event FlowVaultsRequestsAddressSet(address: String)

    /// @notice Emitted after processing a batch of requests
    /// @param count Total requests processed
    /// @param successful Number of successful requests
    /// @param failed Number of failed requests
    access(all) event RequestsProcessed(count: Int, successful: Int, failed: Int)

    /// @notice Emitted when a new Tide is created for an EVM user
    /// @param evmAddress The EVM address of the user
    /// @param tideId The newly created Tide ID
    /// @param amount The initial deposit amount
    access(all) event TideCreatedForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)

    /// @notice Emitted when funds are deposited to an existing Tide
    /// @param evmAddress The EVM address of the user
    /// @param tideId The Tide ID receiving the deposit
    /// @param amount The deposited amount
    access(all) event TideDepositedForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)

    /// @notice Emitted when funds are withdrawn from a Tide
    /// @param evmAddress The EVM address of the user
    /// @param tideId The Tide ID being withdrawn from
    /// @param amount The withdrawn amount
    access(all) event TideWithdrawnForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)

    /// @notice Emitted when a Tide is closed
    /// @param evmAddress The EVM address of the user
    /// @param tideId The closed Tide ID
    /// @param amountReturned The total amount returned to the user
    access(all) event TideClosedForEVMUser(evmAddress: String, tideId: UInt64, amountReturned: UFix64)

    /// @notice Emitted when a request fails during processing
    /// @param requestId The failed request ID
    /// @param userAddress The EVM address of the user
    /// @param requestType The type of request that failed
    /// @param reason The failure reason
    access(all) event RequestFailed(requestId: UInt256, userAddress: String, requestType: UInt8, reason: String)

    /// @notice Emitted when maxRequestsPerTx is updated
    /// @param oldValue The previous value
    /// @param newValue The new value
    access(all) event MaxRequestsPerTxUpdated(oldValue: Int, newValue: Int)

    /// @notice Emitted when withdrawing funds from EVM fails
    /// @param requestId The request ID
    /// @param amount The amount that failed to withdraw
    /// @param tokenAddress The token address
    /// @param reason The failure reason
    access(all) event WithdrawFundsFromEVMFailed(requestId: UInt256, amount: UFix64, tokenAddress: String, reason: String)

    // ============================================
    // Resources
    // ============================================

    /// @notice Admin resource for contract configuration
    /// @dev Only the contract deployer receives this resource
    access(all) resource Admin {

        /// @notice Sets the FlowVaultsRequests address (first time only)
        /// @param address The EVM address of the FlowVaultsRequests contract
        access(all) fun setFlowVaultsRequestsAddress(_ address: EVM.EVMAddress) {
            pre {
                FlowVaultsEVM.flowVaultsRequestsAddress == nil: "FlowVaultsRequests address already set"
            }
            FlowVaultsEVM.flowVaultsRequestsAddress = address
            emit FlowVaultsRequestsAddressSet(address: address.toString())
        }

        /// @notice Updates the FlowVaultsRequests address
        /// @param address The new EVM address of the FlowVaultsRequests contract
        access(all) fun updateFlowVaultsRequestsAddress(_ address: EVM.EVMAddress) {
            FlowVaultsEVM.flowVaultsRequestsAddress = address
            emit FlowVaultsRequestsAddressSet(address: address.toString())
        }

        /// @notice Updates the maximum requests processed per transaction
        /// @param newMax The new maximum (must be 1-100)
        access(all) fun updateMaxRequestsPerTx(_ newMax: Int) {
            pre {
                newMax > 0: "maxRequestsPerTx must be greater than 0"
                newMax <= 100: "maxRequestsPerTx should not exceed 100 for gas safety"
            }

            let oldMax = FlowVaultsEVM.maxRequestsPerTx
            FlowVaultsEVM.maxRequestsPerTx = newMax

            emit MaxRequestsPerTxUpdated(oldValue: oldMax, newValue: newMax)
        }

        /// @notice Creates a new Worker resource
        /// @param coaCap Capability to the COA with Call, Withdraw, and Bridge entitlements
        /// @param tideManagerCap Capability to the TideManager with Withdraw entitlement
        /// @param betaBadgeCap Capability to the beta badge for Flow Vaults access
        /// @param feeProviderCap Capability to withdraw fees for bridge operations
        /// @return The newly created Worker resource
        access(all) fun createWorker(
            coaCap: Capability<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>,
            tideManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>,
            betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>,
            feeProviderCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>
        ): @Worker {
            let worker <- create Worker(
                coaCap: coaCap,
                tideManagerCap: tideManagerCap,
                betaBadgeCap: betaBadgeCap,
                feeProviderCap: feeProviderCap
            )
            emit WorkerInitialized(coaAddress: worker.getCOAAddressString())
            return <-worker
        }
    }

    /// @notice Worker resource that processes EVM requests
    /// @dev Holds capabilities to COA, beta badge, fee provider, and TideManager.
    ///      TideManager is stored separately and accessed via capability for better composability.
    access(all) resource Worker {
        access(self) let coaCap: Capability<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>
        access(self) let tideManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>
        access(self) let betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>
        access(self) let feeProviderCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>

        init(
            coaCap: Capability<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>,
            tideManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>,
            betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>,
            feeProviderCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>
        ) {
            pre {
                coaCap.check(): "COA capability is invalid"
                tideManagerCap.check(): "TideManager capability is invalid"
                feeProviderCap.check(): "Fee provider capability is invalid"
            }

            self.coaCap = coaCap
            self.tideManagerCap = tideManagerCap
            self.betaBadgeCap = betaBadgeCap
            self.feeProviderCap = feeProviderCap
        }

        access(self) view fun getCOARef(): auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount {
            return self.coaCap.borrow()
                ?? panic("Could not borrow COA capability")
        }

        access(self) fun getTideManagerRef(): auth(FungibleToken.Withdraw) &FlowVaults.TideManager {
            return self.tideManagerCap.borrow()
                ?? panic("Could not borrow TideManager capability")
        }

        access(self) view fun getBetaReference(): auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge {
            return self.betaBadgeCap.borrow()
                ?? panic("Could not borrow beta badge capability")
        }

        /// @notice Returns the COA address as a string
        /// @return The EVM address string of the COA
        access(all) view fun getCOAAddressString(): String {
            return self.getCOARef().address().toString()
        }

        /// @notice Processes pending requests from the EVM contract
        /// @dev Fetches up to count pending requests and processes each one.
        ///      Uses two-phase commit pattern with startProcessing() and completeProcessing().
        /// @param startIndex The index to start fetching requests from
        /// @param count The number of requests to fetch
        access(all) fun processRequests(startIndex: Int, count: Int) {
            pre {
                FlowVaultsEVM.flowVaultsRequestsAddress != nil: "FlowVaultsRequests address not set"
            }

            let totalPending = self.getPendingRequestCountFromEVM()
            let requestsToProcess = self.getPendingRequestsFromEVM(startIndex: startIndex, count: count)
            let batchSize = requestsToProcess.length

            if batchSize == 0 {
                emit RequestsProcessed(count: 0, successful: 0, failed: 0)
                return
            }

            var successCount = 0
            var failCount = 0
            var i = 0

            while i < batchSize {
                let request = requestsToProcess[i]

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
            pre {
                request.amount > 0 || request.requestType == FlowVaultsEVM.RequestType.CLOSE_TIDE.rawValue: "Request amount must be greater than 0 for non-close operations"
                request.status == FlowVaultsEVM.RequestStatus.PENDING.rawValue: "Request must be in PENDING status"
            }
            var success = false
            var tideId: UInt64 = FlowVaultsEVM.noTideId
            var message = ""

            let needsStartProcessing = request.requestType == FlowVaultsEVM.RequestType.WITHDRAW_FROM_TIDE.rawValue
                || request.requestType == FlowVaultsEVM.RequestType.CLOSE_TIDE.rawValue

            if needsStartProcessing {
                if !self.startProcessing(requestId: request.id) {
                    if !self.completeProcessing(
                        requestId: request.id,
                        success: false,
                        tideId: request.tideId,
                        message: "Failed to start processing"
                    ) {
                        emit RequestFailed(
                            requestId: request.id,
                            userAddress: request.user.toString(),
                            requestType: request.requestType,
                            reason: "Failed to start processing and complete processing"
                        )
                    }
                    return false
                }
            }

            switch request.requestType {
                case FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue:
                    let result = self.processCreateTide(request)
                    success = result.success
                    tideId = result.tideId
                    message = result.message
                case FlowVaultsEVM.RequestType.DEPOSIT_TO_TIDE.rawValue:
                    let result = self.processDepositToTide(request)
                    success = result.success
                    tideId = result.tideId != FlowVaultsEVM.noTideId ? result.tideId : request.tideId
                    message = result.message
                case FlowVaultsEVM.RequestType.WITHDRAW_FROM_TIDE.rawValue:
                    let result = self.processWithdrawFromTide(request)
                    success = result.success
                    tideId = result.tideId != FlowVaultsEVM.noTideId ? result.tideId : request.tideId
                    message = result.message
                case FlowVaultsEVM.RequestType.CLOSE_TIDE.rawValue:
                    let result = self.processCloseTide(request)
                    success = result.success
                    tideId = result.tideId != FlowVaultsEVM.noTideId ? result.tideId : request.tideId
                    message = result.message
                default:
                    success = false
                    message = "Unknown request type: \(request.requestType) for request ID \(request.id)"
            }

            if !self.completeProcessing(
                requestId: request.id,
                success: success,
                tideId: tideId,
                message: message
            ) {
                emit RequestFailed(
                    requestId: request.id,
                    userAddress: request.user.toString(),
                    requestType: request.requestType,
                    reason: "Processing completed but failed to update status: \(message)"
                )
            }

            if !success {
                emit RequestFailed(
                    requestId: request.id,
                    userAddress: request.user.toString(),
                    requestType: request.requestType,
                    reason: message
                )
            }

            return success
        }

        access(self) fun returnFundsAndFail(
            vault: @{FungibleToken.Vault},
            recipient: EVM.EVMAddress,
            tokenAddress: EVM.EVMAddress,
            errorMessage: String
        ): ProcessResult {
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: recipient, tokenAddress: tokenAddress)
            return ProcessResult(
                success: false,
                tideId: FlowVaultsEVM.noTideId,
                message: errorMessage.concat(". Funds returned to user.")
            )
        }

        access(self) fun processCreateTide(_ request: EVMRequest): ProcessResult {
            let vaultIdentifier = request.vaultIdentifier
            let strategyIdentifier = request.strategyIdentifier
            let amount = FlowVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            if !self.startProcessing(requestId: request.id) {
                return ProcessResult(
                    success: false,
                    tideId: FlowVaultsEVM.noTideId,
                    message: "Failed to start processing - request may already be processing or completed"
                )
            }

            let vaultOptional <- self.withdrawFundsFromCOA(
                amount: amount,
                tokenAddress: request.tokenAddress
            )

            if vaultOptional == nil {
                destroy vaultOptional
                return ProcessResult(
                    success: false,
                    tideId: FlowVaultsEVM.noTideId,
                    message: "Failed to withdraw funds from COA"
                )
            }

            let vault <- vaultOptional!

            let vaultType = vault.getType()
            if vaultType.identifier != vaultIdentifier {
                return self.returnFundsAndFail(
                    vault: <-vault,
                    recipient: request.user,
                    tokenAddress: request.tokenAddress,
                    errorMessage: "Vault type mismatch: expected \(vaultIdentifier), got \(vaultType.identifier)"
                )
            }

            let strategyType = CompositeType(strategyIdentifier)
            if strategyType == nil {
                return self.returnFundsAndFail(
                    vault: <-vault,
                    recipient: request.user,
                    tokenAddress: request.tokenAddress,
                    errorMessage: "Invalid strategyIdentifier: \(strategyIdentifier)"
                )
            }

            let betaRef = self.getBetaReference()
            let tideManager = self.getTideManagerRef()
            let tidesBeforeCreate = tideManager.getIDs()

            tideManager.createTide(
                betaRef: betaRef,
                strategyType: strategyType!,
                withVault: <-vault
            )

            let tidesAfterCreate = tideManager.getIDs()
            var tideId = FlowVaultsEVM.noTideId
            for id in tidesAfterCreate {
                if !tidesBeforeCreate.contains(id) {
                    tideId = id
                    break
                }
            }

            if tideId == FlowVaultsEVM.noTideId {
                return ProcessResult(
                    success: false,
                    tideId: FlowVaultsEVM.noTideId,
                    message: "Failed to find newly created Tide ID after creation for request \(request.id)"
                )
            }

            let evmAddr = request.user.toString()

            if FlowVaultsEVM.tidesByEVMAddress[evmAddr] == nil {
                FlowVaultsEVM.tidesByEVMAddress[evmAddr] = []
            }
            FlowVaultsEVM.tidesByEVMAddress[evmAddr]!.append(tideId)

            if FlowVaultsEVM.tideOwnershipLookup[evmAddr] == nil {
                FlowVaultsEVM.tideOwnershipLookup[evmAddr] = {}
            }
            FlowVaultsEVM.tideOwnershipLookup[evmAddr]!.insert(key: tideId, true)

            emit TideCreatedForEVMUser(evmAddress: evmAddr, tideId: tideId, amount: amount)

            return ProcessResult(
                success: true,
                tideId: tideId,
                message: "Tide ID \(tideId) created successfully with amount \(amount) FLOW"
            )
        }

        access(self) fun processCloseTide(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            if let ownershipMap = FlowVaultsEVM.tideOwnershipLookup[evmAddr] {
                if ownershipMap[request.tideId] != true {
                    return ProcessResult(
                        success: false,
                        tideId: request.tideId,
                        message: "User \(evmAddr) does not own Tide ID \(request.tideId)"
                    )
                }
            } else {
                return ProcessResult(
                    success: false,
                    tideId: request.tideId,
                    message: "User \(evmAddr) has no Tides registered"
                )
            }

            let vault <- self.getTideManagerRef().closeTide(request.tideId)
            let amount = vault.balance

            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user, tokenAddress: request.tokenAddress)

            if let index = FlowVaultsEVM.tidesByEVMAddress[evmAddr]!.firstIndex(of: request.tideId) {
                let _ = FlowVaultsEVM.tidesByEVMAddress[evmAddr]!.remove(at: index)
            }
            FlowVaultsEVM.tideOwnershipLookup[evmAddr]!.remove(key: request.tideId)

            emit TideClosedForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amountReturned: amount)

            return ProcessResult(
                success: true,
                tideId: request.tideId,
                message: "Tide ID \(request.tideId) closed successfully, returned \(amount) FLOW"
            )
        }

        access(self) fun processDepositToTide(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            if let ownershipMap = FlowVaultsEVM.tideOwnershipLookup[evmAddr] {
                if ownershipMap[request.tideId] != true {
                    return ProcessResult(
                        success: false,
                        tideId: request.tideId,
                        message: "User \(evmAddr) does not own Tide ID \(request.tideId)"
                    )
                }
            } else {
                return ProcessResult(
                    success: false,
                    tideId: request.tideId,
                    message: "User \(evmAddr) has no Tides registered"
                )
            }

            if !self.startProcessing(requestId: request.id) {
                return ProcessResult(
                    success: false,
                    tideId: request.tideId,
                    message: "Failed to start processing - request may already be processing or completed"
                )
            }

            let amount = FlowVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            let vaultOptional <- self.withdrawFundsFromCOA(
                amount: amount,
                tokenAddress: request.tokenAddress
            )

            if vaultOptional == nil {
                destroy vaultOptional
                return ProcessResult(
                    success: false,
                    tideId: request.tideId,
                    message: "Failed to withdraw funds from COA"
                )
            }

            let vault <- vaultOptional!

            let betaRef = self.getBetaReference()
            self.getTideManagerRef().depositToTide(betaRef: betaRef, request.tideId, from: <-vault)

            emit TideDepositedForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amount: amount)

            return ProcessResult(
                success: true,
                tideId: request.tideId,
                message: "Deposited \(amount) FLOW to Tide ID \(request.tideId)"
            )
        }

        access(self) fun processWithdrawFromTide(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            if let ownershipMap = FlowVaultsEVM.tideOwnershipLookup[evmAddr] {
                if ownershipMap[request.tideId] != true {
                    return ProcessResult(
                        success: false,
                        tideId: request.tideId,
                        message: "User \(evmAddr) does not own Tide ID \(request.tideId)"
                    )
                }
            } else {
                return ProcessResult(
                    success: false,
                    tideId: request.tideId,
                    message: "User \(evmAddr) has no Tides registered"
                )
            }

            let amount = FlowVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            let vault <- self.getTideManagerRef().withdrawFromTide(request.tideId, amount: amount)

            let actualAmount = vault.balance
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user, tokenAddress: request.tokenAddress)

            emit TideWithdrawnForEVMUser(evmAddress: evmAddr, tideId: request.tideId, amount: actualAmount)

            return ProcessResult(
                success: true,
                tideId: request.tideId,
                message: "Withdrew \(actualAmount) FLOW from Tide ID \(request.tideId)"
            )
        }

        /// @notice Marks a request as PROCESSING and deducts user balance atomically
        /// @param requestId The request ID to start processing
        /// @return True if successful, false otherwise
        access(self) fun startProcessing(requestId: UInt256): Bool {
            let calldata = EVM.encodeABIWithSignature(
                "startProcessing(uint256)",
                [requestId]
            )

            let result = self.getCOARef().call(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 200_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(result.data)
                emit WithdrawFundsFromEVMFailed(
                    requestId: requestId,
                    amount: 0.0,
                    tokenAddress: "",
                    reason: "startProcessing failed: \(errorMsg)"
                )
                return false
            }

            return true
        }

        /// @notice Marks a request as COMPLETED or FAILED with refund on failure
        /// @param requestId The request ID to complete
        /// @param success Whether the operation succeeded
        /// @param tideId The associated Tide ID
        /// @param message Status message or error reason
        /// @return True if the EVM call succeeded, false otherwise
        access(self) fun completeProcessing(requestId: UInt256, success: Bool, tideId: UInt64, message: String): Bool {
            let status = success
                ? FlowVaultsEVM.RequestStatus.COMPLETED.rawValue
                : FlowVaultsEVM.RequestStatus.FAILED.rawValue

            let calldata = EVM.encodeABIWithSignature(
                "completeProcessing(uint256,bool,uint64,string)",
                [requestId, success, tideId, message]
            )

            let result = self.getCOARef().call(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 1_000_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(result.data)
                emit RequestFailed(
                    requestId: requestId,
                    userAddress: "",
                    requestType: 0,
                    reason: "completeProcessing failed: \(errorMsg)"
                )
                return false
            }

            return true
        }

        access(self) fun withdrawFundsFromCOA(amount: UFix64, tokenAddress: EVM.EVMAddress): @{FungibleToken.Vault}? {
            if tokenAddress.toString() == FlowVaultsEVM.nativeFlowEVMAddress.toString() {
                let balance = FlowVaultsEVM.balanceFromUFix64(amount, tokenAddress: tokenAddress)
                let vault <- self.getCOARef().withdraw(balance: balance)

                if vault.balance == 0.0 {
                    destroy vault
                    return nil
                }

                return <-vault
            } else {
                let amountUInt256 = FlowVaultsEVM.uint256FromUFix64(amount, tokenAddress: tokenAddress)
                let vault <- self.bridgeERC20FromEVM(
                    tokenAddress: tokenAddress,
                    amount: amountUInt256
                )

                if vault.balance == 0.0 {
                    destroy vault
                    return nil
                }

                return <-vault
            }
        }

        access(self) fun bridgeFundsToEVMUser(vault: @{FungibleToken.Vault}, recipient: EVM.EVMAddress, tokenAddress: EVM.EVMAddress) {
            let amount = vault.balance

            if tokenAddress.toString() == FlowVaultsEVM.nativeFlowEVMAddress.toString() {
                self.getCOARef().deposit(from: <-vault as! @FlowToken.Vault)
                let balance = FlowVaultsEVM.balanceFromUFix64(amount, tokenAddress: tokenAddress)
                recipient.deposit(from: <-self.getCOARef().withdraw(balance: balance))
            } else {
                self.bridgeERC20ToEVM(
                    vault: <-vault,
                    recipient: recipient,
                    tokenAddress: tokenAddress
                )
            }
        }

        access(self) fun bridgeERC20FromEVM(
            tokenAddress: EVM.EVMAddress,
            amount: UInt256
        ): @{FungibleToken.Vault} {
            let vaultType = FlowEVMBridgeConfig.getTypeAssociated(with: tokenAddress)
                ?? panic("ERC20 token at \(tokenAddress.toString()) is not onboarded to the FlowEVMBridge")

            let coaRef = self.getCOARef()
            let feeProvider = self.feeProviderCap.borrow()
                ?? panic("Could not borrow fee provider capability")

            let vault <- coaRef.withdrawTokens(
                type: vaultType,
                amount: amount,
                feeProvider: feeProvider
            )

            return <-vault
        }

        access(self) fun bridgeERC20ToEVM(
            vault: @{FungibleToken.Vault},
            recipient: EVM.EVMAddress,
            tokenAddress: EVM.EVMAddress
        ) {
            let amountUInt256 = FlowVaultsEVM.uint256FromUFix64(vault.balance, tokenAddress: tokenAddress)

            let coaRef = self.getCOARef()
            let feeProvider = self.feeProviderCap.borrow()
                ?? panic("Could not borrow fee provider capability")

            coaRef.depositTokens(
                vault: <-vault,
                feeProvider: feeProvider
            )

            let transferCalldata = EVM.encodeABIWithSignature(
                "transfer(address,uint256)",
                [recipient, amountUInt256]
            )

            let transferResult = coaRef.call(
                to: tokenAddress,
                data: transferCalldata,
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )

            if transferResult.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(transferResult.data)
                panic("ERC20 transfer to recipient failed: \(errorMsg)")
            }
        }

        /// @notice Gets the count of pending requests from the EVM contract
        /// @return The number of pending requests
        access(all) fun getPendingRequestCountFromEVM(): Int {
            let calldata = EVM.encodeABIWithSignature("getPendingRequestCount()", [])

            let callResult = self.getCOARef().dryCall(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )

            if callResult.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(callResult.data)
                panic("getPendingRequestCount call failed: \(errorMsg)")
            }

            let decoded = EVM.decodeABI(
                types: [Type<UInt256>()],
                data: callResult.data
            )

            let count256 = decoded[0] as! UInt256
            return Int(count256)
        }

        /// @notice Fetches pending requests from the EVM contract
        /// @param startIndex The index to start fetching from
        /// @param count The number of requests to fetch (use maxRequestsPerTx if not specified)
        /// @return Array of pending EVMRequest structs
        access(all) fun getPendingRequestsFromEVM(startIndex: Int, count: Int): [EVMRequest] {
            let startIdx = UInt256(startIndex)
            let cnt = UInt256(count)
            let calldata = EVM.encodeABIWithSignature("getPendingRequestsUnpacked(uint256,uint256)", [startIdx, cnt])

            let callResult = self.getCOARef().dryCall(
                to: FlowVaultsEVM.flowVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 15_000_000,
                value: EVM.Balance(attoflow: 0)
            )

            if callResult.status != EVM.Status.successful {
                let errorMsg = FlowVaultsEVM.decodeEVMError(callResult.data)
                panic("getPendingRequestsUnpacked call failed: \(errorMsg)")
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

    // ============================================
    // Public Functions
    // ============================================

    /// @notice Gets all Tide IDs owned by an EVM address
    /// @param evmAddress The EVM address string to query
    /// @return Array of Tide IDs owned by the address
    access(all) view fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64] {
        return self.tidesByEVMAddress[evmAddress] ?? []
    }

    /// @notice Checks if an EVM address owns a specific Tide ID (O(1) lookup)
    /// @param evmAddress The EVM address string to check
    /// @param tideId The Tide ID to verify ownership of
    /// @return True if the address owns the Tide, false otherwise
    access(all) view fun doesEVMAddressOwnTide(evmAddress: String, tideId: UInt64): Bool {
        if let ownershipMap = self.tideOwnershipLookup[evmAddress] {
            return ownershipMap[tideId] ?? false
        }
        return false
    }

    /// @notice Gets the configured FlowVaultsRequests contract address
    /// @return The EVM address or nil if not set
    access(all) view fun getFlowVaultsRequestsAddress(): EVM.EVMAddress? {
        return self.flowVaultsRequestsAddress
    }

    // ============================================
    // Internal Functions
    // ============================================

    access(self) fun ufix64FromUInt256(_ value: UInt256, tokenAddress: EVM.EVMAddress): UFix64 {
        if tokenAddress.toString() == FlowVaultsEVM.nativeFlowEVMAddress.toString() {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: value, decimals: 18)
        }
        return FlowEVMBridgeUtils.convertERC20AmountToCadenceAmount(value, erc20Address: tokenAddress)
    }

    access(self) fun uint256FromUFix64(_ value: UFix64, tokenAddress: EVM.EVMAddress): UInt256 {
        if tokenAddress.toString() == FlowVaultsEVM.nativeFlowEVMAddress.toString() {
            return FlowEVMBridgeUtils.ufix64ToUInt256(value: value, decimals: 18)
        }
        return FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(value, erc20Address: tokenAddress)
    }

    access(self) fun balanceFromUFix64(_ value: UFix64, tokenAddress: EVM.EVMAddress): EVM.Balance {
        assert(
            tokenAddress.toString() == FlowVaultsEVM.nativeFlowEVMAddress.toString(),
            message: "balanceFromUFix64 should only be called for native FLOW, not ERC20 tokens"
        )

        let bal = EVM.Balance(attoflow: 0)
        bal.setFLOW(flow: value)
        return bal
    }

    access(self) fun decodeEVMError(_ data: [UInt8]): String {
        if data.length >= 4 {
            let selector = (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
            if selector == 0x08c379a0 && data.length > 4 {
                let payload = data.slice(from: 4, upTo: data.length)
                let decoded = EVM.decodeABI(types: [Type<String>()], data: payload)
                if decoded.length > 0 {
                    if let errorMsg = decoded[0] as? String {
                        return errorMsg
                    }
                }
            }
        }
        return "EVM revert data: 0x\(String.encodeHex(data))"
    }

    // ============================================
    // Initialization
    // ============================================

    init() {
        self.noTideId = UInt64.max
        self.nativeFlowEVMAddress = EVM.addressFromString("0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF")
        self.WorkerStoragePath = /storage/flowVaultsEVM
        self.AdminStoragePath = /storage/flowVaultsEVMAdmin
        self.maxRequestsPerTx = 1
        self.tidesByEVMAddress = {}
        self.tideOwnershipLookup = {}
        self.flowVaultsRequestsAddress = nil

        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
