import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowVaultsEVM"
import "FlowToken"
import "FungibleToken"

/// @title FlowVaultsTransactionHandler
/// @author Flow Vaults Team
/// @notice Handler contract for scheduled FlowVaultsEVM request processing with auto-scheduling.
/// @dev This contract manages the automated execution of EVM request processing through the
///      FlowTransactionScheduler. After each execution, it automatically schedules the next
///      execution based on the current workload.
///
///      Key features:
///      - Dynamic delay adjustment based on pending request count
///      - Parallel transaction scheduling for high throughput
///      - Pausable execution for maintenance
///
///      Delay thresholds:
///      - >= 50 pending: 5s delay (high load)
///      - >= 20 pending: 15s delay (medium-high load)
///      - >= 10 pending: 30s delay (medium load)
///      - >= 5 pending: 45s delay (low load)
///      - >= 0 pending: 60s delay (idle)
access(all) contract FlowVaultsTransactionHandler {

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
    access(all) let thresholdToDelay: {Int: UFix64}

    /// @notice Default delay when no threshold matches
    access(all) let defaultDelay: UFix64

    /// @notice When true, scheduled executions skip processing and don't schedule next execution
    access(all) var isPaused: Bool

    /// @notice Maximum parallel transactions to schedule at once
    /// @dev Each transaction processes up to FlowVaultsEVM.maxRequestsPerTx requests
    access(all) var maxParallelTransactions: Int

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when the handler is paused
    access(all) event HandlerPaused()

    /// @notice Emitted when the handler is unpaused
    access(all) event HandlerUnpaused()

    /// @notice Emitted when maxParallelTransactions is updated
    /// @param oldValue The previous value
    /// @param newValue The new value
    access(all) event MaxParallelTransactionsUpdated(oldValue: Int, newValue: Int)

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

    /// @notice Emitted when parallel executions are scheduled
    /// @param coordinatorId The coordinator transaction ID
    /// @param workerIds Array of worker transaction IDs
    /// @param scheduledFor Timestamp when executions are scheduled
    /// @param delaySeconds Delay from current time
    /// @param pendingRequests Current pending request count
    /// @param workerCount Number of worker transactions scheduled
    access(all) event ParallelExecutionsScheduled(
        coordinatorId: UInt64,
        workerIds: [UInt64],
        scheduledFor: UFix64,
        delaySeconds: UFix64,
        pendingRequests: Int,
        workerCount: Int
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
            FlowVaultsTransactionHandler.isPaused = true
            emit HandlerPaused()
        }

        /// @notice Unpauses the handler, resuming scheduled executions
        access(all) fun unpause() {
            FlowVaultsTransactionHandler.isPaused = false
            emit HandlerUnpaused()
        }

        /// @notice Sets the maximum number of parallel transactions
        /// @param count The new maximum (must be > 0)
        access(all) fun setMaxParallelTransactions(count: Int) {
            pre {
                count > 0: "Max parallel transactions must be greater than 0"
            }
            let oldValue = FlowVaultsTransactionHandler.maxParallelTransactions
            FlowVaultsTransactionHandler.maxParallelTransactions = count
            emit MaxParallelTransactionsUpdated(oldValue: oldValue, newValue: count)
        }

        /// @notice Stops all scheduled executions by pausing and cancelling all pending transactions
        /// @dev This will pause the handler and cancel all scheduled transactions, refunding fees
        /// @return Dictionary with cancelledIds array and totalRefunded amount
        access(all) fun stopAll(): {String: AnyStruct} {
            // First pause to prevent any new scheduling
            FlowVaultsTransactionHandler.isPaused = true
            emit HandlerPaused()

            // Borrow the manager to cancel scheduled transactions
            let manager = FlowVaultsTransactionHandler.account.storage
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
            let vaultRef = FlowVaultsTransactionHandler.account.storage
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

        access(self) let workerCap: Capability<&FlowVaultsEVM.Worker>
        access(self) var executionCount: UInt64
        access(self) var lastExecutionTime: UFix64?

        init(workerCap: Capability<&FlowVaultsEVM.Worker>) {
            self.workerCap = workerCap
            self.executionCount = 0
            self.lastExecutionTime = nil
        }

        /// @notice Executes the scheduled transaction
        /// @dev Called by FlowTransactionScheduler when the scheduled time arrives.
        ///      Processes requests and schedules the next execution.
        /// @param id The transaction ID being executed
        /// @param data Array [UInt8 priority, UInt64 executionEffort] - priority (0=High, 1=Medium, 2=Low)
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            if FlowVaultsTransactionHandler.isPaused {
                emit ExecutionSkipped(transactionId: id, reason: "Handler is paused")
                return
            }

            let worker = self.workerCap.borrow()
            if worker == nil {
                emit ExecutionSkipped(transactionId: id, reason: "Could not borrow Worker capability")
                return
            }

            // Parse data: [priority: UInt8, executionEffort: UInt64]
            var priorityRaw: UInt8 = 1
            var executionEffort: UInt64 = 7499

            if let dataArray = data as? [AnyStruct] {
                if dataArray.length >= 1 {
                    priorityRaw = (dataArray[0] as? UInt8) ?? priorityRaw
                }
                if dataArray.length >= 2 {
                    executionEffort = (dataArray[1] as? UInt64) ?? executionEffort
                }
            }

            let priority = priorityRaw == 0
                ? FlowTransactionScheduler.Priority.High
                : priorityRaw == 1
                    ? FlowTransactionScheduler.Priority.Medium
                    : FlowTransactionScheduler.Priority.Low

            // Process requests
            let maxRequestsPerTx = FlowVaultsEVM.maxRequestsPerTx
            worker!.processRequests(startIndex: 0, count: maxRequestsPerTx)

            self.executionCount = self.executionCount + 1
            self.lastExecutionTime = getCurrentBlock().timestamp

            // Get pending count and schedule next execution
            let pendingRequests = self.getPendingRequestCount(worker!)
            let nextDelay = FlowVaultsTransactionHandler.getDelayForPendingCount(pendingRequests)

            emit ScheduledExecutionTriggered(
                transactionId: id,
                pendingRequests: pendingRequests,
                nextExecutionDelaySeconds: nextDelay
            )

            self.scheduleNextExecution(nextDelay: nextDelay, priority: priority, executionEffort: executionEffort)
        }

        access(self) fun scheduleNextExecution(nextDelay: UFix64, priority: FlowTransactionScheduler.Priority, executionEffort: UInt64) {
            let future = getCurrentBlock().timestamp + nextDelay

            let manager = FlowVaultsTransactionHandler.account.storage
                .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                    from: FlowTransactionSchedulerUtils.managerStoragePath
                )
                ?? panic("Could not borrow Manager reference from contract account")

            let handlerTypeIdentifiers = manager.getHandlerTypeIdentifiers()
            assert(handlerTypeIdentifiers.keys.length > 0, message: "No handler types found in manager")
            let handlerTypeIdentifier = handlerTypeIdentifiers.keys[0]

            let vaultRef = FlowVaultsTransactionHandler.account.storage
                .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
                ?? panic("missing FlowToken vault on contract account")

            // Pass [priority, executionEffort] in data so they persist across executions
            let priorityRaw: UInt8 = priority == FlowTransactionScheduler.Priority.High ? 0
                : priority == FlowTransactionScheduler.Priority.Medium ? 1 : 2
            let schedulingData: [AnyStruct] = [priorityRaw, executionEffort]

            let estimate = FlowTransactionScheduler.estimate(
                data: schedulingData,
                timestamp: future,
                priority: priority,
                executionEffort: executionEffort
            )
            let fees <- vaultRef.withdraw(amount: estimate.flowFee ?? 0.0) as! @FlowToken.Vault
            let transactionId = manager.scheduleByHandler(
                handlerTypeIdentifier: handlerTypeIdentifier,
                handlerUUID: self.uuid,
                data: schedulingData,
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
                    return FlowVaultsTransactionHandler.HandlerStoragePath
                case Type<PublicPath>():
                    return FlowVaultsTransactionHandler.HandlerPublicPath
                default:
                    return nil
            }
        }

        access(self) fun getPendingRequestCount(_ worker: &FlowVaultsEVM.Worker): Int {
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
    /// @param workerCap Capability to the FlowVaultsEVM.Worker
    /// @return The newly created Handler resource
    access(all) fun createHandler(workerCap: Capability<&FlowVaultsEVM.Worker>): @Handler {
        return <- create Handler(workerCap: workerCap)
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

    // ============================================
    // Initialization
    // ============================================

    init() {
        self.HandlerStoragePath = /storage/FlowVaultsTransactionHandler
        self.HandlerPublicPath = /public/FlowVaultsTransactionHandler
        self.AdminStoragePath = /storage/FlowVaultsTransactionHandlerAdmin
        self.isPaused = false
        self.maxParallelTransactions = 1
        self.defaultDelay = 60.0
        self.thresholdToDelay = {
            50: 5.0,
            20: 15.0,
            10: 30.0,
            5: 45.0,
            0: 60.0
        }

        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
