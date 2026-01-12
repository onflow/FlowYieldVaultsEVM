import "FungibleToken"
import "FlowToken"
import "EVM"

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
///      - Two-phase processing: Uses startProcessing() and completeProcessing() to coordinate EVM and Cadence state
///
///      Request flow:
///      1. Worker fetches pending requests from FlowYieldVaultsRequests (EVM)
///      2. For each request, calls startProcessing() to mark as PROCESSING (deducts escrow for CREATE/DEPOSIT)
///      3. Executes Cadence-side operation (create/deposit/withdraw/close YieldVault)
///      4. Calls completeProcessing() to mark as COMPLETED or FAILED (refunds escrow for CREATE/DEPOSIT failures)
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
                    "Invalid request type: expected 0 (CREATE_YIELDVAULT) to 3 (CLOSE_YIELDVAULT) but got \(requestType)"

                status >= FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue &&
                status <= FlowYieldVaultsEVM.RequestStatus.FAILED.rawValue:
                    "Invalid status: expected 0 (PENDING) to 3 (FAILED) but got \(status)"

                requestType == FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue || amount > 0:
                    "Amount must be greater than 0 for requestType \(requestType) but got amount \(amount)"
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

    /// @notice Pending requests info for a specific EVM address
    /// @dev Used to return aggregated pending request data for UI/queries
    access(all) struct PendingRequestsInfo {
        access(all) let evmAddress: String
        access(all) let pendingCount: Int
        access(all) let pendingBalance: UFix64
        access(all) let claimableRefund: UFix64
        access(all) let requests: [EVMRequest]

        init(evmAddress: String, pendingCount: Int, pendingBalance: UFix64, claimableRefund: UFix64, requests: [EVMRequest]) {
            self.evmAddress = evmAddress
            self.pendingCount = pendingCount
            self.pendingBalance = pendingBalance
            self.claimableRefund = claimableRefund
            self.requests = requests
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
    access(contract) var maxRequestsPerTx: Int

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
    access(contract) var flowYieldVaultsRequestsAddress: EVM.EVMAddress?

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when a Worker is initialized
    /// @dev All capabilities are expected to originate from the same Cadence account
    ///      (the transaction signer). This event does not include the Cadence owner address.
    /// @param coaAddress The COA address associated with the Worker
    /// @param coaCapId The capability ID for the COA
    /// @param yieldVaultManagerCapId The capability ID for the YieldVaultManager
    /// @param betaBadgeCapId The capability ID for the BetaBadge
    /// @param feeProviderCapId The capability ID for the fee provider
    access(all) event WorkerInitialized(
        coaAddress: String,
        coaCapId: UInt64,
        yieldVaultManagerCapId: UInt64,
        betaBadgeCapId: UInt64,
        feeProviderCapId: UInt64
    )

    /// @notice Emitted when the FlowYieldVaultsRequests address is set
    /// @param address The EVM address of the FlowYieldVaultsRequests contract
    access(all) event FlowYieldVaultsRequestsAddressSet(address: String)

    /// @notice Emitted after processing a batch of requests
    /// @param count Total requests processed
    /// @param successful Number of successful requests
    /// @param failed Number of failed requests
    access(all) event RequestsProcessed(count: Int, successful: Int, failed: Int)

    /// @notice Emitted when a new YieldVault is created for an EVM user
    /// @param requestId The EVM request ID that triggered this operation
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The newly created YieldVault Id
    /// @param amount The initial deposit amount
    /// @param tokenAddress The token address used for the deposit
    /// @param vaultIdentifier The Cadence vault type identifier
    /// @param strategyIdentifier The Cadence strategy type identifier
    access(all) event YieldVaultCreatedForEVMUser(
        requestId: UInt256,
        evmAddress: String,
        yieldVaultId: UInt64,
        amount: UFix64,
        tokenAddress: String,
        vaultIdentifier: String,
        strategyIdentifier: String
    )

    /// @notice Emitted when funds are deposited to an existing YieldVault
    /// @param requestId The EVM request ID that triggered this operation
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The YieldVault Id receiving the deposit
    /// @param amount The deposited amount
    /// @param tokenAddress The token address used for the deposit
    /// @param isYieldVaultOwner Whether the depositor is the yieldvault owner
    access(all) event YieldVaultDepositedForEVMUser(
        requestId: UInt256,
        evmAddress: String,
        yieldVaultId: UInt64,
        amount: UFix64,
        tokenAddress: String,
        isYieldVaultOwner: Bool
    )

    /// @notice Emitted when funds are withdrawn from a YieldVault
    /// @param requestId The EVM request ID that triggered this operation
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The YieldVault Id being withdrawn from
    /// @param amount The withdrawn amount
    /// @param tokenAddress The token address for the withdrawal
    access(all) event YieldVaultWithdrawnForEVMUser(
        requestId: UInt256,
        evmAddress: String,
        yieldVaultId: UInt64,
        amount: UFix64,
        tokenAddress: String
    )

    /// @notice Emitted when a YieldVault is closed
    /// @param requestId The EVM request ID that triggered this operation
    /// @param evmAddress The EVM address of the user
    /// @param yieldVaultId The closed YieldVault Id
    /// @param amountReturned The total amount returned to the user
    /// @param tokenAddress The token address for the returned funds
    access(all) event YieldVaultClosedForEVMUser(
        requestId: UInt256,
        evmAddress: String,
        yieldVaultId: UInt64,
        amountReturned: UFix64,
        tokenAddress: String
    )

    /// @notice Emitted when a request fails during processing
    /// @param requestId The failed request ID
    /// @param userAddress The EVM address of the user
    /// @param requestType The type of request that failed
    /// @param tokenAddress The token address involved in the request
    /// @param amount The amount involved in the request (in wei/smallest unit)
    /// @param yieldVaultId The YieldVault ID if applicable (UInt64.max if not applicable)
    /// @param reason The failure reason
    access(all) event RequestFailed(
        requestId: UInt256,
        userAddress: String,
        requestType: UInt8,
        tokenAddress: String,
        amount: UInt256,
        yieldVaultId: UInt64,
        reason: String
    )

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
                FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress == nil:
                    "FlowYieldVaultsRequests address already set to \(FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!.toString())"
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
                newMax > 0: "maxRequestsPerTx must be greater than 0 but got \(newMax)"
                newMax <= 100: "maxRequestsPerTx must not exceed 100 for gas safety but got \(newMax)"
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
            emit WorkerInitialized(
                coaAddress: worker.getCOAAddressString(),
                coaCapId: coaCap.id,
                yieldVaultManagerCapId: yieldVaultManagerCap.id,
                betaBadgeCapId: betaBadgeCap.id,
                feeProviderCapId: feeProviderCap.id
            )
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

        /// @notice Initializes the Worker with required capabilities
        /// @dev All capabilities are validated on initialization to ensure they can be borrowed.
        ///      The Worker stores capability references rather than resources for better composability.
        /// @param coaCap Capability to COA with Call, Withdraw, and Bridge entitlements for EVM interaction
        /// @param yieldVaultManagerCap Capability to YieldVaultManager with Withdraw entitlement for vault operations
        /// @param betaBadgeCap Capability to BetaBadge for Flow YieldVaults closed beta access
        /// @param feeProviderCap Capability to fee provider for paying bridge fees
        init(
            coaCap: Capability<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>,
            yieldVaultManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>,
            betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>,
            feeProviderCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>
        ) {
            pre {
                coaCap.check(): "COA capability is invalid (id: \(coaCap.id))"
                yieldVaultManagerCap.check(): "YieldVaultManager capability is invalid (id: \(yieldVaultManagerCap.id))"
                betaBadgeCap.check(): "BetaBadge capability is invalid (id: \(betaBadgeCap.id))"
                feeProviderCap.check(): "Fee provider capability is invalid (id: \(feeProviderCap.id))"
            }

            self.coaCap = coaCap
            self.yieldVaultManagerCap = yieldVaultManagerCap
            self.betaBadgeCap = betaBadgeCap
            self.feeProviderCap = feeProviderCap
        }

        /// @notice Borrows the COA reference from the stored capability
        /// @dev Used internally for all EVM interactions (calls, withdrawals, bridging)
        /// @return Authenticated reference to the CadenceOwnedAccount with full entitlements
        access(self) view fun getCOARef(): auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount {
            return self.coaCap.borrow()
                ?? panic("Could not borrow COA capability (id: \(self.coaCap.id))")
        }

        /// @notice Borrows the YieldVaultManager reference from the stored capability
        /// @dev Used for creating, depositing to, withdrawing from, and closing YieldVaults
        /// @return Authenticated reference to YieldVaultManager with Withdraw entitlement
        access(self) fun getYieldVaultManagerRef(): auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager {
            return self.yieldVaultManagerCap.borrow()
                ?? panic("Could not borrow YieldVaultManager capability (id: \(self.yieldVaultManagerCap.id))")
        }

        /// @notice Borrows the BetaBadge reference from the stored capability
        /// @dev Required for closed beta access to Flow YieldVaults protocol operations
        /// @return Authenticated reference to BetaBadge with Beta entitlement
        access(self) view fun getBetaReference(): auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge {
            return self.betaBadgeCap.borrow()
                ?? panic("Could not borrow beta badge capability (id: \(self.betaBadgeCap.id))")
        }

        /// @notice Returns the COA address as a string
        /// @return The EVM address string of the COA
        access(all) view fun getCOAAddressString(): String {
            return self.getCOARef().address().toString()
        }

        /// @notice Processes pending requests from the EVM contract
        /// @dev Fetches up to count pending requests and processes each one.
        ///      Uses two-phase processing (startProcessing → completeProcessing) to sync request status.
        /// @param startIndex The index to start fetching requests from
        /// @param count The number of requests to fetch
        access(all) fun processRequests(startIndex: Int, count: Int) {
            pre {
                FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress != nil:
                    "FlowYieldVaultsRequests address not set - call Admin.setFlowYieldVaultsRequestsAddress() first"
            }

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

        /// @notice Safely processes a single request with error handling and status updates
        /// @dev This is the main dispatcher that:
        ///      1. Validates request preconditions (amount, status)
        ///      2. For CREATE requests: validates vault/strategy parameters before fund withdrawal
        ///      3. For WITHDRAW/CLOSE: calls startProcessing before the operation
        ///      4. Dispatches to the appropriate process function based on request type
        ///      5. Calls completeProcessing to update final status (with refund on failure for CREATE/DEPOSIT)
        /// @param request The EVM request to process
        /// @return True if the request was processed successfully, false otherwise
        access(self) fun processRequestSafely(_ request: EVMRequest): Bool {
            pre {
                request.amount > 0 || request.requestType == FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue:
                    "Request amount must be greater than 0 for requestType \(request.requestType) but got amount \(request.amount) (requestId: \(request.id))"
                request.status == FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue:
                    "Request must be in PENDING (0) status but got \(request.status) (requestId: \(request.id))"
            }
            var success = false
            var yieldVaultId: UInt64 = FlowYieldVaultsEVM.noYieldVaultId
            var message = ""

            // Early validation for CREATE_YIELDVAULT requests
            // Validate vaultIdentifier and strategyIdentifier before fund withdrawal to prevent panics
            // Note: Must call startProcessing BEFORE completeProcessing because Solidity requires
            // request status to be PROCESSING before it can be marked COMPLETED/FAILED
            if request.requestType == FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue {
                let validationResult = self.validateCreateYieldVaultParameters(request)
                if !validationResult.success {
                    // Start processing first to transition request from PENDING to PROCESSING
                    // This is required because completeProcessing requires PROCESSING status
                    if !self.startProcessing(requestId: request.id) {
                        emit RequestFailed(
                            requestId: request.id,
                            userAddress: request.user.toString(),
                            requestType: request.requestType,
                            tokenAddress: request.tokenAddress.toString(),
                            amount: request.amount,
                            yieldVaultId: request.yieldVaultId,
                            reason: "Validation failed and could not start processing: \(validationResult.message)"
                        )
                        return false
                    }
                    // Now we can mark as failed - request is in PROCESSING status
                    // Refund funds since startProcessing moved them to COA
                    if !self.completeProcessing(
                        requestId: request.id,
                        success: false,
                        yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                        message: validationResult.message,
                        refundAmount: request.amount,
                        tokenAddress: request.tokenAddress,
                        requestType: request.requestType
                    ) {
                        emit RequestFailed(
                            requestId: request.id,
                            userAddress: request.user.toString(),
                            requestType: request.requestType,
                            tokenAddress: request.tokenAddress.toString(),
                            amount: request.amount,
                            yieldVaultId: request.yieldVaultId,
                            reason: "Validation failed and could not complete processing: \(validationResult.message)"
                        )
                    }
                    return false
                }
            }

            // WITHDRAW/CLOSE: Call startProcessing here before the switch statement.
            // CREATE/DEPOSIT: startProcessing is called inside their respective process functions
            // (processCreateYieldVault, processDepositToYieldVault) or in the validation block above,
            // because they need to handle fund withdrawal from COA after startProcessing succeeds.
            let needsStartProcessing = request.requestType == FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue
                || request.requestType == FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue

            if needsStartProcessing {
                if !self.startProcessing(requestId: request.id) {
                    // WITHDRAW/CLOSE don't escrow deposits, so no refund needed on failure
                    if !self.completeProcessing(
                        requestId: request.id,
                        success: false,
                        yieldVaultId: request.yieldVaultId,
                        message: "Failed to start processing request \(request.id)",
                        refundAmount: 0,
                        tokenAddress: request.tokenAddress,
                        requestType: request.requestType
                    ) {
                        emit RequestFailed(
                            requestId: request.id,
                            userAddress: request.user.toString(),
                            requestType: request.requestType,
                            tokenAddress: request.tokenAddress.toString(),
                            amount: request.amount,
                            yieldVaultId: request.yieldVaultId,
                            reason: "Failed to start processing and complete processing for request \(request.id)"
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

            // Pass refund info - completeProcessing will determine if refund is needed
            // based on success flag and request type
            if !self.completeProcessing(
                requestId: request.id,
                success: success,
                yieldVaultId: yieldVaultId,
                message: message,
                refundAmount: request.amount,
                tokenAddress: request.tokenAddress,
                requestType: request.requestType
            ) {
                emit RequestFailed(
                    requestId: request.id,
                    userAddress: request.user.toString(),
                    requestType: request.requestType,
                    tokenAddress: request.tokenAddress.toString(),
                    amount: request.amount,
                    yieldVaultId: yieldVaultId,
                    reason: "Processing completed but failed to update status: \(message)"
                )
            }

            if !success {
                emit RequestFailed(
                    requestId: request.id,
                    userAddress: request.user.toString(),
                    requestType: request.requestType,
                    tokenAddress: request.tokenAddress.toString(),
                    amount: request.amount,
                    yieldVaultId: yieldVaultId,
                    reason: message
                )
            }

            return success
        }

        /// @notice Helper function to return funds to user and create a failure result
        /// @dev Used when an operation fails after funds have already been withdrawn from COA.
        ///      Bridges the vault contents back to the user's EVM address before returning.
        /// @param vault The vault containing funds to return (will be consumed)
        /// @param recipient The EVM address to send funds back to
        /// @param tokenAddress The token address (native FLOW or ERC20) for bridging
        /// @param errorMessage The error message to include in the result
        /// @return ProcessResult with success=false and the error message appended with "Funds returned to user"
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
                message: "\(errorMessage). Funds returned to user."
            )
        }

        /// @notice Validates CREATE_YIELDVAULT request parameters before processing
        /// @dev Validates that vaultIdentifier and strategyIdentifier are valid Cadence types
        ///      and that the strategy is supported by FlowYieldVaults protocol.
        ///      This prevents panics during createYieldVault by catching invalid parameters early.
        ///      Note: Basic string validations (empty checks) should be done on the Solidity side.
        /// @param request The request to validate
        /// @return ProcessResult with success=true if valid, or success=false with error message
        access(self) fun validateCreateYieldVaultParameters(_ request: EVMRequest): ProcessResult {
            // Validate vaultIdentifier is a valid Cadence type identifier
            let vaultType = CompositeType(request.vaultIdentifier)
            if vaultType == nil {
                return ProcessResult(
                    success: false,
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                    message: "Invalid vaultIdentifier: \(request.vaultIdentifier) is not a valid Cadence type"
                )
            }

            // Validate strategyIdentifier is a valid Cadence type identifier
            let strategyType = CompositeType(request.strategyIdentifier)
            if strategyType == nil {
                return ProcessResult(
                    success: false,
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                    message: "Invalid strategyIdentifier: \(request.strategyIdentifier) is not a valid Cadence type"
                )
            }

            // Validate strategy is supported by FlowYieldVaults protocol
            let supportedStrategies = FlowYieldVaults.getSupportedStrategies()
            var isStrategySupported = false
            for supported in supportedStrategies {
                if supported == strategyType! {
                    isStrategySupported = true
                    break
                }
            }
            if !isStrategySupported {
                return ProcessResult(
                    success: false,
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                    message: "Unsupported strategy: \(request.strategyIdentifier) is not supported by FlowYieldVaults"
                )
            }

            // Validate vault type is supported for this strategy's initialization
            let supportedVaults = FlowYieldVaults.getSupportedInitializationVaults(forStrategy: strategyType!)
            if supportedVaults[vaultType!] != true {
                return ProcessResult(
                    success: false,
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                    message: "Unsupported vault type: \(request.vaultIdentifier) cannot be used to initialize strategy \(request.strategyIdentifier)"
                )
            }

            // Validation passed
            return ProcessResult(
                success: true,
                yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                message: "Validation passed"
            )
        }

        /// @notice Processes a CREATE_YIELDVAULT request
        /// @dev Creates a new YieldVault for the EVM user with the specified vault type and strategy.
        ///      Flow:
        ///      1. Calls startProcessing to mark request as PROCESSING and transfer funds to COA
        ///      2. Withdraws funds from COA (bridging ERC20 if needed)
        ///      3. Validates vault type matches the requested vaultIdentifier
        ///      4. Creates YieldVault via YieldVaultManager
        ///      5. Records ownership in yieldVaultsByEVMAddress and yieldVaultOwnershipLookup
        /// @param request The CREATE_YIELDVAULT request containing vault/strategy identifiers and amount
        /// @return ProcessResult with success status, created yieldVaultId, and status message
        access(self) fun processCreateYieldVault(_ request: EVMRequest): ProcessResult {
            let vaultIdentifier = request.vaultIdentifier
            let strategyIdentifier = request.strategyIdentifier
            let amount = FlowYieldVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            // Phase 1: Mark request as PROCESSING and transfer escrowed funds to COA
            if !self.startProcessing(requestId: request.id) {
                return ProcessResult(
                    success: false,
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                    message: "Failed to start processing request \(request.id) - request may already be processing or completed"
                )
            }

            // Phase 2: Withdraw funds from COA (bridges ERC20 to Cadence vault if needed)
            let vaultOptional <- self.withdrawFundsFromCOA(
                amount: amount,
                tokenAddress: request.tokenAddress
            )

            if vaultOptional == nil {
                destroy vaultOptional
                return ProcessResult(
                    success: false,
                    yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
                    message: "Failed to withdraw \(amount) from COA for request \(request.id) (token: \(request.tokenAddress.toString()))"
                )
            }

            let vault <- vaultOptional!

            // Phase 3: Validate vault type matches the requested identifier
            let vaultType = vault.getType()
            if vaultType.identifier != vaultIdentifier {
                return self.returnFundsAndFail(
                    vault: <-vault,
                    recipient: request.user,
                    tokenAddress: request.tokenAddress,
                    errorMessage: "Vault type mismatch: expected \(vaultIdentifier), got \(vaultType.identifier)"
                )
            }

            // Phase 4: Create the YieldVault with the specified strategy
            // Note: strategyIdentifier already validated by validateCreateYieldVaultParameters
            let strategyType = CompositeType(strategyIdentifier)!

            let betaRef = self.getBetaReference()
            let yieldVaultManager = self.getYieldVaultManagerRef()

            let yieldVaultId = yieldVaultManager.createYieldVault(
                betaRef: betaRef,
                strategyType: strategyType,
                withVault: <-vault
            )

            // Phase 5: Record ownership in contract state for O(1) lookups
            let evmAddr = request.user.toString()

            // Initialize array for this address if needed
            if FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr] == nil {
                FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr] = []
            }
            FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr]!.append(yieldVaultId)

            // Initialize ownership map for this address if needed
            if FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] == nil {
                FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] = {}
            }
            FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr]!.insert(key: yieldVaultId, true)

            emit YieldVaultCreatedForEVMUser(
                requestId: request.id,
                evmAddress: evmAddr,
                yieldVaultId: yieldVaultId,
                amount: amount,
                tokenAddress: request.tokenAddress.toString(),
                vaultIdentifier: vaultIdentifier,
                strategyIdentifier: strategyIdentifier
            )

            return ProcessResult(
                success: true,
                yieldVaultId: yieldVaultId,
                message: "YieldVault Id \(yieldVaultId) created successfully with amount \(amount) FLOW"
            )
        }

        /// @notice Processes a CLOSE_YIELDVAULT request
        /// @dev Closes an existing YieldVault and returns all funds to the EVM user.
        ///      Flow:
        ///      1. Validates the user owns the specified YieldVault
        ///      2. Closes the YieldVault via YieldVaultManager (returns vault with all funds)
        ///      3. Bridges funds back to user's EVM address
        ///      4. Removes yieldVaultId from ownership tracking
        /// @param request The CLOSE_YIELDVAULT request containing the yieldVaultId to close
        /// @return ProcessResult with success status, the closed yieldVaultId, and amount returned
        access(self) fun processCloseYieldVault(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            // Step 1: Validate user ownership of the YieldVault
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

            // Step 2: Close YieldVault and retrieve all funds
            let vault <- self.getYieldVaultManagerRef().closeYieldVault(request.yieldVaultId)
            let amount = vault.balance

            // Step 3: Bridge funds back to user's EVM address
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user, tokenAddress: request.tokenAddress)

            // Step 4: Remove yieldVaultId from ownership tracking
            if let index = FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr]!.firstIndex(of: request.yieldVaultId) {
                let _ = FlowYieldVaultsEVM.yieldVaultsByEVMAddress[evmAddr]!.remove(at: index)
            }
            FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr]!.remove(key: request.yieldVaultId)

            emit YieldVaultClosedForEVMUser(
                requestId: request.id,
                evmAddress: evmAddr,
                yieldVaultId: request.yieldVaultId,
                amountReturned: amount,
                tokenAddress: request.tokenAddress.toString()
            )

            return ProcessResult(
                success: true,
                yieldVaultId: request.yieldVaultId,
                message: "YieldVault Id \(request.yieldVaultId) closed successfully, returned \(amount) FLOW"
            )
        }

        /// @notice Processes a DEPOSIT_TO_YIELDVAULT request
        /// @dev Deposits additional funds into an existing YieldVault.
        ///      Note: Unlike CLOSE/WITHDRAW, anyone can deposit to any YieldVault (no ownership check).
        ///      Flow:
        ///      1. Calls startProcessing to mark request as PROCESSING and transfer funds to COA
        ///      2. Withdraws funds from COA (bridging ERC20 if needed)
        ///      3. Deposits to YieldVault via YieldVaultManager
        /// @param request The DEPOSIT_TO_YIELDVAULT request containing yieldVaultId and amount
        /// @return ProcessResult with success status, the yieldVaultId, and deposited amount
        access(self) fun processDepositToYieldVault(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            // Step 1: Mark request as PROCESSING and transfer escrowed funds to COA
            if !self.startProcessing(requestId: request.id) {
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "Failed to start processing request \(request.id) - request may already be processing or completed"
                )
            }

            let amount = FlowYieldVaultsEVM.ufix64FromUInt256(request.amount, tokenAddress: request.tokenAddress)

            // Step 2: Withdraw funds from COA (bridges ERC20 to Cadence vault if needed)
            let vaultOptional <- self.withdrawFundsFromCOA(
                amount: amount,
                tokenAddress: request.tokenAddress
            )

            if vaultOptional == nil {
                destroy vaultOptional
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "Failed to withdraw \(amount) from COA for request \(request.id) (token: \(request.tokenAddress.toString()))"
                )
            }

            let vault <- vaultOptional!

            // Step 3: Deposit to YieldVault via YieldVaultManager
            let betaRef = self.getBetaReference()
            self.getYieldVaultManagerRef().depositToYieldVault(betaRef: betaRef, request.yieldVaultId, from: <-vault)

            // Check if depositor is the owner for event emission
            var isYieldVaultOwner = false
            if let ownershipMap = FlowYieldVaultsEVM.yieldVaultOwnershipLookup[evmAddr] {
                isYieldVaultOwner = ownershipMap[request.yieldVaultId] ?? false
            }
            emit YieldVaultDepositedForEVMUser(
                requestId: request.id,
                evmAddress: evmAddr,
                yieldVaultId: request.yieldVaultId,
                amount: amount,
                tokenAddress: request.tokenAddress.toString(),
                isYieldVaultOwner: isYieldVaultOwner
            )

            return ProcessResult(
                success: true,
                yieldVaultId: request.yieldVaultId,
                message: "Deposited \(amount) FLOW to YieldVault Id \(request.yieldVaultId)"
            )
        }

        /// @notice Processes a WITHDRAW_FROM_YIELDVAULT request
        /// @dev Withdraws a specified amount from an existing YieldVault and sends to user.
        ///      Flow:
        ///      1. Validates the user owns the specified YieldVault
        ///      2. Validates YieldVault has sufficient balance for the withdrawal
        ///      3. Withdraws funds from YieldVault via YieldVaultManager
        ///      4. Bridges funds back to user's EVM address
        /// @param request The WITHDRAW_FROM_YIELDVAULT request containing yieldVaultId and amount
        /// @return ProcessResult with success status, the yieldVaultId, and withdrawn amount
        access(self) fun processWithdrawFromYieldVault(_ request: EVMRequest): ProcessResult {
            let evmAddr = request.user.toString()

            // Step 1: Validate user ownership of the YieldVault
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

            // Step 2: Pre-validate YieldVault exists and has sufficient balance
            let yieldVaultRef = self.getYieldVaultManagerRef().borrowYieldVault(id: request.yieldVaultId)
            if yieldVaultRef == nil {
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "YieldVault Id \(request.yieldVaultId) not found in manager"
                )
            }
            let availableBalance = yieldVaultRef!.getYieldVaultBalance()
            if amount > availableBalance {
                return ProcessResult(
                    success: false,
                    yieldVaultId: request.yieldVaultId,
                    message: "Requested withdrawal amount \(amount) exceeds YieldVault balance \(availableBalance)"
                )
            }

            // Step 3: Withdraw funds from YieldVault
            let vault <- self.getYieldVaultManagerRef().withdrawFromYieldVault(request.yieldVaultId, amount: amount)

            // Step 4: Bridge funds back to user's EVM address
            let actualAmount = vault.balance
            self.bridgeFundsToEVMUser(vault: <-vault, recipient: request.user, tokenAddress: request.tokenAddress)

            emit YieldVaultWithdrawnForEVMUser(
                requestId: request.id,
                evmAddress: evmAddr,
                yieldVaultId: request.yieldVaultId,
                amount: actualAmount,
                tokenAddress: request.tokenAddress.toString()
            )

            return ProcessResult(
                success: true,
                yieldVaultId: request.yieldVaultId,
                message: "Withdrew \(actualAmount) FLOW from YieldVault Id \(request.yieldVaultId)"
            )
        }

        /// @notice Marks a request as PROCESSING and transfers escrowed funds to COA
        /// @dev For CREATE/DEPOSIT: deducts user balance and transfers funds to COA for bridging.
        ///      For WITHDRAW/CLOSE: only updates status (no balance change).
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
                gasLimit: 15_000_000,
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

        /// @notice Marks a request as COMPLETED or FAILED, returning escrowed funds on failure
        /// @dev For failed CREATE/DEPOSIT: returns funds from COA to EVM contract via msg.value (native)
        ///      or approve+transferFrom (ERC20). For WITHDRAW/CLOSE or success: no refund sent.
        /// @param requestId The request ID to complete
        /// @param success Whether the operation succeeded
        /// @param yieldVaultId The associated YieldVault Id
        /// @param message Status message or error reason
        /// @param refundAmount Amount to refund (0 if no refund needed)
        /// @param tokenAddress Token address for refund (used to determine native vs ERC20)
        /// @param requestType The type of request (needed to determine if refund applies)
        /// @return True if the EVM call succeeded, false otherwise
        access(self) fun completeProcessing(
            requestId: UInt256,
            success: Bool,
            yieldVaultId: UInt64,
            message: String,
            refundAmount: UInt256,
            tokenAddress: EVM.EVMAddress,
            requestType: UInt8
        ): Bool {
            let calldata = EVM.encodeABIWithSignature(
                "completeProcessing(uint256,bool,uint64,string)",
                [requestId, success, yieldVaultId, message]
            )

            // Determine if refund is needed (failed CREATE or DEPOSIT)
            let needsRefund = !success
                && refundAmount > 0
                && (requestType == FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue
                    || requestType == FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue)

            var refundValue = EVM.Balance(attoflow: 0)
            let coaRef = self.getCOARef()

            if needsRefund {
                let isNativeFlow = tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString()

                if isNativeFlow {
                    // Native FLOW: send with the call
                    // Convert UInt256 to UFix64 then to EVM.Balance
                    let refundUFix64 = FlowYieldVaultsEVM.ufix64FromUInt256(refundAmount, tokenAddress: tokenAddress)
                    refundValue = FlowYieldVaultsEVM.balanceFromUFix64(refundUFix64, tokenAddress: tokenAddress)
                } else {
                    // ERC20: approve contract to pull funds
                    let approveCalldata = EVM.encodeABIWithSignature(
                        "approve(address,uint256)",
                        [FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!, refundAmount]
                    )
                    let approveResult = coaRef.call(
                        to: tokenAddress,
                        data: approveCalldata,
                        gasLimit: 100_000,
                        value: EVM.Balance(attoflow: 0)
                    )
                    if approveResult.status != EVM.Status.successful {
                        let errorMsg = FlowYieldVaultsEVM.decodeEVMError(approveResult.data)
                        emit RequestFailed(
                            requestId: requestId,
                            userAddress: "",
                            requestType: requestType,
                            tokenAddress: tokenAddress.toString(),
                            amount: refundAmount,
                            yieldVaultId: yieldVaultId,
                            reason: "ERC20 approve for refund failed: \(errorMsg)"
                        )
                        return false
                    }
                }
            }

            let result = coaRef.call(
                to: FlowYieldVaultsEVM.flowYieldVaultsRequestsAddress!,
                data: calldata,
                gasLimit: 15_000_000,
                value: refundValue
            )

            if result.status != EVM.Status.successful {
                let errorMsg = FlowYieldVaultsEVM.decodeEVMError(result.data)
                emit RequestFailed(
                    requestId: requestId,
                    userAddress: "",
                    requestType: requestType,
                    tokenAddress: tokenAddress.toString(),
                    amount: refundAmount,
                    yieldVaultId: yieldVaultId,
                    reason: "completeProcessing failed: \(errorMsg)"
                )
                return false
            }

            return true
        }

        /// @notice Withdraws funds from the COA, handling both native FLOW and ERC20 tokens
        /// @dev For native FLOW: Uses COA.withdraw() to get FlowToken.Vault directly
        ///      For ERC20: Uses FlowEVMBridge to bridge tokens to Cadence vault
        /// @param amount The amount to withdraw in UFix64 format
        /// @param tokenAddress The token address (NATIVE_FLOW sentinel or ERC20 address)
        /// @return Optional vault containing the withdrawn funds, or nil if withdrawal failed
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

        /// @notice Bridges funds from a Cadence vault to an EVM user address
        /// @dev For native FLOW: Deposits to COA, then withdraws and deposits to recipient
        ///      For ERC20: Uses FlowEVMBridge to bridge, then transfers via ERC20.transfer()
        /// @param vault The Cadence vault containing funds to send (will be consumed)
        /// @param recipient The EVM address to receive the funds
        /// @param tokenAddress The token address (NATIVE_FLOW sentinel or ERC20 address)
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

        /// @notice Bridges ERC20 tokens from EVM to Cadence using FlowEVMBridge
        /// @dev Looks up the Cadence vault type associated with the ERC20 address,
        ///      then uses COA.withdrawTokens() to bridge the tokens.
        /// @param tokenAddress The ERC20 token address on EVM
        /// @param amount The amount to bridge in wei/smallest unit (UInt256)
        /// @return Cadence vault containing the bridged tokens
        access(self) fun bridgeERC20FromEVM(
            tokenAddress: EVM.EVMAddress,
            amount: UInt256
        ): @{FungibleToken.Vault} {
            let vaultType = FlowEVMBridgeConfig.getTypeAssociated(with: tokenAddress)
                ?? panic("ERC20 token at \(tokenAddress.toString()) is not onboarded to the FlowEVMBridge - amount: \(amount)")

            let coaRef = self.getCOARef()
            let feeProvider = self.feeProviderCap.borrow()
                ?? panic("Could not borrow fee provider capability (id: \(self.feeProviderCap.id))")

            let vault <- coaRef.withdrawTokens(
                type: vaultType,
                amount: amount,
                feeProvider: feeProvider
            )

            return <-vault
        }

        /// @notice Bridges a Cadence vault to ERC20 tokens on EVM and transfers to recipient
        /// @dev Uses COA.depositTokens() to bridge tokens to EVM, then calls ERC20.transfer()
        ///      to send the tokens to the recipient address.
        /// @param vault The Cadence vault containing tokens to bridge (will be consumed)
        /// @param recipient The EVM address to receive the tokens
        /// @param tokenAddress The ERC20 token address on EVM
        access(self) fun bridgeERC20ToEVM(
            vault: @{FungibleToken.Vault},
            recipient: EVM.EVMAddress,
            tokenAddress: EVM.EVMAddress
        ) {
            let amountUInt256 = FlowYieldVaultsEVM.uint256FromUFix64(vault.balance, tokenAddress: tokenAddress)

            let coaRef = self.getCOARef()
            let feeProvider = self.feeProviderCap.borrow()
                ?? panic("Could not borrow fee provider capability (id: \(self.feeProviderCap.id))")

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

    /// @notice Gets the maximum requests processed per transaction
    /// @return The current maxRequestsPerTx value
    access(all) view fun getMaxRequestsPerTx(): Int {
        return self.maxRequestsPerTx
    }

    /// @notice Gets pending requests for a specific EVM address (public query)
    /// @dev Uses the contract account's public COA capability at /public/evm for read-only EVM calls.
    /// @param evmAddressHex The EVM address as a hex string (e.g., "0x1234...")
    /// @return PendingRequestsInfo containing count, balances, and request details
    access(all) fun getPendingRequestsForEVMAddress(_ evmAddressHex: String): PendingRequestsInfo {
        pre {
            self.flowYieldVaultsRequestsAddress != nil:
                "FlowYieldVaultsRequests address not set - call Admin.setFlowYieldVaultsRequestsAddress() first"
        }
        let coaRef = self.account.capabilities.borrow<&EVM.CadenceOwnedAccount>(/public/evm)
            ?? panic("Could not borrow public COA capability from /public/evm for contract account \(self.account.address)")
        let evmAddress = EVM.addressFromString(evmAddressHex)

        let calldata = EVM.encodeABIWithSignature(
            "getPendingRequestsByUserUnpacked(address)",
            [evmAddress]
        )

        let callResult = coaRef.dryCall(
            to: self.flowYieldVaultsRequestsAddress!,
            data: calldata,
            gasLimit: 15_000_000,
            value: EVM.Balance(attoflow: 0)
        )

        if callResult.status != EVM.Status.successful {
            let errorMsg = self.decodeEVMError(callResult.data)
            panic("getPendingRequestsByUserUnpacked call failed for user \(evmAddressHex): \(errorMsg)")
        }

        let decoded = EVM.decodeABI(
            types: [
                Type<[UInt256]>(),        // ids
                Type<[UInt8]>(),          // requestTypes
                Type<[UInt8]>(),          // statuses
                Type<[EVM.EVMAddress]>(), // tokenAddresses
                Type<[UInt256]>(),        // amounts
                Type<[UInt64]>(),         // yieldVaultIds
                Type<[UInt256]>(),        // timestamps
                Type<[String]>(),         // messages
                Type<[String]>(),         // vaultIdentifiers
                Type<[String]>(),         // strategyIdentifiers
                Type<UInt256>(),          // pendingBalance
                Type<UInt256>()           // claimableRefund
            ],
            data: callResult.data
        )

        let ids = decoded[0] as! [UInt256]
        let requestTypes = decoded[1] as! [UInt8]
        let statuses = decoded[2] as! [UInt8]
        let tokenAddresses = decoded[3] as! [EVM.EVMAddress]
        let amounts = decoded[4] as! [UInt256]
        let yieldVaultIds = decoded[5] as! [UInt64]
        let timestamps = decoded[6] as! [UInt256]
        let messages = decoded[7] as! [String]
        let vaultIdentifiers = decoded[8] as! [String]
        let strategyIdentifiers = decoded[9] as! [String]
        let pendingBalanceRaw = decoded[10] as! UInt256
        let claimableRefundRaw = decoded[11] as! UInt256

        // Convert pending balance from wei to UFix64
        let pendingBalance = FlowEVMBridgeUtils.uint256ToUFix64(value: pendingBalanceRaw, decimals: 18)
        let claimableRefund = FlowEVMBridgeUtils.uint256ToUFix64(value: claimableRefundRaw, decimals: 18)

        // Build request array
        var requests: [EVMRequest] = []
        var i = 0
        while i < ids.length {
            let request = EVMRequest(
                id: ids[i],
                user: evmAddress,
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

        return PendingRequestsInfo(
            evmAddress: evmAddressHex,
            pendingCount: ids.length,
            pendingBalance: pendingBalance,
            claimableRefund: claimableRefund,
            requests: requests
        )
    }

    /// @notice Gets the total count of pending requests (public query)
    /// @dev Uses the contract account's public COA capability at /public/evm for read-only EVM calls.
    /// @return The number of pending requests
    access(all) fun getPendingRequestCount(): Int {
        pre {
            self.flowYieldVaultsRequestsAddress != nil:
                "FlowYieldVaultsRequests address not set - call Admin.setFlowYieldVaultsRequestsAddress() first"
        }
        let coaRef = self.account.capabilities.borrow<&EVM.CadenceOwnedAccount>(/public/evm)
            ?? panic("Could not borrow public COA capability from /public/evm for contract account \(self.account.address)")

        let calldata = EVM.encodeABIWithSignature("getPendingRequestCount()", [])

        let callResult = coaRef.dryCall(
            to: self.flowYieldVaultsRequestsAddress!,
            data: calldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        if callResult.status != EVM.Status.successful {
            let errorMsg = self.decodeEVMError(callResult.data)
            panic("getPendingRequestCount call failed on contract \(self.flowYieldVaultsRequestsAddress!.toString()): \(errorMsg)")
        }

        let decoded = EVM.decodeABI(
            types: [Type<UInt256>()],
            data: callResult.data
        )

        let count256 = decoded[0] as! UInt256
        return Int(count256)
    }

    // ============================================
    // Internal Functions
    // ============================================

    /// @notice Converts a UInt256 amount from EVM to UFix64 for Cadence
    /// @dev For native FLOW: Uses 18 decimals (attoflow to FLOW conversion)
    ///      For ERC20: Uses FlowEVMBridgeUtils to look up token decimals
    /// @param value The amount in wei/smallest unit (UInt256)
    /// @param tokenAddress The token address to determine decimal conversion
    /// @return The converted amount in UFix64 format
    access(self) fun ufix64FromUInt256(_ value: UInt256, tokenAddress: EVM.EVMAddress): UFix64 {
        if tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString() {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: value, decimals: 18)
        }
        return FlowEVMBridgeUtils.convertERC20AmountToCadenceAmount(value, erc20Address: tokenAddress)
    }

    /// @notice Converts a UFix64 amount from Cadence to UInt256 for EVM
    /// @dev For native FLOW: Uses 18 decimals (FLOW to attoflow conversion)
    ///      For ERC20: Uses FlowEVMBridgeUtils to look up token decimals
    /// @param value The amount in UFix64 format
    /// @param tokenAddress The token address to determine decimal conversion
    /// @return The converted amount in wei/smallest unit (UInt256)
    access(self) fun uint256FromUFix64(_ value: UFix64, tokenAddress: EVM.EVMAddress): UInt256 {
        if tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString() {
            return FlowEVMBridgeUtils.ufix64ToUInt256(value: value, decimals: 18)
        }
        return FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(value, erc20Address: tokenAddress)
    }

    /// @notice Creates an EVM.Balance from a UFix64 amount (native FLOW only)
    /// @dev Only valid for native FLOW token. Asserts if called with ERC20 address.
    ///      Uses EVM.Balance.setFLOW() for proper attoflow conversion.
    /// @param value The amount in UFix64 format
    /// @param tokenAddress Must be the NATIVE_FLOW sentinel address
    /// @return EVM.Balance representing the amount in attoflow
    access(self) fun balanceFromUFix64(_ value: UFix64, tokenAddress: EVM.EVMAddress): EVM.Balance {
        assert(
            tokenAddress.toString() == FlowYieldVaultsEVM.nativeFlowEVMAddress.toString(),
            message: "balanceFromUFix64 requires native FLOW address (\(FlowYieldVaultsEVM.nativeFlowEVMAddress.toString())) but got \(tokenAddress.toString()) for value \(value)"
        )

        let bal = EVM.Balance(attoflow: 0)
        bal.setFLOW(flow: value)
        return bal
    }

    /// @notice Decodes an EVM revert error message from raw bytes
    /// @dev Attempts to decode standard Solidity Error(string) format (selector 0x08c379a0).
    ///      Falls back to hex-encoded raw data if decoding fails.
    /// @param data The raw bytes from EVM call result.data
    /// @return Human-readable error message or hex-encoded revert data
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
