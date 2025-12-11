import "FungibleToken"
import "FlowToken"
import "EVM"
import "Burner"

import "FlowYieldVaults"
import "FlowYieldVaultsClosedBeta"
import "FlowEVMBridgeUtils"
import "FlowEVMBridgeConfig"

/// @title FlowYieldVaultsEVM
/// @author Flow YieldVaults Team
/// @notice Bridge contract that processes requests from EVM users and manages their YieldVault positions in Cadence.
/// @dev This contract serves as the Cadence-side processor for cross-VM operations. It reads pending
///      requests from the FlowYieldVaultsRequests Solidity contract, executes the corresponding Flow YieldVaults
///      operations (create/deposit/withdraw/close YieldVault), and updates request status back on EVM.
///
///      Key architecture:
///      - Worker resource: Holds COA capability and YieldVaultManager, processes requests
///      - Admin resource: Manages contract configuration (requests address, batch size)
///      - Two-phase commit: Uses startProcessing() and completeProcessing() for atomic state management
///
///      Request flow:
///      1. Worker fetches pending requests from FlowYieldVaultsRequests (EVM)
///      2. For each request, calls startProcessing() to mark as PROCESSING and deduct balance
///      3. Executes Cadence-side operation (create/deposit/withdraw/close YieldVault)
///      4. Calls completeProcessing() to mark as COMPLETED or FAILED (with refund on failure)
access(all) contract FlowYieldVaultsEVM {

    // ============================================
    // Type Declarations
    // ============================================

    /// @notice Request types matching the Solidity RequestType enum
    /// @dev Must stay synchronized with FlowYieldVaultsRequests.sol RequestType enum
    access(all) enum RequestType: UInt8 {
        access(all) case CREATE_YIELDVAULT
        access(all) case DEPOSIT_TO_YIELDVAULT
        access(all) case WITHDRAW_FROM_YIELDVAULT
        access(all) case CLOSE_YIELDVAULT
    }

    /// @notice Request status matching the Solidity RequestStatus enum
    /// @dev Must stay synchronized with FlowYieldVaultsRequests.sol RequestStatus enum
    access(all) enum RequestStatus: UInt8 {
        access(all) case PENDING
        access(all) case PROCESSING
        access(all) case COMPLETED
        access(all) case FAILED
    }

    /// @notice Decoded request data from EVM contract
    /// @dev Mirrors the Request struct in FlowYieldVaultsRequests.sol for cross-VM communication
    access(all) struct EVMRequest {
        access(all) let id: UInt256
        access(all) let user: EVM.EVMAddress
        access(all) let requestType: UInt8
        access(all) let status: UInt8
        access(all) let tokenAddress: EVM.EVMAddress
        access(all) let amount: UInt256
        access(all) let yieldVaultId: UInt64
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
            yieldVaultId: UInt64,
            timestamp: UInt256,
            message: String,
            vaultIdentifier: String,
            strategyIdentifier: String
        ) {
            pre {
                requestType >= FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue &&
                requestType <= FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue:
                    "Invalid request type: must be between 0 (CREATE_YIELDVAULT) and 3 (CLOSE_YIELDVAULT)"

                status >= FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue &&
                status <= FlowYieldVaultsEVM.RequestStatus.FAILED.rawValue:
                    "Invalid status: must be between 0 (PENDING) and 3 (FAILED)"

                requestType == FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue || amount > 0:
                    "Amount must be greater than 0 for CREATE_YIELDVAULT, DEPOSIT_TO_YIELDVAULT, and WITHDRAW_FROM_YIELDVAULT operations"
            }
            self.id = id
            self.user = user
            self.requestType = requestType
            self.status = status
            self.tokenAddress = tokenAddress
            self.amount = amount
            self.yieldVaultId = yieldVaultId
            self.timestamp = timestamp
            self.message = message
            self.vaultIdentifier = vaultIdentifier
            self.strategyIdentifier = strategyIdentifier
        }
    }

    /// @notice Sentinel value for "no yieldvault" in ProcessResult
    /// @dev Uses UInt64.max as sentinel since yieldVaultId can legitimately be 0
    access(all) let noYieldVaultId: UInt64

    /// @notice Result of processing a single request
    /// @dev yieldVaultId uses UInt64.max as sentinel for "no yieldvault" since valid Ids can be 0
    access(all) struct ProcessResult {
        access(all) let success: Bool
        access(all) let yieldVaultId: UInt64
        access(all) let message: String

        init(success: Bool, yieldVaultId: UInt64, message: String) {
            self.success = success
            self.yieldVaultId = yieldVaultId
            self.message = message
        }
    }

    // ============================================
    // State Variables
    // ============================================

    /// @notice Sentinel address representing native $FLOW in EVM
    /// @dev Uses recognizable pattern (all F's) matching FlowYieldVaultsRequests.sol NATIVE_FLOW constant
    access(all) let nativeFlowEVMAddress: EVM.EVMAddress

    /// @notice Maximum requests to process per transaction
    /// @dev Configurable by Admin for performance tuning. Higher values increase throughput
    ///      but risk hitting gas limits. Recommended range: 5-50.
    access(all) var maxRequestsPerTx: Int

    /// @notice Storage path for Worker resource
    access(all) let WorkerStoragePath: StoragePath

    /// @notice Storage path for Admin resource
    access(all) let AdminStoragePath: StoragePath

    /// @notice YieldVault Ids owned by each EVM address
    /// @dev Maps EVM address string to array of owned YieldVault Ids for public queries
    access(all) let yieldVaultsByEVMAddress: {String: [UInt64]}

    /// @notice O(1) lookup for yieldvault ownership verification
    /// @dev Maps EVM address string to {yieldVaultId: true} for fast ownership checks
    access(all) let yieldVaultOwnershipLookup: {String: {UInt64: Bool}}

    /// @notice Address of the FlowYieldVaultsRequests contract on EVM
    access(all) var flowYieldVaultsRequestsAddress: EVM.EVMAddress?

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when a Worker is initialized
    /// @param coaAddress The COA address associated with the Worker
    access(all) event WorkerInitialized(coaAddress: String)

    /// @notice Emitted when the FlowYieldVaultsRequests address is set
    /// @param address The EVM address of the FlowYieldVaultsRequests contract
    access(all) event FlowYieldVaultsRequestsAddressSet(address: String)

    /// @notice Emitted after processing a batch of requests
    /// @param count Total requests processed
    /// @param successful Number of successful requests
    /// @param failed Number of failed requests
    access(all) event RequestsProcessed(count: Int, successful: Int, failed: Int)

    /// @notice Emitted when a new YieldVault is created for an EVM user
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The newly created YieldVault Id
    /// @param amount The initial deposit amount
    access(all) event YieldVaultCreatedForEVMUser(evmAddress: String, yieldVaultId: UInt64, amount: UFix64)

    /// @notice Emitted when funds are deposited to an existing YieldVault
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The YieldVault Id receiving the deposit
    /// @param amount The deposited amount
    /// @param isYieldVaultOwner Whether the depositor is the yieldvault owner
    access(all) event YieldVaultDepositedForEVMUser(evmAddress: String, yieldVaultId: UInt64, amount: UFix64, isYieldVaultOwner: Bool)

    /// @notice Emitted when funds are withdrawn from a YieldVault
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The YieldVault Id being withdrawn from
    /// @param amount The withdrawn amount
    access(all) event YieldVaultWithdrawnForEVMUser(evmAddress: String, yieldVaultId: UInt64, amount: UFix64)

    /// @notice Emitted when a YieldVault is closed
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The closed YieldVault Id
    /// @param amountReturned The total amount returned to the user
    access(all) event YieldVaultClosedForEVMUser(evmAddress: String, yieldVaultId: UInt64, amountReturned: UFix64)

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

    /// @notice Emitted when allowlist status changes on EVM
    /// @param enabled The new allowlist status
    access(all) event EVMAllowlistStatusChanged(enabled: Bool)

    /// @notice Emitted when addresses are added/removed from allowlist on EVM
    /// @param addresses The addresses that were updated
    /// @param added True if addresses were added, false if removed
    access(all) event EVMAllowlistUpdated(addresses: [String], added: Bool)

    /// @notice Emitted when blocklist status changes on EVM
    /// @param enabled The new blocklist status
    access(all) event EVMBlocklistStatusChanged(enabled: Bool)

    /// @notice Emitted when addresses are added/removed from blocklist on EVM
    /// @param addresses The addresses that were updated
    /// @param added True if addresses were added, false if removed
    access(all) event EVMBlocklistUpdated(addresses: [String], added: Bool)

    /// @notice Emitted when token configuration changes on EVM
    /// @param tokenAddress The token address configured
    /// @param isSupported Whether the token is supported
    /// @param minimumBalance The minimum balance required
    /// @param isNative Whether the token is native FLOW
    access(all) event EVMTokenConfigured(tokenAddress: String, isSupported: Bool, minimumBalance: UInt256, isNative: Bool)

    /// @notice Emitted when authorized COA changes on EVM
    /// @param newCOA The new authorized COA address
    access(all) event EVMAuthorizedCOAUpdated(newCOA: String)

    /// @notice Emitted when max pending requests per user changes on EVM
    /// @param maxRequests The new maximum pending requests per user
    access(all) event EVMMaxPendingRequestsPerUserUpdated(maxRequests: UInt256)

    /// @notice Emitted when requests are dropped on EVM
    /// @param requestIds The request IDs that were dropped
    access(all) event EVMRequestsDropped(requestIds: [UInt256])

    /// @notice Emitted when a request is cancelled on EVM
    /// @param requestId The request ID that was cancelled
    access(all) event EVMRequestCancelled(requestId: UInt256)

    // ============================================
    // Resources
    // ============================================

    /// @notice Admin resource for contract configuration
    /// @dev Only the contract deployer receives this resource
    access(all) resource Admin {

        /// @notice Sets the FlowYieldVaultsRequests address (first time only)
        /// @param address The EVM address of the FlowYieldVaultsRequests contract
        access(all) fun setFlowYieldVaultsRequestsAddress(_ address: EVM.EVMAddress) {
            pre {
                FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress == nil: "FlowYieldVaultsRequests address already set"
            }
            FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress = address
            emit FlowYieldVaultsRequestsAddressSet(address: address.toString())
        }

        /// @notice Updates the FlowYieldVaultsRequests address
        /// @param address The new EVM address of the FlowYieldVaultsRequests contract
        access(all) fun updateFlowYieldVaultsRequestsAddress(_ address: EVM.EVMAddress) {
            FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress = address
            emit FlowYieldVaultsRequestsAddressSet(address: address.toString())
        }

        /// @notice Updates the maximum requests processed per transaction
        /// @param newMax The new maximum (must be 1-100)
        access(all) fun updateMaxRequestsPerTx(_ newMax: Int) {
            pre {
                newMax > 0: "maxRequestsPerTx must be greater than 0"
                newMax <= 100: "maxRequestsPerTx should not exceed 100 for gas safety"
            }

            let oldMax = FlowYieldVaultsEVM.maxRequestsPerTx
            FlowYieldVaultsEVM.maxRequestsPerTx = newMax

            emit MaxRequestsPerTxUpdated(oldValue: oldMax, newValue: newMax)
        }

        /// @notice Creates a new Worker resource
        /// @param coaCap Capability to the COA with Call, Withdraw, and Bridge entitlements
        /// @param yieldVaultManagerCap Capability to the YieldVaultManager with Withdraw entitlement
        /// @param betaBadgeCap Capability to the beta badge for Flow YieldVaults access
        /// @param feeProviderCap Capability to withdraw fees for bridge operations
        /// @return The newly created Worker resource
        access(all) fun createWorker(
            coaCap: Capability<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>,
            yieldVaultManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>,
            betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>,
            feeProviderCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>
        ): @Worker {
            let worker <- create Worker(
                coaCap: coaCap,
                yieldVaultManagerCap: yieldVaultManagerCap,
                betaBadgeCap: betaBadgeCap,
                feeProviderCap: feeProviderCap
            )
            emit WorkerInitialized(coaAddress: worker.getCOAAddressString())
            return <-worker
        }
    }

    /// @notice Worker resource that processes EVM requests
    /// @dev Holds capabilities to COA, beta badge, fee provider, and YieldVaultManager.
    ///      YieldVaultManager is stored separately and accessed via capability for better composability.
    access(all) resource Worker {
        access(self) let coaCap: Capability<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>
        access(self) let yieldVaultManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>
        access(self) let betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>
        access(self) let feeProviderCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>

        init(
            coaCap: Capability<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>,
            yieldVaultManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>,
            betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>,
            feeProviderCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>
        ) {
            pre {
                coaCap.check(): "COA capability is invalid"
                yieldVaultManagerCap.check(): "YieldVaultManager capability is invalid"
                feeProviderCap.check(): "Fee provider capability is invalid"
            }

            self.coaCap = coaCap
            self.yieldVaultManagerCap = yieldVaultManagerCap
            self.betaBadgeCap = betaBadgeCap
            self.feeProviderCap = feeProviderCap
        }

        access(self) view fun getCOARef(): auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount {
            return self.coaCap.borrow()
                ?? panic("Could not borrow COA capability")
        }

        access(self) fun getYieldVaultManagerRef(): auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager {
            return self.yieldVaultManagerCap.borrow()
                ?? panic("Could not borrow YieldVaultManager capability")
        }

        access(self) view fun getBetaReference(): auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge {
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
                FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress != nil: "FlowYieldVaultsRequests address not set"
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
                request.amount > 0 || request.requestType == FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue: "Request amount must be greater than 0 for non-close operations"
                request.status == FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue: "Request must be in PENDING status"
            }
            var success = false
            var yieldVaultId: UInt64 = FlowYieldVaultsEVM.noYieldVaultId
            var message = ""

            let needsStartProcessing = request.requestType == FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue
                || request.requestType == FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue

            if needsStartProcessing {
                if !self.startProcessing(requestId: request.id) {
                    if !self.completeProcessing(
                        requestId: request.id,
                        success: false,
                        yieldVaultId: request.yieldVaultId,
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
                case FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue:
                    let result = self.processCreateYieldVault(request)
                    success = result.success
                    yieldVaultId = result.yieldVaultId
                    message = result.message
                case FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue:
                    let result = self.processDepositToYieldVault(request)
                    success = result.success
                    yieldVaultId = result.yieldVaultId != FlowYieldVaultsEVM.noYieldVaultId ? result.yieldVaultId : request.yieldVaultId
                    message = result.message
                case FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue:
                    let result = self.processWithdrawFromYieldVault(request)
                    success = result.success
                    yieldVaultId = result.yieldVaultId != FlowYieldVaultsEVM.noYieldVaultId ? result.yieldVaultId : request.yieldVaultId
                    message = result.message
                case FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue:
                    let result = self.processCloseYieldVault(request)
                    success = result.success
                    yieldVaultId = result.yieldVaultId != FlowYieldVaultsEVM.noYieldVaultId ? result.yieldVaultId : request.yieldVaultId
                    message = result.message
                default:
                    success = false
                    message = "Unknown request type: \(request.requestType) for request ID \(request.id)"
            }

            if !self.completeProcessing(
                requestId: request.id,
                success: success,
                yieldVaultId: yieldVaultId,
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
                yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                message: errorMessage.concat(". Funds returned to user.")
            )
        }

        access(self) fun processCreateYieldVault(_ request: EVMRequest): ProcessResult {
            let vaultIdentifier = request.vaultIdentifier
            let strategyIdentifier = request.strategyIdentifier
            let amount = FlowYieldVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            if !self.startProcessing(requestId: request.id) {
                return ProcessResult(
                    success: false,
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
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
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
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
            let yieldVaultManager = self.getYieldVaultManagerRef()

            let yieldVaultId = yieldVaultManager.createYieldVault(
                betaRef: betaRef,
                strategyType: strategyType!,
                withVault: <-vault
            )

            let evmAddr = request.user.toString()

            if FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr] == nil {
                FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr] = []
            }
            FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr]!.append(yieldVaultId)

            if FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] == nil {
                FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] = {}
            }
            FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr]!.insert(key: yieldVaultId, true)

            emit YieldVaultCreatedForEVMUser(evmAddress: evmAddr, yieldVaultId: yieldVaultId, amount: amount)

            return ProcessResult(
                success: true,
                yieldVaultId: yieldVaultId,
                message: "YieldVault Id \(yieldVaultId) created successfully with amount \(amount) FLOW"
            )
        }

        access(self) fun processCloseYieldVault(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            if let ownershipMap = FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] {
                if ownershipMap[request.yieldVaultId] != true {
                    return ProcessResult(
                        success: false,
                        yieldVaultId: request.yieldVaultId,
                        message: "User \(evmAddr) does not own YieldVault Id \(request.yieldVaultId)"
                    )
                }
            } else {
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "User \(evmAddr) has no YieldVaults registered"
                )
            }

            let vault <- self.getYieldVaultManagerRef().closeYieldVault(request.yieldVaultId)
            let amount = vault.balance

            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user, tokenAddress: request.tokenAddress)

            if let index = FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr]!.firstIndex(of: request.yieldVaultId) {
                let _ = FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr]!.remove(at: index)
            }
            FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr]!.remove(key: request.yieldVaultId)

            emit YieldVaultClosedForEVMUser(evmAddress: evmAddr, yieldVaultId: request.yieldVaultId, amountReturned: amount)

            return ProcessResult(
                success: true,
                yieldVaultId: request.yieldVaultId,
                message: "YieldVault Id \(request.yieldVaultId) closed successfully, returned \(amount) FLOW"
            )
        }

        access(self) fun processDepositToYieldVault(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            if !self.startProcessing(requestId: request.id) {
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "Failed to start processing - request may already be processing or completed"
                )
            }

            let amount = FlowYieldVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            let vaultOptional <- self.withdrawFundsFromCOA(
                amount: amount,
                tokenAddress: request.tokenAddress
            )

            if vaultOptional == nil {
                destroy vaultOptional
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "Failed to withdraw funds from COA"
                )
            }

            let vault <- vaultOptional!

            let betaRef = self.getBetaReference()
            self.getYieldVaultManagerRef().depositToYieldVault(betaRef: betaRef, request.yieldVaultId, from: <-vault)

            var isYieldVaultOwner = false
            if let ownershipMap = FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] {
                isYieldVaultOwner = ownershipMap[request.yieldVaultId] ?? false
            }
            emit YieldVaultDepositedForEVMUser(evmAddress: evmAddr, yieldVaultId: request.yieldVaultId, amount: amount, isYieldVaultOwner: isYieldVaultOwner)

            return ProcessResult(
                success: true,
                yieldVaultId: request.yieldVaultId,
                message: "Deposited \(amount) FLOW to YieldVault Id \(request.yieldVaultId)"
            )
        }

        access(self) fun processWithdrawFromYieldVault(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            if let ownershipMap = FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] {
                if ownershipMap[request.yieldVaultId] != true {
                    return ProcessResult(
                        success: false,
                        yieldVaultId: request.yieldVaultId,
                        message: "User \(evmAddr) does not own YieldVault Id \(request.yieldVaultId)"
                    )
                }
            } else {
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "User \(evmAddr) has no YieldVaults registered"
                )
            }

            let amount = FlowYieldVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            let vault <- self.getYieldVaultManagerRef().withdrawFromYieldVault(request.yieldVaultId, amount: amount)

            let actualAmount = vault.balance
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user, tokenAddress: request.tokenAddress)

            emit YieldVaultWithdrawnForEVMUser(evmAddress: evmAddr, yieldVaultId: request.yieldVaultId, amount: actualAmount)

            return ProcessResult(
                success: true,
                yieldVaultId: request.yieldVaultId,
                message: "Withdrew \(actualAmount) FLOW from YieldVault Id \(request.yieldVaultId)"
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
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 200_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
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
        /// @param yieldVaultId The associated YieldVault Id
        /// @param message Status message or error reason
        /// @return True if the EVM call succeeded, false otherwise
        access(self) fun completeProcessing(requestId: UInt256, success: Bool, yieldVaultId: UInt64, message: String): Bool {
            let status = success
                ? FlowYieldVaultsEVM.RequestStatus.COMPLETED.rawValue
                : FlowYieldVaultsEVM.RequestStatus.FAILED.rawValue

            let calldata = EVM.encodeABIWithSignature(
                "completeProcessing(uint256,bool,uint64,string)",
                [requestId, success, yieldVaultId, message]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 1_000_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
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
            if tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString() {
                let balance = FlowYieldVaultsEVM.balanceFromUFix64(amount, tokenAddress: tokenAddress)
                let vault <- self.getCOARef().withdraw(balance: balance)

                if vault.balance == 0.0 {
                    destroy vault
                    return nil
                }

                return <-vault
            } else {
                let amountUInt256 = FlowYieldVaultsEVM.uint256FromUFix64(amount, tokenAddress: tokenAddress)
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

            if tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString() {
                self.getCOARef().deposit(from: <-vault as! @FlowToken.Vault)
                let balance = FlowYieldVaultsEVM.balanceFromUFix64(amount, tokenAddress: tokenAddress)
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
            let amountUInt256 = FlowYieldVaultsEVM.uint256FromUFix64(vault.balance, tokenAddress: tokenAddress)

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
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(transferResult.data)
                panic("ERC20 transfer to recipient failed: \(errorMsg)")
            }
        }

        /// @notice Gets the count of pending requests from the EVM contract
        /// @return The number of pending requests
        access(all) fun getPendingRequestCountFromEVM(): Int {
            let calldata = EVM.encodeABIWithSignature("getPendingRequestCount()", [])

            let callResult = self.getCOARef().dryCall(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )

            if callResult.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(callResult.data)
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
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 15_000_000,
                value: EVM.Balance(attoflow: 0)
            )

            if callResult.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(callResult.data)
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
            let yieldVaultIds = decoded[6] as! [UInt64]
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
                    yieldVaultId: yieldVaultIds[i],
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

        // ============================================
        // EVM Admin Functions
        // ============================================

        /// @dev Converts an array of EVM addresses to an array of strings for event emission
        access(self) fun evmAddressesToStrings(_ addresses: [EVM.EVMAddress]): [String] {
            var result: [String] = []
            for addr in addresses {
                result.append(addr.toString())
            }
            return result
        }

        /// @notice Enables or disables the allowlist on the EVM contract
        /// @param enabled True to enable, false to disable
        access(all) fun setAllowlistEnabled(_ enabled: Bool) {
            let calldata = EVM.encodeABIWithSignature(
                "setAllowlistEnabled(bool)",
                [enabled]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("setAllowlistEnabled failed: ".concat(errorMsg))
            }

            emit EVMAllowlistStatusChanged(enabled: enabled)
        }

        /// @notice Adds multiple addresses to the allowlist on the EVM contract
        /// @param addresses The addresses to add to the allowlist
        access(all) fun batchAddToAllowlist(_ addresses: [EVM.EVMAddress]) {
            let calldata = EVM.encodeABIWithSignature(
                "batchAddToAllowlist(address[])",
                [addresses]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 300_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("batchAddToAllowlist failed: ".concat(errorMsg))
            }

            emit EVMAllowlistUpdated(addresses: self.evmAddressesToStrings(addresses), added: true)
        }

        /// @notice Removes multiple addresses from the allowlist on the EVM contract
        /// @param addresses The addresses to remove from the allowlist
        access(all) fun batchRemoveFromAllowlist(_ addresses: [EVM.EVMAddress]) {
            let calldata = EVM.encodeABIWithSignature(
                "batchRemoveFromAllowlist(address[])",
                [addresses]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 300_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("batchRemoveFromAllowlist failed: ".concat(errorMsg))
            }

            emit EVMAllowlistUpdated(addresses: self.evmAddressesToStrings(addresses), added: false)
        }

        /// @notice Enables or disables the blocklist on the EVM contract
        /// @param enabled True to enable, false to disable
        access(all) fun setBlocklistEnabled(_ enabled: Bool) {
            let calldata = EVM.encodeABIWithSignature(
                "setBlocklistEnabled(bool)",
                [enabled]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("setBlocklistEnabled failed: ".concat(errorMsg))
            }

            emit EVMBlocklistStatusChanged(enabled: enabled)
        }

        /// @notice Adds multiple addresses to the blocklist on the EVM contract
        /// @param addresses The addresses to add to the blocklist
        access(all) fun batchAddToBlocklist(_ addresses: [EVM.EVMAddress]) {
            let calldata = EVM.encodeABIWithSignature(
                "batchAddToBlocklist(address[])",
                [addresses]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 300_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("batchAddToBlocklist failed: ".concat(errorMsg))
            }

            emit EVMBlocklistUpdated(addresses: self.evmAddressesToStrings(addresses), added: true)
        }

        /// @notice Removes multiple addresses from the blocklist on the EVM contract
        /// @param addresses The addresses to remove from the blocklist
        access(all) fun batchRemoveFromBlocklist(_ addresses: [EVM.EVMAddress]) {
            let calldata = EVM.encodeABIWithSignature(
                "batchRemoveFromBlocklist(address[])",
                [addresses]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 300_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("batchRemoveFromBlocklist failed: ".concat(errorMsg))
            }

            emit EVMBlocklistUpdated(addresses: self.evmAddressesToStrings(addresses), added: false)
        }

        /// @notice Configures a token on the EVM contract
        /// @param tokenAddress The token address to configure
        /// @param isSupported Whether the token is supported
        /// @param minimumBalance The minimum balance required for deposits
        /// @param isNative Whether the token is native FLOW
        access(all) fun setTokenConfig(
            tokenAddress: EVM.EVMAddress,
            isSupported: Bool,
            minimumBalance: UInt256,
            isNative: Bool
        ) {
            let calldata = EVM.encodeABIWithSignature(
                "setTokenConfig(address,bool,uint256,bool)",
                [tokenAddress, isSupported, minimumBalance, isNative]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 150_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("setTokenConfig failed: ".concat(errorMsg))
            }

            emit EVMTokenConfigured(
                tokenAddress: tokenAddress.toString(),
                isSupported: isSupported,
                minimumBalance: minimumBalance,
                isNative: isNative
            )
        }

        /// @notice Sets the authorized COA address on the EVM contract
        /// @param coa The new authorized COA address
        access(all) fun setAuthorizedCOA(_ coa: EVM.EVMAddress) {
            let calldata = EVM.encodeABIWithSignature(
                "setAuthorizedCOA(address)",
                [coa]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("setAuthorizedCOA failed: ".concat(errorMsg))
            }

            emit EVMAuthorizedCOAUpdated(newCOA: coa.toString())
        }

        /// @notice Sets the maximum pending requests per user on the EVM contract
        /// @param maxRequests The new maximum pending requests per user (0 = unlimited)
        access(all) fun setMaxPendingRequestsPerUser(_ maxRequests: UInt256) {
            let calldata = EVM.encodeABIWithSignature(
                "setMaxPendingRequestsPerUser(uint256)",
                [maxRequests]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("setMaxPendingRequestsPerUser failed: ".concat(errorMsg))
            }

            emit EVMMaxPendingRequestsPerUserUpdated(maxRequests: maxRequests)
        }

        /// @notice Drops pending requests on the EVM contract and refunds users
        /// @param requestIds The request IDs to drop
        access(all) fun dropRequests(_ requestIds: [UInt256]) {
            let gasLimit: UInt64 = 500_000 + UInt64(requestIds.length) * 100_000

            let calldata = EVM.encodeABIWithSignature(
                "dropRequests(uint256[])",
                [requestIds]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: gasLimit,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("dropRequests failed: ".concat(errorMsg))
            }

            emit EVMRequestsDropped(requestIds: requestIds)
        }

        /// @notice Cancels a pending request on the EVM contract
        /// @param requestId The request ID to cancel
        access(all) fun cancelRequest(_ requestId: UInt256) {
            let calldata = EVM.encodeABIWithSignature(
                "cancelRequest(uint256)",
                [requestId]
            )

            let result = self.getCOARef().call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 300_000,
                value: EVM.Balance(attoflow: 0)
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                panic("cancelRequest failed: ".concat(errorMsg))
            }

            emit EVMRequestCancelled(requestId: requestId)
        }
    }

    // ============================================
    // Public Functions
    // ============================================

    /// @notice Gets all YieldVault Ids owned by an EVM address
    /// @param evmAddress The EVM address string to query
    /// @return Array of YieldVault Ids owned by the address
    access(all) view fun getYieldVaultIdsForEVMAddress(_ evmAddress: String): [UInt64] {
        return self.yieldVaultsByEVMAddress[evmAddress] ?? []
    }

    /// @notice Checks if an EVM address owns a specific YieldVault Id (O(1) lookup)
    /// @param evmAddress The EVM address string to check
    /// @param yieldVaultId The YieldVault Id to verify ownership of
    /// @return True if the address owns the YieldVault, false otherwise
    access(all) view fun doesEVMAddressOwnYieldVault(evmAddress: String, yieldVaultId: UInt64): Bool {
        if let ownershipMap = self.yieldVaultOwnershipLookup[evmAddress] {
            return ownershipMap[yieldVaultId] ?? false
        }
        return false
    }

    /// @notice Gets the configured FlowYieldVaultsRequests contract address
    /// @return The EVM address or nil if not set
    access(all) view fun getFlowYieldVaultsRequestsAddress(): EVM.EVMAddress? {
        return self.flowYieldVaultsRequestsAddress
    }

    // ============================================
    // Internal Functions
    // ============================================

    access(self) fun ufix64FromUInt256(_ value: UInt256, tokenAddress: EVM.EVMAddress): UFix64 {
        if tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString() {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: value, decimals: 18)
        }
        return FlowEVMBridgeUtils.convertERC20AmountToCadenceAmount(value, erc20Address: tokenAddress)
    }

    access(self) fun uint256FromUFix64(_ value: UFix64, tokenAddress: EVM.EVMAddress): UInt256 {
        if tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString() {
            return FlowEVMBridgeUtils.ufix64ToUInt256(value: value, decimals: 18)
        }
        return FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(value, erc20Address: tokenAddress)
    }

    access(self) fun balanceFromUFix64(_ value: UFix64, tokenAddress: EVM.EVMAddress): EVM.Balance {
        assert(
            tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString(),
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
        self.noYieldVaultId = UInt64.max
        self.nativeFlowEVMAddress = EVM.addressFromString("0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF")
        self.WorkerStoragePath = /storage/flowYieldVaultsEVM
        self.AdminStoragePath = /storage/flowYieldVaultsEVMAdmin
        self.maxRequestsPerTx = 1
        self.yieldVaultsByEVMAddress = {}
        self.yieldVaultOwnershipLookup = {}
        self.flowYieldVaultsRequestsAddress = nil

        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
