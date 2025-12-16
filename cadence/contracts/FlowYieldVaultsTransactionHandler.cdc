import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowYieldVaultsEVM"
import "FlowToken"
import "FungibleToken"

/// @title FlowYieldVaultsTransactionHandler
/// @author Flow YieldVaults Team
/// @notice Handler contract for scheduled FlowYieldVaultsEVM request processing with auto-scheduling.
/// @dev This contract manages the automated execution of EVM request processing through the
///      FlowTransactionScheduler. After each execution, it automatically schedules the next
///      execution based on the current workload.
///
///      Key features:
///      - Dynamic delay adjustment based on pending request count
///      - Cost-optimized idle polling (low effort when no pending requests)
///      - Pausable execution for maintenance
///
///      Delay thresholds:
///      - > 10 pending: 3s delay (high load)
///      - >= 5 pending: 5s delay (medium load)
///      - >= 1 pending: 7s delay (low load)
///      - 0 pending: 30s delay (idle)
access(all) contract FlowYieldVaultsTransactionHandler {

    // ============================================
    // State Variables
    // ============================================

    /// @notice Storage path for Handler resource
    access(all) let HandlerStoragePath: StoragePath

    /// @notice Public path for Handler capability
    access(all) let HandlerPublicPath: PublicPath

    /// @notice Storage path for Admin resource
    access(all) let AdminStoragePath: StoragePath

    /// @notice Mapping of pending request thresholds to execution delays (in seconds)
    /// @dev Higher pending counts result in shorter delays for faster processing
    access(contract) var thresholdToDelay: {Int: UFix64}

    /// @notice Default delay when no threshold matches
    access(all) let defaultDelay: UFix64

    /// @notice When true, scheduled executions skip processing and don't schedule next execution
    access(contract) var isPaused: Bool

    /// @notice Base execution effort per request processed
    /// @dev Total executionEffort = baseEffortPerRequest * maxRequestsPerTx + baseOverhead
    access(contract) var baseEffortPerRequest: UInt64

    /// @notice Base overhead for transaction execution (independent of request count)
    access(contract) var baseOverhead: UInt64

    /// @notice Minimal execution effort used when idle (no pending requests)
    /// @dev Keeps costs low for polling transactions that won't process anything
    access(contract) var idleExecutionEffort: UInt64

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when the handler is paused
    access(all) event HandlerPaused()

    /// @notice Emitted when the handler is unpaused
    access(all) event HandlerUnpaused()

    /// @notice Emitted when thresholdToDelay mapping is updated
    /// @param newThresholds The new threshold to delay mapping
    access(all) event ThresholdToDelayUpdated(newThresholds: {Int: UFix64})

    /// @notice Emitted when execution effort parameters are updated
    /// @param baseEffortPerRequest New base effort per request
    /// @param baseOverhead New base overhead
    /// @param idleExecutionEffort New idle execution effort
    access(all) event ExecutionEffortParamsUpdated(baseEffortPerRequest: UInt64, baseOverhead: UInt64, idleExecutionEffort: UInt64)

    /// @notice Emitted when a scheduled execution is triggered
    /// @param transactionId The transaction ID that was executed
    /// @param pendingRequests Number of pending requests after processing
    /// @param nextExecutionDelaySeconds Delay until next execution
    access(all) event ScheduledExecutionTriggered(
        transactionId: UInt64,
        pendingRequests: Int,
        nextExecutionDelaySeconds: UFix64
    )

    /// @notice Emitted when next execution is scheduled (single transaction)
    /// @param transactionId The scheduled transaction ID
    /// @param scheduledFor Timestamp when execution is scheduled
    /// @param delaySeconds Delay from current time
    /// @param pendingRequests Current pending request count
    access(all) event NextExecutionScheduled(
        transactionId: UInt64,
        scheduledFor: UFix64,
        delaySeconds: UFix64,
        pendingRequests: Int
    )

    /// @notice Emitted when execution is skipped
    /// @param transactionId The transaction ID that was skipped
    /// @param reason Why the execution was skipped
    access(all) event ExecutionSkipped(
        transactionId: UInt64,
        reason: String
    )

    /// @notice Emitted when all scheduled executions are stopped and cancelled
    /// @param cancelledIds Array of cancelled transaction IDs
    /// @param totalRefunded Total amount of FLOW refunded
    access(all) event AllExecutionsStopped(
        cancelledIds: [UInt64],
        totalRefunded: UFix64
    )

    // ============================================
    // Resources
    // ============================================

    /// @notice Admin resource for handler configuration
    /// @dev Only the contract deployer receives this resource
    access(all) resource Admin {

        /// @notice Pauses the handler, stopping all scheduled executions
        access(all) fun pause() {
            FlowYieldVaultsTransactionHandler.isPaused = true
            emit HandlerPaused()
        }

        /// @notice Unpauses the handler, resuming scheduled executions
        access(all) fun unpause() {
            FlowYieldVaultsTransactionHandler.isPaused = false
            emit HandlerUnpaused()
        }

        /// @notice Updates the threshold to delay mapping
        /// @param newThresholds The new mapping of pending request thresholds to delays
        access(all) fun setThresholdToDelay(newThresholds: {Int: UFix64}) {
            pre {
                newThresholds.length > 0: "Thresholds mapping cannot be empty"
            }
            FlowYieldVaultsTransactionHandler.thresholdToDelay = newThresholds
            emit ThresholdToDelayUpdated(newThresholds: newThresholds)
        }

        /// @notice Updates execution effort calculation parameters
        /// @dev executionEffort = baseEffortPerRequest * maxRequestsPerTx + baseOverhead
        /// @param baseEffortPerRequest Effort units per request (e.g., 800 for EVM calls)
        /// @param baseOverhead Fixed overhead regardless of request count (e.g., 1500)
        /// @param idleExecutionEffort Minimal effort when no pending requests (e.g., 3000 to handle burst arrivals)
        access(all) fun setExecutionEffortParams(baseEffortPerRequest: UInt64, baseOverhead: UInt64, idleExecutionEffort: UInt64) {
            pre {
                baseEffortPerRequest > 0: "baseEffortPerRequest must be greater than 0"
                idleExecutionEffort > 0: "idleExecutionEffort must be greater than 0"
            }
            FlowYieldVaultsTransactionHandler.baseEffortPerRequest = baseEffortPerRequest
            FlowYieldVaultsTransactionHandler.baseOverhead = baseOverhead
            FlowYieldVaultsTransactionHandler.idleExecutionEffort = idleExecutionEffort
            emit ExecutionEffortParamsUpdated(baseEffortPerRequest: baseEffortPerRequest, baseOverhead: baseOverhead, idleExecutionEffort: idleExecutionEffort)
        }

        /// @notice Stops all scheduled executions by pausing and cancelling all pending transactions
        /// @dev This will pause the handler and cancel all scheduled transactions, refunding fees
        /// @return Dictionary with cancelledIds array and totalRefunded amount
        access(all) fun stopAll(): {String: AnyStruct} {
            // First pause to prevent any new scheduling
            FlowYieldVaultsTransactionHandler.isPaused = true
            emit HandlerPaused()

            // Borrow the manager to cancel scheduled transactions
            let manager = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                    from: FlowTransactionSchedulerUtils.managerStoragePath
                )

            let cancelledIds: [UInt64] = []

            if manager == nil {
                emit AllExecutionsStopped(cancelledIds: [], totalRefunded: 0.0)
                return {
                    "cancelledIds": cancelledIds,
                    "totalRefunded": 0.0
                }
            }

            // Get all pending transaction IDs
            let transactionIds = manager!.getTransactionIDs()
            var totalRefunded: UFix64 = 0.0

            // Get vault to deposit refunds
            let vaultRef = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
                ?? panic("Could not borrow FlowToken vault")

            // Cancel each scheduled transaction
            for id in transactionIds {
                let refund <- manager!.cancel(id: id)
                totalRefunded = totalRefunded + refund.balance
                vaultRef.deposit(from: <-refund)
                cancelledIds.append(id)
            }

            emit AllExecutionsStopped(cancelledIds: cancelledIds, totalRefunded: totalRefunded)

            return {
                "cancelledIds": cancelledIds,
                "totalRefunded": totalRefunded
            }
        }
    }

    /// @notice Handler resource that implements FlowTransactionScheduler.TransactionHandler
    /// @dev Processes EVM requests and auto-schedules next execution based on workload
    access(all) resource Handler: FlowTransactionScheduler.TransactionHandler {

        access(self) let workerCap: Capability<&FlowYieldVaultsEVM.Worker>
        access(self) var executionCount: UInt64
        access(self) var lastExecutionTime: UFix64?

        init(workerCap: Capability<&FlowYieldVaultsEVM.Worker>) {
            self.workerCap = workerCap
            self.executionCount = 0
            self.lastExecutionTime = nil
        }

        /// @notice Executes the scheduled transaction
        /// @dev Called by FlowTransactionScheduler when the scheduled time arrives.
        ///      Processes requests and schedules the next execution.
        ///      Priority and execution effort are calculated dynamically based on maxRequestsPerTx.
        /// @param id The transaction ID being executed
        /// @param data Unused - priority and effort calculated dynamically from contract state
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            if FlowYieldVaultsTransactionHandler.isPaused {
                emit ExecutionSkipped(transactionId: id, reason: "Handler is paused")
                return
            }

            let worker = self.workerCap.borrow()
            if worker == nil {
                emit ExecutionSkipped(transactionId: id, reason: "Could not borrow Worker capability")
                return
            }

            // Process requests
            let maxRequestsPerTx = FlowYieldVaultsEVM.getMaxRequestsPerTx()
            worker!.processRequests(startIndex: 0, count: maxRequestsPerTx)
            
            // Calculate dynamic execution effort and determine priority based on effort
            let effortAndPriority = FlowYieldVaultsTransactionHandler.calculateExecutionEffortAndPriority(maxRequestsPerTx)
            let executionEffort = effortAndPriority["effort"]! as! UInt64
            let priorityRaw = effortAndPriority["priority"]! as! UInt8
            
            let priority = priorityRaw == 0
                ? FlowTransactionScheduler.Priority.High
                : FlowTransactionScheduler.Priority.Medium

            self.executionCount = self.executionCount + 1
            self.lastExecutionTime = getCurrentBlock().timestamp

            // Get pending count and schedule next execution
            let pendingRequests = self.getPendingRequestCount(worker!)
            let nextDelay = FlowYieldVaultsTransactionHandler.getDelayForPendingCount(pendingRequests)

            emit ScheduledExecutionTriggered(
                transactionId: id,
                pendingRequests: pendingRequests,
                nextExecutionDelaySeconds: nextDelay
            )

            // Use Low priority when idle (no pending requests) to minimize FLOW costs
            // Use computed effort but cap at idleExecutionEffort (max for Low priority = 2500)
            if pendingRequests == 0 {
                let cappedEffort = executionEffort < FlowYieldVaultsTransactionHandler.idleExecutionEffort 
                    ? executionEffort 
                    : FlowYieldVaultsTransactionHandler.idleExecutionEffort
                self.scheduleNextExecution(
                    nextDelay: nextDelay,
                    priority: FlowTransactionScheduler.Priority.Low,
                    executionEffort: cappedEffort
                )
            } else {
                self.scheduleNextExecution(nextDelay: nextDelay, priority: priority, executionEffort: executionEffort)
            }
        }

        access(self) fun scheduleNextExecution(nextDelay: UFix64, priority: FlowTransactionScheduler.Priority, executionEffort: UInt64) {
            let future = getCurrentBlock().timestamp + nextDelay

            let manager = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                    from: FlowTransactionSchedulerUtils.managerStoragePath
                )
                ?? panic("Could not borrow Manager reference from contract account")

            let handlerTypeIdentifiers = manager.getHandlerTypeIdentifiers()
            assert(handlerTypeIdentifiers.keys.length > 0, message: "No handler types found in manager")
            let handlerTypeIdentifier = handlerTypeIdentifiers.keys[0]

            let vaultRef = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
                ?? panic("missing FlowToken vault on contract account")

            let estimate = FlowTransactionScheduler.estimate(
                data: [],
                timestamp: future,
                priority: priority,
                executionEffort: executionEffort
            )
            let fees <- vaultRef.withdraw(amount: estimate.flowFee ?? 0.0) as! @FlowToken.Vault
            let transactionId = manager.scheduleByHandler(
                handlerTypeIdentifier: handlerTypeIdentifier,
                handlerUUID: self.uuid,
                data: [],
                timestamp: future,
                priority: priority,
                executionEffort: executionEffort,
                fees: <-fees
            )

            emit NextExecutionScheduled(
                transactionId: transactionId,
                scheduledFor: future,
                delaySeconds: nextDelay,
                pendingRequests: 0
            )
        }

        /// @notice Returns the view types supported by this handler
        /// @return Array of supported view types
        access(all) view fun getViews(): [Type] {
            return [Type<StoragePath>(), Type<PublicPath>()]
        }

        /// @notice Resolves a view for this handler
        /// @param view The view type to resolve
        /// @return The resolved view value or nil
        access(all) fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<StoragePath>():
                    return FlowYieldVaultsTransactionHandler.HandlerStoragePath
                case Type<PublicPath>():
                    return FlowYieldVaultsTransactionHandler.HandlerPublicPath
                default:
                    return nil
            }
        }

        access(self) fun getPendingRequestCount(_ worker: &FlowYieldVaultsEVM.Worker): Int {
            return worker.getPendingRequestCountFromEVM()
        }

        /// @notice Returns handler execution statistics
        /// @return Dictionary with executionCount and lastExecutionTime
        access(all) fun getStats(): {String: AnyStruct} {
            return {
                "executionCount": self.executionCount,
                "lastExecutionTime": self.lastExecutionTime
            }
        }
    }

    // ============================================
    // Public Functions
    // ============================================

    /// @notice Creates a new Handler resource
    /// @param workerCap Capability to the FlowYieldVaultsEVM.Worker
    /// @return The newly created Handler resource
    access(all) fun createHandler(workerCap: Capability<&FlowYieldVaultsEVM.Worker>): @Handler {
        return <- create Handler(workerCap: workerCap)
    }

    /// @notice Returns the current paused state
    /// @return True if paused, false otherwise
    access(all) view fun getIsPaused(): Bool {
        return self.isPaused
    }

    /// @notice Returns the current threshold to delay mapping
    /// @return Dictionary mapping pending request thresholds to delays in seconds
    access(all) view fun getThresholdToDelay(): {Int: UFix64} {
        return self.thresholdToDelay
    }

    /// @notice Returns the current execution effort parameters
    /// @return Dictionary with baseEffortPerRequest, baseOverhead, and idleExecutionEffort
    access(all) view fun getExecutionEffortParams(): {String: UInt64} {
        return {
            "baseEffortPerRequest": self.baseEffortPerRequest,
            "baseOverhead": self.baseOverhead,
            "idleExecutionEffort": self.idleExecutionEffort
        }
    }

    /// @notice Calculates the appropriate delay based on pending request count
    /// @dev Finds the highest threshold that pendingCount meets or exceeds
    /// @param pendingCount The current number of pending requests
    /// @return The delay in seconds for the next execution
    access(all) fun getDelayForPendingCount(_ pendingCount: Int): UFix64 {
        var bestThreshold: Int? = nil

        for threshold in self.thresholdToDelay.keys {
            if pendingCount >= threshold {
                if bestThreshold == nil || threshold > bestThreshold! {
                    bestThreshold = threshold
                }
            }
        }

        if let threshold = bestThreshold {
            return self.thresholdToDelay[threshold] ?? self.defaultDelay
        }

        return self.defaultDelay
    }

    /// @notice Calculates execution effort and determines appropriate priority
    /// @dev Formula: baseEffortPerRequest * requestCount + baseOverhead
    ///      If calculated > 7500, uses High priority (max 9999)
    ///      Otherwise uses Medium priority (max 7500)
    /// @param requestCount The number of requests to process (typically maxRequestsPerTx)
    /// @return Dictionary with "effort" (UInt64) and "priority" (UInt8: 0=High, 1=Medium)
    access(all) fun calculateExecutionEffortAndPriority(_ requestCount: Int): {String: AnyStruct} {
        let calculated = self.baseEffortPerRequest * UInt64(requestCount) + self.baseOverhead
        
        // If calculated > 7500, need High priority (max 9999)
        // Otherwise use Medium priority (max 7500)
        if calculated > 7500 {
            let capped = calculated < 9999 ? calculated : 9999
            return {
                "effort": capped,
                "priority": 0 as UInt8
            }
        } else {
            return {
                "effort": calculated,
                "priority": 1 as UInt8
            }
        }
    }

    // ============================================
    // Initialization
    // ============================================

    init() {
        self.HandlerStoragePath = /storage/FlowYieldVaultsTransactionHandler
        self.HandlerPublicPath = /public/FlowYieldVaultsTransactionHandler
        self.AdminStoragePath = /storage/FlowYieldVaultsTransactionHandlerAdmin
        self.isPaused = false
        self.defaultDelay = 30.0
        self.thresholdToDelay = {
            11: 3.0,
            5: 5.0,
            1: 7.0,
            0: 30.0
        }
        
        // Execution effort calculation parameters
        // Formula: baseEffortPerRequest * maxRequestsPerTx + baseOverhead
        // Default: 800 * 1 + 1500 = 2300 for 1 request
        //          800 * 3 + 1500 = 3900 for 3 requests
        //          800 * 5 + 1500 = 5500 for 5 requests
        self.baseEffortPerRequest = 800
        self.baseOverhead = 1500
        
        // Minimal execution effort for idle polling (no pending requests)
        // Set to 2500 (max for Low priority) to handle burst arrivals after idle scheduling
        // Uses Low priority to minimize FLOW costs when just checking status
        self.idleExecutionEffort = 2500

        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
