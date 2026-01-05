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
///      - >= 11 pending: 3s delay (high load)
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
    /// @param oldThresholds The previous threshold to delay mapping
    /// @param newThresholds The new threshold to delay mapping
    access(all) event ThresholdToDelayUpdated(oldThresholds: {Int: UFix64}, newThresholds: {Int: UFix64})

    /// @notice Emitted when execution effort parameters are updated
    /// @param oldBaseEffortPerRequest Previous base effort per request
    /// @param oldBaseOverhead Previous base overhead
    /// @param oldIdleExecutionEffort Previous idle execution effort
    /// @param newBaseEffortPerRequest New base effort per request
    /// @param newBaseOverhead New base overhead
    /// @param newIdleExecutionEffort New idle execution effort
    access(all) event ExecutionEffortParamsUpdated(
        oldBaseEffortPerRequest: UInt64,
        oldBaseOverhead: UInt64,
        oldIdleExecutionEffort: UInt64,
        newBaseEffortPerRequest: UInt64,
        newBaseOverhead: UInt64,
        newIdleExecutionEffort: UInt64
    )

    /// @notice Emitted when a scheduled execution is triggered
    /// @param transactionId The transaction ID that was executed
    /// @param maxRequestsPerTx The maximum number of requests that could be processed
    /// @param executionEffort The execution effort used for this transaction
    /// @param pendingRequests Number of pending requests after processing
    /// @param nextExecutionDelaySeconds Delay until next execution
    access(all) event ScheduledExecutionTriggered(
        transactionId: UInt64,
        maxRequestsPerTx: Int,
        executionEffort: UInt64,
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
                newThresholds.length > 0: "Thresholds mapping cannot be empty (got length: \(newThresholds.length))"
            }
            let oldThresholds = FlowYieldVaultsTransactionHandler.thresholdToDelay
            FlowYieldVaultsTransactionHandler.thresholdToDelay = newThresholds
            emit ThresholdToDelayUpdated(oldThresholds: oldThresholds, newThresholds: newThresholds)
        }

        /// @notice Updates execution effort calculation parameters
        /// @dev executionEffort = baseEffortPerRequest * maxRequestsPerTx + baseOverhead
        /// @param baseEffortPerRequest Effort units per request (e.g., 2000 for EVM calls)
        /// @param baseOverhead Fixed overhead regardless of request count (e.g., 3000)
        /// @param idleExecutionEffort Minimal effort when no pending requests (e.g., 3000 to handle burst arrivals)
        access(all) fun setExecutionEffortParams(baseEffortPerRequest: UInt64, baseOverhead: UInt64, idleExecutionEffort: UInt64) {
            pre {
                baseEffortPerRequest > 0: "baseEffortPerRequest must be greater than 0 but got \(baseEffortPerRequest)"
                idleExecutionEffort > 0: "idleExecutionEffort must be greater than 0 but got \(idleExecutionEffort)"
            }
            let oldBaseEffortPerRequest = FlowYieldVaultsTransactionHandler.baseEffortPerRequest
            let oldBaseOverhead = FlowYieldVaultsTransactionHandler.baseOverhead
            let oldIdleExecutionEffort = FlowYieldVaultsTransactionHandler.idleExecutionEffort

            FlowYieldVaultsTransactionHandler.baseEffortPerRequest = baseEffortPerRequest
            FlowYieldVaultsTransactionHandler.baseOverhead = baseOverhead
            FlowYieldVaultsTransactionHandler.idleExecutionEffort = idleExecutionEffort

            emit ExecutionEffortParamsUpdated(
                oldBaseEffortPerRequest: oldBaseEffortPerRequest,
                oldBaseOverhead: oldBaseOverhead,
                oldIdleExecutionEffort: oldIdleExecutionEffort,
                newBaseEffortPerRequest: baseEffortPerRequest,
                newBaseOverhead: baseOverhead,
                newIdleExecutionEffort: idleExecutionEffort
            )
        }

        /// @notice Stops all scheduled executions by pausing and cancelling all pending transactions
        /// @dev This will pause the handler and cancel all scheduled transactions, refunding fees.
        ///      Flow:
        ///      1. Pauses the handler to prevent new scheduling
        ///      2. Borrows the scheduler Manager
        ///      3. Cancels each pending transaction and collects refunds
        ///      4. Returns summary of cancelled IDs and total refunded
        /// @return Dictionary with cancelledIds array and totalRefunded amount
        access(all) fun stopAll(): {String: AnyStruct} {
            // Step 1: Pause to prevent any new scheduling during cancellation
            FlowYieldVaultsTransactionHandler.isPaused = true
            emit HandlerPaused()

            // Step 2: Borrow the scheduler Manager from storage
            let manager = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                    from: FlowTransactionSchedulerUtils.managerStoragePath
                )

            let cancelledIds: [UInt64] = []

            // Handle case where Manager doesn't exist yet
            if manager == nil {
                emit AllExecutionsStopped(cancelledIds: [], totalRefunded: 0.0)
                return {
                    "cancelledIds": cancelledIds,
                    "totalRefunded": 0.0
                }
            }

            // Step 3: Get all pending transaction IDs and prepare for refunds
            let transactionIds = manager!.getTransactionIDs()
            var totalRefunded: UFix64 = 0.0

            // Borrow vault to deposit refunded fees
            let vaultRef = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
                ?? panic("Could not borrow FlowToken vault from /storage/flowTokenVault for contract account")

            // Step 4: Cancel each scheduled transaction and collect refunds
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

        /// @notice Capability to the Worker resource for processing requests
        access(self) let workerCap: Capability<&FlowYieldVaultsEVM.Worker>

        /// @notice Counter tracking the total number of executions performed
        access(self) var executionCount: UInt64

        /// @notice Timestamp of the last execution, nil if never executed
        access(self) var lastExecutionTime: UFix64?

        /// @notice Initializes the Handler with a Worker capability
        /// @dev Validates that the Worker capability is valid on initialization.
        ///      Initializes execution tracking counters.
        /// @param workerCap Capability to the FlowYieldVaultsEVM.Worker resource
        init(workerCap: Capability<&FlowYieldVaultsEVM.Worker>) {
            pre {
                workerCap.check(): "Worker capability is invalid (id: \(workerCap.id))"
            }
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
            // Step 1: Check if handler is paused
            if FlowYieldVaultsTransactionHandler.isPaused {
                emit ExecutionSkipped(transactionId: id, reason: "Handler is paused")
                return
            }

            // Step 2: Borrow the Worker capability
            let worker = self.workerCap.borrow()
            if worker == nil {
                emit ExecutionSkipped(transactionId: id, reason: "Could not borrow Worker capability (id: \(self.workerCap.id))")
                return
            }

            // Step 3: Process pending requests using the Worker
            let maxRequestsPerTx = FlowYieldVaultsEVM.getMaxRequestsPerTx()
            worker!.processRequests(startIndex: 0, count: maxRequestsPerTx)

            // Step 4: Calculate dynamic execution effort and priority for next execution
            // Higher request counts require more effort; effort > 7500 triggers High priority
            let effortAndPriority = FlowYieldVaultsTransactionHandler.calculateExecutionEffortAndPriority(maxRequestsPerTx)
            let executionEffort = effortAndPriority["effort"]! as! UInt64
            let priorityRaw = effortAndPriority["priority"]! as! UInt8

            let priority = priorityRaw == 0
                ? FlowTransactionScheduler.Priority.High
                : FlowTransactionScheduler.Priority.Medium

            // Step 5: Update execution statistics
            self.executionCount = self.executionCount + 1
            self.lastExecutionTime = getCurrentBlock().timestamp

            // Step 6: Determine next execution delay based on remaining pending requests
            let pendingRequests = self.getPendingRequestCount(worker!)
            let nextDelay = FlowYieldVaultsTransactionHandler.getDelayForPendingCount(pendingRequests)

            emit ScheduledExecutionTriggered(
                transactionId: id,
                maxRequestsPerTx: maxRequestsPerTx,
                executionEffort: executionEffort,
                pendingRequests: pendingRequests,
                nextExecutionDelaySeconds: nextDelay
            )

            // Step 7: Schedule next execution with appropriate priority and effort
            // When idle (no pending requests), use Medium priority with capped effort to reduce costs
            if pendingRequests == 0 {
                let cappedEffort = executionEffort < FlowYieldVaultsTransactionHandler.idleExecutionEffort
                    ? executionEffort
                    : FlowYieldVaultsTransactionHandler.idleExecutionEffort
                self.scheduleNextExecution(
                    nextDelay: nextDelay,
                    priority: FlowTransactionScheduler.Priority.Medium,
                    executionEffort: cappedEffort,
                    pendingRequests: pendingRequests
                )
            } else {
                self.scheduleNextExecution(nextDelay: nextDelay, priority: priority, executionEffort: executionEffort, pendingRequests: pendingRequests)
            }
        }

        /// @notice Schedules the next execution with the FlowTransactionScheduler
        /// @dev Calculates the future timestamp, estimates fees, withdraws from FlowToken vault,
        ///      and schedules via the Manager. Emits NextExecutionScheduled event on success.
        /// @param nextDelay The delay in seconds until the next execution
        /// @param priority The execution priority (High or Medium)
        /// @param executionEffort The execution effort units to allocate
        /// @param pendingRequests Current pending request count (for event emission)
        access(self) fun scheduleNextExecution(nextDelay: UFix64, priority: FlowTransactionScheduler.Priority, executionEffort: UInt64, pendingRequests: Int) {
            // Calculate the target execution timestamp
            let future = getCurrentBlock().timestamp + nextDelay

            // Borrow the scheduler Manager from storage
            let manager = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                    from: FlowTransactionSchedulerUtils.managerStoragePath
                )
                ?? panic("Could not borrow Manager reference from \(FlowTransactionSchedulerUtils.managerStoragePath) for contract account")

            // Get the handler type identifier (should be this Handler's type)
            let handlerTypeIdentifiers = manager.getHandlerTypeIdentifiers()
            assert(handlerTypeIdentifiers.keys.length > 0, message: "No handler types found in manager (registered handlers count: \(handlerTypeIdentifiers.keys.length))")
            let handlerTypeIdentifier = handlerTypeIdentifiers.keys[0]

            // Borrow FlowToken vault to pay scheduling fees
            let vaultRef = FlowYieldVaultsTransactionHandler.account.storage
                .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
                ?? panic("Could not borrow FlowToken vault from /storage/flowTokenVault for contract account")

            // Estimate fees and withdraw payment
            let estimate = FlowTransactionScheduler.estimate(
                data: [],
                timestamp: future,
                priority: priority,
                executionEffort: executionEffort
            )
            let fees <- vaultRef.withdraw(amount: estimate.flowFee ?? 0.0) as! @FlowToken.Vault

            // Schedule the next execution
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
                pendingRequests: pendingRequests
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
        access(all) view fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<StoragePath>():
                    return FlowYieldVaultsTransactionHandler.HandlerStoragePath
                case Type<PublicPath>():
                    return FlowYieldVaultsTransactionHandler.HandlerPublicPath
                default:
                    return nil
            }
        }

        /// @notice Gets the current count of pending requests from the EVM contract
        /// @dev Delegates to the Worker's getPendingRequestCountFromEVM method
        /// @param worker Reference to the Worker resource
        /// @return The number of pending requests
        access(self) fun getPendingRequestCount(_ worker: &FlowYieldVaultsEVM.Worker): Int {
            return worker.getPendingRequestCountFromEVM()
        }

        /// @notice Returns handler execution statistics
        /// @return Dictionary with executionCount and lastExecutionTime
        access(all) view fun getStats(): {String: AnyStruct} {
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
    /// @dev Finds the highest threshold that pendingCount meets or exceeds.
    ///      Example with default thresholds: {0: 30s, 1: 7s, 5: 5s, 11: 3s}
    ///      - pendingCount=15 matches thresholds 0, 1, 5, 11 -> uses 11 -> 3s delay
    ///      - pendingCount=7 matches thresholds 0, 1, 5 -> uses 5 -> 5s delay
    ///      - pendingCount=0 matches threshold 0 -> 30s delay (idle)
    /// @param pendingCount The current number of pending requests
    /// @return The delay in seconds for the next execution
    access(all) view fun getDelayForPendingCount(_ pendingCount: Int): UFix64 {
        // Find the highest threshold that pendingCount meets or exceeds
        var bestThreshold: Int? = nil

        for threshold in self.thresholdToDelay.keys {
            if pendingCount >= threshold {
                // Take the highest matching threshold for the shortest delay
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
    ///      Default values: 2000 * requestCount + 3000
    ///      Examples:
    ///      - 1 request: 2000*1 + 3000 = 5000 (Medium priority)
    ///      - 2 requests: 2000*2 + 3000 = 7000 (Medium priority)
    ///      - 3 requests: 2000*3 + 3000 = 9000 (High priority, capped)
    ///      If calculated > 7500, uses High priority (max 9999)
    ///      Otherwise uses Medium priority (max 7500)
    /// @param requestCount The number of requests to process (typically maxRequestsPerTx)
    /// @return Dictionary with "effort" (UInt64) and "priority" (UInt8: 0=High, 1=Medium)
    access(all) view fun calculateExecutionEffortAndPriority(_ requestCount: Int): {String: AnyStruct} {
        // Calculate effort using formula: baseEffortPerRequest * requestCount + baseOverhead
        let calculated = self.baseEffortPerRequest * UInt64(requestCount) + self.baseOverhead

        // Determine priority based on effort threshold
        // High priority allows up to 9999 effort, Medium allows up to 7500
        if calculated > 7500 {
            // Need High priority; cap effort at 9999
            let capped = calculated < 9999 ? calculated : 9999
            return {
                "effort": capped,
                "priority": 0 as UInt8  // 0 = High
            }
        } else {
            // Medium priority is sufficient
            return {
                "effort": calculated,
                "priority": 1 as UInt8  // 1 = Medium
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
        // Default: 2000 * 1 + 3000 = 2300 for 1 request
        //          2000 * 2 + 3000 = 7000 for 2 requests
        self.baseEffortPerRequest = 2000
        self.baseOverhead = 3000
        
        // Minimal execution effort for idle polling (no pending requests)
        // Set to 5000 for Medium priority to handle burst arrivals after idle scheduling
        self.idleExecutionEffort = 5000

        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
