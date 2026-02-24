import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowYieldVaultsEVM"
import "FlowToken"
import "FungibleToken"

/// @title FlowYieldVaultsEVMWorkerOps
/// @author Flow YieldVaults Team
/// @notice Worker management contract for FlowYieldVaultsEVM requests processing and auto-scheduling.
/// @dev This contract provides two resources that implement the TransactionHandler interface for
///      auto-processing EVM requests:
///      - WorkerHandler: Processes each request individually.
///      - SchedulerHandler: Recurrent job that checks for pending requests and
///                          schedules WorkerHandlers to process them based on available capacity.
///
///      Design Overview:
///      - WorkerHandler is scheduled to process a specified request individually. Upon completion, it will finalize
///        the request status back on EVM side.
///      - SchedulerHandler is always scheduled to run at the configured interval. It checks if there are any
///        pending requests in the EVM contract. If there are, it will schedule multiple WorkerHandlers to process the
///        requests based on available capacity.
///      - SchedulerHandler also identifies WorkerHandlers that panicked and handles the failure state changes accordingly.
///      - SchedulerHandler preprocesses requests before scheduling WorkerHandlers to identify and fail invalid requests.
///      - SchedulerHandler will schedule multiple WorkerHandlers for the same immediate height. If an EVM address has
///        multiple pending requests, they will be offsetted sequentially to avoid randomization in the same block.
///      - Contract provides shared state between WorkerHandler and SchedulerHandler (e.g. scheduledRequests dictionary).
///
///      EVM State Overview:
///      - PENDING -> PROCESSING -> COMPLETED/FAILED
///      - PENDING -> FAILED (drop/cancel/preprocess failure)
///
///      - PENDING:
///        - Request was created by an EVM user and is awaiting processing
///      - PROCESSING:
///        - Preprocessing was successful
///        - SchedulerHandler has scheduled a WorkerHandler to process the request
///      - COMPLETED:
///        - WorkerHandler has processed the request successfully and no failure occurred
///      - FAILED:
///        - WorkerHandler has processed the request successfully but it failed gracefully returning an error message
///        - WorkerHandler has panicked and SchedulerHandler has marked the request as FAILED
///        - Request was dropped or cancelled through the EVM contract
///
access(all) contract FlowYieldVaultsEVMWorkerOps {

    // ============================================
    // State Variables
    // ============================================

    /// @notice Tracks current in-flight scheduled requests by the SchedulerHandler
    /// @dev request id -> ScheduledEVMRequest
    access(self) var scheduledRequests: {UInt256: ScheduledEVMRequest}

    /// @notice When true, the SchedulerHandler will not schedule new WorkerHandlers
    /// @dev Note that this doesn't affect the in-flight requests (WorkerHandlers)
    access(self) var isSchedulerPaused: Bool

    // ============================================
    // Configuration Variables
    // ============================================

    /// @notice Interval at which the SchedulerHandler will be executed recurrently
    access(self) var schedulerWakeupInterval: UFix64

    /// @notice Maximum number of WorkerHandlers to be scheduled simultaneously
    access(self) var maxProcessingRequests: UInt8

    // ============================================
    // Configuration Variables (Execution Effort)
    // ============================================

    /// @notice Configurable execution effort constants for scheduling transactions
    /// @dev Keys are defined as public constants below. Values can be updated via Admin.setExecutionEffortConstants()
    access(all) let executionEffortConstants: {String: UInt64}

    /// @notice Key constant for scheduler base execution effort
    access(all) let SCHEDULER_BASE_EFFORT: String
    /// @notice Key constant for scheduler per-request additional execution effort
    access(all) let SCHEDULER_PER_REQUEST_EFFORT: String
    /// @notice Key constant for worker CREATE_YIELDVAULT request execution effort
    access(all) let WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT: String
    /// @notice Key constant for worker WITHDRAW_FROM_YIELDVAULT request execution effort
    access(all) let WORKER_WITHDRAW_REQUEST_EFFORT: String
    /// @notice Key constant for worker DEPOSIT_TO_YIELDVAULT request execution effort
    access(all) let WORKER_DEPOSIT_REQUEST_EFFORT: String
    /// @notice Key constant for worker CLOSE_YIELDVAULT request execution effort
    access(all) let WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT: String

    // ============================================
    // Path Configuration Variables
    // ============================================

    /// @notice Storage path for WorkerHandler resource
    access(all) let WorkerHandlerStoragePath: StoragePath

    /// @notice Storage path for SchedulerHandler resource
    access(all) let SchedulerHandlerStoragePath: StoragePath

    /// @notice Storage path for Admin resource
    access(all) let AdminStoragePath: StoragePath

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when the SchedulerHandler is paused
    access(all) event SchedulerPaused()

    /// @notice Emitted when the SchedulerHandler is unpaused
    access(all) event SchedulerUnpaused(
        nextTransactionId: UInt64,
    )

    /// @notice Emitted when WorkerHandler has executed a request
    /// @param transactionId The transaction ID that was executed
    /// @param requestId The request ID that was processed
    /// @param message The message from the WorkerHandler if error occurred
    access(all) event WorkerHandlerExecuted(
        transactionId: UInt64,
        requestId: UInt256?,
        processResult: FlowYieldVaultsEVM.ProcessResult?,
        message: String,
    )

    /// @notice Emitted when SchedulerHandler has executed a request
    /// @param transactionId The transaction ID that was executed
    /// @param nextTransactionId The transaction ID of the next SchedulerHandler execution
    /// @param message The message from the SchedulerHandler if error occurred
    access(all) event SchedulerHandlerExecuted(
        transactionId: UInt64,
        nextTransactionId: UInt64?,
        message: String,
        pendingRequestCount: Int?,
        fetchCount: Int?,
        runCapacity: UInt8?,
        nextRunCapacity: UInt8?,
    )

    /// @notice Emitted when a WorkerHandler has panicked and SchedulerHandler has marked the request as FAILED
    /// @param status The status of the transaction (Unknown, Scheduled, Executed, Canceled)
    /// @param markedAsFailed Whether the request was marked as FAILED
    /// @param request The request that was marked as FAILED
    access(all) event WorkerHandlerPanicDetected(
        status: UInt8?,
        markedAsFailed: Bool,
        request: ScheduledEVMRequest,
    )

    /// @notice Emitted when a WorkerHandler has been scheduled to process a request
    /// @param scheduledRequest The scheduled request
    access(all) event WorkerHandlerScheduled(
        scheduledRequest: ScheduledEVMRequest,
    )

    /// @notice Emitted when all scheduled executions are stopped and cancelled
    /// @param cancelledIds Array of cancelled transaction IDs
    /// @param totalRefunded Total amount of FLOW refunded
    access(all) event AllExecutionsStopped(
        cancelledIds: [UInt64],
        totalRefunded: UFix64
    )

    // ============================================
    // Admin Resource
    // ============================================

    /// @notice Admin resource for handler configuration
    /// @dev Only the contract deployer receives this resource
    access(all) resource Admin {

        /// @notice Pauses the SchedulerHandler, stopping new scheduling
        /// @dev This doesn't affect the in-flight requests (WorkerHandlers)
        access(all) fun pauseScheduler() {
            FlowYieldVaultsEVMWorkerOps.isSchedulerPaused = true
            emit SchedulerPaused()
        }

        /// @notice Unpauses the SchedulerHandler, resuming scheduling pending requests
        access(all) fun unpauseScheduler() {
            pre {
                FlowYieldVaultsEVMWorkerOps._getManagerFromStorage() != nil: "Scheduler manager not found"
                FlowYieldVaultsEVMWorkerOps._getSchedulerHandlerFromStorage() != nil: "SchedulerHandler resource not found"
            }
            if FlowYieldVaultsEVMWorkerOps.isSchedulerPaused {
                FlowYieldVaultsEVMWorkerOps.isSchedulerPaused = false
                let schedulerHandler = FlowYieldVaultsEVMWorkerOps._getSchedulerHandlerFromStorage()!
                let manager = FlowYieldVaultsEVMWorkerOps._getManagerFromStorage()!
                let txId = schedulerHandler.scheduleNextSchedulerExecution(manager: manager, forNumberOfRequests: 0)
                emit SchedulerUnpaused(
                    nextTransactionId: txId,
                )
            }
        }

        /// @notice Sets the maximum number of WorkerHandlers to be scheduled simultaneously
        access(all) fun setMaxProcessingRequests(maxProcessingRequests: UInt8) {
            pre {
                maxProcessingRequests > 0: "Max processing requests must be greater than 0"
            }
            FlowYieldVaultsEVMWorkerOps.maxProcessingRequests = maxProcessingRequests
        }

        /// @notice Sets the execution effort constants
        /// @param key The key of the execution effort constant to set
        /// @param value The value of the execution effort constant to set
        access(all) fun setExecutionEffortConstants(key: String, value: UInt64) {
            pre {
                value > 0: "Execution effort must be greater than 0"
                key == FlowYieldVaultsEVMWorkerOps.SCHEDULER_BASE_EFFORT ||
                key == FlowYieldVaultsEVMWorkerOps.SCHEDULER_PER_REQUEST_EFFORT ||
                key == FlowYieldVaultsEVMWorkerOps.WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT ||
                key == FlowYieldVaultsEVMWorkerOps.WORKER_WITHDRAW_REQUEST_EFFORT ||
                key == FlowYieldVaultsEVMWorkerOps.WORKER_DEPOSIT_REQUEST_EFFORT ||
                key == FlowYieldVaultsEVMWorkerOps.WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT
                : "Invalid key: \(key)"
            }
            FlowYieldVaultsEVMWorkerOps.executionEffortConstants[key] = value
        }

        /// @notice Sets the interval at which the SchedulerHandler will be executed recurrently
        access(all) fun setSchedulerWakeupInterval(schedulerWakeupInterval: UFix64) {
            pre {
                schedulerWakeupInterval > 0.0: "Scheduler wakeup interval must be greater than 0.0"
            }
            FlowYieldVaultsEVMWorkerOps.schedulerWakeupInterval = schedulerWakeupInterval
        }

        /// @notice Creates a new WorkerHandler resource
        /// @return The newly created WorkerHandler resource
        access(all) fun createWorkerHandler(
            workerCap: Capability<&FlowYieldVaultsEVM.Worker>,
        ): @WorkerHandler {
            pre {
                workerCap.check(): "Worker capability is invalid (id: \(workerCap.id))"
            }
            return <- create WorkerHandler(workerCap: workerCap)
        }

        /// @notice Creates a new SchedulerHandler resource
        /// @return The newly created SchedulerHandler resource
        access(all) fun createSchedulerHandler(
            workerCap: Capability<&FlowYieldVaultsEVM.Worker>,
        ): @SchedulerHandler {
            pre {
                workerCap.check(): "Worker capability is invalid (id: \(workerCap.id))"
            }
            return <- create SchedulerHandler(workerCap: workerCap)
        }

        /// @notice Stops all scheduled executions by pausing the SchedulerHandler and cancelling all pending transactions
        /// @dev This will pause the handler and cancel all scheduled transactions, refunding fees.
        access(all) fun stopAll() {
            pre {
                FlowYieldVaultsEVMWorkerOps._getManagerFromStorage() != nil: "Scheduler manager not found"
                FlowYieldVaultsEVMWorkerOps._getFlowTokenVaultFromStorage() != nil: "FlowToken vault not found"
                FlowYieldVaultsEVMWorkerOps._getSchedulerHandlerFromStorage() != nil: "SchedulerHandler resource not found"
            }

            // Step 1: Pause the SchedulerHandler to prevent any new scheduling during cancellation
            self.pauseScheduler()

            // Borrow the scheduler Manager from storage
            let manager = FlowYieldVaultsEVMWorkerOps._getManagerFromStorage()!

            let cancelledIds: [UInt64] = []

            var totalRefunded: UFix64 = 0.0

            // Borrow FlowToken vault to deposit refunded fees
            let vaultRef = FlowYieldVaultsEVMWorkerOps._getFlowTokenVaultFromStorage()!

            // Step 2: Cancel each scheduled transaction and collect refunds
            for scheduledRequestId in FlowYieldVaultsEVMWorkerOps.scheduledRequests.keys {
                let request = FlowYieldVaultsEVMWorkerOps.scheduledRequests[scheduledRequestId]!
                let refund <- manager.cancel(id: request.workerTransactionId)
                totalRefunded = totalRefunded + refund.balance
                vaultRef.deposit(from: <-refund)
                cancelledIds.append(request.workerTransactionId)
                FlowYieldVaultsEVMWorkerOps.scheduledRequests.remove(key: scheduledRequestId)
            }

            // Step 3: Cancel scheduler execution
            let schedulerHandler = FlowYieldVaultsEVMWorkerOps._getSchedulerHandlerFromStorage()!
            if let schedulerTransactionId = schedulerHandler.nextSchedulerTransactionId {
                let refund <- manager.cancel(id: schedulerTransactionId)
                totalRefunded = totalRefunded + refund.balance
                vaultRef.deposit(from: <-refund)
                cancelledIds.append(schedulerTransactionId)
            }

            emit AllExecutionsStopped(
                cancelledIds: cancelledIds,
                totalRefunded: totalRefunded,
            )
        }
    }

    // ============================================
    // WorkerHandler Resource
    // ============================================

    /// @notice Handler that processes the given EVM requests
    access(all) resource WorkerHandler: FlowTransactionScheduler.TransactionHandler {

        /// @notice Capability to the Worker resource for processing requests
        access(self) let workerCap: Capability<&FlowYieldVaultsEVM.Worker>

        /// @notice Initializes the WorkerHandler
        init(
            workerCap: Capability<&FlowYieldVaultsEVM.Worker>,
        ) {
            pre {
                workerCap.check(): "Worker capability is invalid (id: \(workerCap.id))"
            }
            self.workerCap = workerCap
        }

        /// @notice Processes the assigned EVMRequest
        /// @dev This is scheduled by the SchedulerHandler
        /// @param id The transaction ID being executed
        /// @param data - UInt256 - The request ID to process
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {

            // Get the worker capability
            let worker = self.workerCap.borrow()!

            var message = ""
            var processResult: FlowYieldVaultsEVM.ProcessResult? = nil

            // Process assigned request
            if let requestId = data as? UInt256 {
                if let request = FlowYieldVaultsEVM.getRequestUnpacked(requestId) {
                    processResult = worker.processRequest(request)
                    message = "Successfully processed request"
                } else {
                    message = "Request not found: \(requestId.toString())"
                }
                FlowYieldVaultsEVMWorkerOps.scheduledRequests.remove(key: requestId)
            } else {
                message = "No valid request ID found"
            }

            emit WorkerHandlerExecuted(
                transactionId: id,
                requestId: data as? UInt256,
                processResult: processResult,
                message: message,
            )
        }

        /// @notice Returns the view types supported by the WorkerHandler
        /// @return Array of supported view types
        access(all) view fun getViews(): [Type] {
            return [Type<StoragePath>()]
        }

        /// @notice Resolves a view for the WorkerHandler
        /// @param view The view type to resolve
        /// @return The resolved view value or nil
        access(all) view fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<StoragePath>():
                    return FlowYieldVaultsEVMWorkerOps.WorkerHandlerStoragePath
                default:
                    return nil
            }
        }

    }

    // ============================================
    // SchedulerHandler Resource
    // ============================================

    /// @notice Recurrent handler that checks for pending requests and schedules WorkerHandlers to process them
    /// @dev Also manages crash recovery for scheduled WorkerHandlers
    access(all) resource SchedulerHandler: FlowTransactionScheduler.TransactionHandler {

        /// @notice Capability to the Worker resource for processing requests
        access(self) let workerCap: Capability<&FlowYieldVaultsEVM.Worker>

        /// @notice Transaction ID of the next scheduled SchedulerHandler execution
        access(all) var nextSchedulerTransactionId: UInt64?

        /// @notice Initializes the SchedulerHandler
        init(
            workerCap: Capability<&FlowYieldVaultsEVM.Worker>,
        ) {
            pre {
                workerCap.check(): "Worker capability is invalid (id: \(workerCap.id))"
            }
            self.workerCap = workerCap
            self.nextSchedulerTransactionId = nil
        }

        /// @notice Executes the recurrent scheduler logic
        /// @param id The transaction ID being executed
        /// @param data Unused - scheduler data (nil)
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            pre {
                FlowYieldVaultsEVMWorkerOps._getManagerFromStorage() != nil: "Scheduler manager not found"
                FlowYieldVaultsEVMWorkerOps._getWorkerHandlerFromStorage() != nil: "WorkerHandler resource not found"
                FlowYieldVaultsEVMWorkerOps._getFlowTokenVaultFromStorage() != nil: "FlowToken vault not found"
            }

            // Check if scheduler is paused
            if FlowYieldVaultsEVMWorkerOps.isSchedulerPaused {
                emit SchedulerHandlerExecuted(
                    transactionId: id,
                    nextTransactionId: nil,
                    message: "Scheduler is paused",
                    pendingRequestCount: nil,
                    fetchCount: nil,
                    runCapacity: nil,
                    nextRunCapacity: nil,
                )
                // Return without executing the main scheduler logic
                // No further scheduler executions will be scheduled to save fees during paused state
                return
            }

            // Load scheduler manager and worker from storage
            let manager = FlowYieldVaultsEVMWorkerOps._getManagerFromStorage()!
            let worker = self.workerCap.borrow()!

            var message = ""
            var nextRunCapacity: UInt8 = 0
            var pendingCount: Int? = nil
            var fetchCount: Int? = nil

            // Extract computation limit from passed data (nil is interpreted as 0)
            // Defines how much computation is available for the scheduler to use
            // 1 means 1 request to preprocess
            var runCapacity = data as? UInt8 ?? 0

            // Calculate capacity
            let capacityLimit = UInt8(
                FlowYieldVaultsEVMWorkerOps.maxProcessingRequests -
                UInt8(FlowYieldVaultsEVMWorkerOps.scheduledRequests.length))
            if capacityLimit > 0 {
                let capacity = runCapacity < capacityLimit ? runCapacity : capacityLimit

                // Check pending request count
                if let pendingRequestCount = worker.getPendingRequestCountFromEVM() {
                    pendingCount = pendingRequestCount
                    if pendingRequestCount > 0 {

                        fetchCount = pendingRequestCount > Int(capacity) ? Int(capacity) : pendingRequestCount

                        // Run main scheduler logic
                        if let errorMessage = self._runScheduler(
                            manager: manager,
                            worker: worker,
                            fetchCount: fetchCount!,
                        ) {
                            message = "Scheduler failed with error: \(errorMessage)"
                        } else {
                            message = "Scheduler ran successfully"
                        }

                        let stillPendingCount = pendingRequestCount - fetchCount!
                        nextRunCapacity = stillPendingCount < Int(FlowYieldVaultsEVMWorkerOps.maxProcessingRequests)
                            ? UInt8(stillPendingCount)
                            : FlowYieldVaultsEVMWorkerOps.maxProcessingRequests
                    }
                } else {
                    message = "ERROR fetching pending requests"
                }
            }

            // Schedule the next execution
            let nextTransactionId = self.scheduleNextSchedulerExecution(
                manager: manager,
                forNumberOfRequests: nextRunCapacity,
            )
            self.nextSchedulerTransactionId = nextTransactionId

            emit SchedulerHandlerExecuted(
                transactionId: id,
                nextTransactionId: nextTransactionId,
                message: message,
                pendingRequestCount: pendingCount,
                fetchCount: fetchCount,
                runCapacity: runCapacity,
                nextRunCapacity: nextRunCapacity,
            )
        }

        /// @notice Main scheduler logic
        /// @dev Flow:
        ///      1. Check if scheduler is paused
        ///      2. Check for failed worker requests
        ///         - If a failure is identified, mark the request as failed and remove it from scheduledRequests
        ///      3. Check pending request count & calculate capacity
        ///      4. Fetch pending requests data from EVM contract
        ///      5. Preprocess requests to drop invalid requests
        ///      6. Start processing requests (PENDING -> PROCESSING)
        ///      7. Schedule WorkerHandlers and assign request ids to them
        /// @param manager The scheduler manager
        /// @return Error message if any error occurred, nil otherwise
        access(self) fun _runScheduler(
            manager: auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager},
            worker: &FlowYieldVaultsEVM.Worker,
            fetchCount: Int,
        ): String? {
            // Check for failed worker requests
            self._checkForFailedWorkerRequests(manager: manager, worker: worker)

            // Fetch pending requests from EVM
            if fetchCount > 0 {
                if let pendingRequests = worker.getPendingRequestsFromEVM(
                    startIndex: 0,
                    count: fetchCount,
                ) {
                    // Preprocess requests (PENDING -> PROCESSING)
                    var successCount = 0
                    if let successfulRequests = worker.preprocessRequests(pendingRequests) {
                        // Schedule WorkerHandlers and assign request ids to them
                        self._scheduleWorkerHandlersForRequests(
                            requests: successfulRequests,
                            manager: manager,
                        )
                        successCount = successfulRequests.length
                    }
                } else {
                    return "Failed to fetch pending requests"
                }
            }

            return nil // no error
        }

        /// @notice Identifies failed WorkerHandlers (due to panic or revert) and marks the requests as FAILED
        /// @dev Flow:
        ///      1. Iterate over scheduledRequests
        ///         - scheduledRequests should only contain pending and reverted requests
        ///      2. Check if the intended block height has been reached, continue if not
        ///      3. Get transaction status for scheduled request from manager
        ///         - Only acceptable transaction status is Scheduled (pending execution)
        ///         - No status is considered not acceptable because it means the manager cleaned up the request
        ///      4. If the transaction status is invalid, mark the request as FAILED providing the transaction ID
        ///      5. Remove the request from scheduledRequests
        /// @param manager The scheduler manager
        /// @param worker The worker capability
        /// @return Error message if any error occurred, nil otherwise
        access(self) fun _checkForFailedWorkerRequests(
            manager: &{FlowTransactionSchedulerUtils.Manager},
            worker: &FlowYieldVaultsEVM.Worker,
        ) {
            for requestId in FlowYieldVaultsEVMWorkerOps.scheduledRequests.keys {
                let request = FlowYieldVaultsEVMWorkerOps.scheduledRequests[requestId]!

                // Check block height
                if getCurrentBlock().timestamp <= request.workerScheduledTimestamp {
                    // Expected timestamp is not reached yet, skip
                    continue
                }

                // Check transaction status for scheduled requests to find reverts
                let txId = request.workerTransactionId
                let txStatus = manager.getTransactionStatus(id: txId)

                // Only acceptable status is Scheduled
                // Handled requests by the worker should have been removed from scheduledRequests
                // If manager cleaned up the transaction, the status will be nil
                if txStatus == nil || txStatus != FlowTransactionScheduler.Status.Scheduled {

                    // Fail request
                    let success = worker.markRequestAsFailed(
                        request.request,
                        message: "Worker transaction did not execute successfully. Transaction ID: \(txId.toString())",
                    )

                    // Remove request from scheduledRequests
                    // Success is not checked because errors are not considered transient
                    FlowYieldVaultsEVMWorkerOps.scheduledRequests.remove(key: requestId)

                    emit WorkerHandlerPanicDetected(
                        status: txStatus?.rawValue,
                        markedAsFailed: success,
                        request: request,
                    )
                }
            }
        }

        /// @notice Schedules WorkerHandlers for the given requests
        /// @dev Flow:
        ///      1. Iterate over given requests
        ///      2. Decide delay
        ///         - Immediate execution is default
        ///         - If multiple requests from same user, offset delay by user request count to run them sequentially
        ///      3. Schedule WorkerHandlers and pass request info
        ///      4. Track scheduled request in contract state to be able to identify failed requests
        /// @param requests The requests to schedule
        /// @param manager The scheduler manager
        access(self) fun _scheduleWorkerHandlersForRequests(
            requests: [FlowYieldVaultsEVM.EVMRequest],
            manager: auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager},
        ) {
            let workerHandler = FlowYieldVaultsEVMWorkerOps._getWorkerHandlerFromStorage()!

            // WorkerHandler scheduling parameters
            let baseDelay = 1.0

            // Borrow FlowToken vault to pay scheduling fees
            let vaultRef = FlowYieldVaultsEVMWorkerOps._getFlowTokenVaultFromStorage()!

            // Track user request count for scheduling offset
            let userScheduleOffset: {String: Int} = {} // user address -> request count - 1
            for request in requests {

                // Count user requests for scheduling
                let key = request.user.toString()
                if userScheduleOffset[key] == nil {
                    // first request for user is scheduled immediately
                    userScheduleOffset[key] = 0
                } else {
                    // subsequent requests are scheduled with an offset
                    userScheduleOffset[key] = userScheduleOffset[key]! + 1
                }

                // Offset delay by user request count
                // We assume the original list is sorted by user action timestamp
                // and no action changes order of requests
                let delay = baseDelay + UFix64(userScheduleOffset[key]!)
                var executionEffort: UInt64 = 0
                switch request.requestType {
                    case FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue:
                        executionEffort = FlowYieldVaultsEVMWorkerOps.executionEffortConstants[
                            FlowYieldVaultsEVMWorkerOps.WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT
                        ]!
                    case FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue:
                        executionEffort = FlowYieldVaultsEVMWorkerOps.executionEffortConstants[
                            FlowYieldVaultsEVMWorkerOps.WORKER_WITHDRAW_REQUEST_EFFORT
                        ]!
                    case FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue:
                        executionEffort = FlowYieldVaultsEVMWorkerOps.executionEffortConstants[
                            FlowYieldVaultsEVMWorkerOps.WORKER_DEPOSIT_REQUEST_EFFORT
                        ]!
                    case FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue:
                        executionEffort = FlowYieldVaultsEVMWorkerOps.executionEffortConstants[
                            FlowYieldVaultsEVMWorkerOps.WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT
                        ]!
                }

                // Schedule transaction
                let transactionId = self._scheduleTransaction(
                    manager: manager,
                    handlerTypeIdentifier: workerHandler.getType().identifier,
                    data: request.id,
                    delay: delay,
                    executionEffort: executionEffort,
                )

                // Track scheduled request in contract state
                let scheduledRequest = ScheduledEVMRequest(
                    request: request,
                    workerTransactionId: transactionId,
                    workerScheduledTimestamp: getCurrentBlock().timestamp + delay,
                )

                emit WorkerHandlerScheduled(
                    scheduledRequest: scheduledRequest
                )

                FlowYieldVaultsEVMWorkerOps.scheduledRequests.insert(key: request.id, scheduledRequest)

            }
        }

        /// @notice Schedules the next recurrent execution for SchedulerHandler
        /// @param manager The scheduler manager
        access(contract) fun scheduleNextSchedulerExecution(
            manager: auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager},
            forNumberOfRequests: UInt8,
        ): UInt64 {
            // Scheduler parameters
            let baseEffort = FlowYieldVaultsEVMWorkerOps.executionEffortConstants[
                FlowYieldVaultsEVMWorkerOps.SCHEDULER_BASE_EFFORT
            ]!
            let perRequestEffort = FlowYieldVaultsEVMWorkerOps.executionEffortConstants[
                FlowYieldVaultsEVMWorkerOps.SCHEDULER_PER_REQUEST_EFFORT
            ]!
            let executionEffort = baseEffort + UInt64(forNumberOfRequests) * perRequestEffort

            return self._scheduleTransaction(
                manager: manager,
                handlerTypeIdentifier: self.getType().identifier,
                data: forNumberOfRequests,
                delay: FlowYieldVaultsEVMWorkerOps.schedulerWakeupInterval,
                executionEffort: executionEffort,
            )
        }

        /// @notice Helper function to schedule a transaction for the SchedulerHandler
        /// @dev This function is used for both recurrent scheduling and WorkerHandler scheduling
        /// @param manager The scheduler manager
        /// @param handlerTypeIdentifier The type identifier of the handler
        /// @param data The data to pass to the handler
        /// @param delay The delay in seconds
        /// @return The transaction ID
        access(self) fun _scheduleTransaction(
            manager: auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager},
            handlerTypeIdentifier: String,
            data: AnyStruct?,
            delay: UFix64,
            executionEffort: UInt64,
        ): UInt64 {
            // Calculate the target execution timestamp
            let future = getCurrentBlock().timestamp + delay

            // Determine priority based on execution effort
            var priority = FlowTransactionScheduler.Priority.Low
            if executionEffort > 2500 && executionEffort < 7500 {
                priority = FlowTransactionScheduler.Priority.Medium
            } else if executionEffort >= 7500 {
                priority = FlowTransactionScheduler.Priority.High
            }

            // Borrow FlowToken vault to pay scheduling fees
            let vaultRef = FlowYieldVaultsEVMWorkerOps._getFlowTokenVaultFromStorage()!

            // Estimate fees and withdraw payment
            // calculateFee() is not supported by Flow emulator. When emulator is updated, following code can be uncommented.
            // data is nil or UInt256, size is 0 in both cases
            // let dataSizeMB = 0.0
            // let fee = FlowTransactionScheduler.calculateFee(
            //     executionEffort: executionEffort,
            //     priority: priority,
            //     dataSizeMB: dataSizeMB,
            // )
            // let fees <- vaultRef.withdraw(amount: fee) as! @FlowToken.Vault
            let estimate = FlowTransactionScheduler.estimate(
                data: nil,
                timestamp: future,
                priority: priority,
                executionEffort: executionEffort
            )
            let fees <- vaultRef.withdraw(amount: estimate.flowFee ?? 0.0) as! @FlowToken.Vault

            // Schedule the transaction
            let transactionId = manager.scheduleByHandler(
                handlerTypeIdentifier: handlerTypeIdentifier,
                handlerUUID: nil,
                data: data,
                timestamp: future,
                priority: priority,
                executionEffort: executionEffort,
                fees: <-fees
            )

            return transactionId
        }

        /// @notice Returns the view types supported by this handler
        /// @return Array of supported view types
        access(all) view fun getViews(): [Type] {
            return [Type<StoragePath>()]
        }

        /// @notice Resolves a view for this handler
        /// @param view The view type to resolve
        /// @return The resolved view value or nil
        access(all) view fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<StoragePath>():
                    return FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath
                default:
                    return nil
            }
        }

    }

    // ============================================
    // Internal Helper View Functions
    // ============================================

    /// @notice Gets the Manager from contract storage for managing scheduled transactions
    /// @return The manager or nil if not found
    access(self) view fun _getManagerFromStorage():
     auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}? {
        return FlowYieldVaultsEVMWorkerOps.account.storage
            .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>
            (from: FlowTransactionSchedulerUtils.managerStoragePath)
    }

    /// @notice Gets the WorkerHandler from contract storage
    /// @return The WorkerHandler or nil if not found
    access(self) view fun _getWorkerHandlerFromStorage(): &WorkerHandler? {
        return FlowYieldVaultsEVMWorkerOps.account.storage
            .borrow<&WorkerHandler>
            (from: FlowYieldVaultsEVMWorkerOps.WorkerHandlerStoragePath)
    }

    /// @notice Gets the SchedulerHandler from contract storage
    /// @return The SchedulerHandler or nil if not found
    access(self) view fun _getSchedulerHandlerFromStorage(): &SchedulerHandler? {
        return FlowYieldVaultsEVMWorkerOps.account.storage
            .borrow<&SchedulerHandler>
            (from: FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath)
    }

    /// @notice Gets the FlowToken vault from contract storage
    /// @return The FlowToken vault or nil if not found
    access(self) view fun _getFlowTokenVaultFromStorage():
     auth(FungibleToken.Withdraw) &FlowToken.Vault? {
        return FlowYieldVaultsEVMWorkerOps.account.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>
            (from: /storage/flowTokenVault)
    }

    // ============================================
    // Data Structures
    // ============================================

    /// @notice Data structure to track scheduled EVM requests
    access(all) struct ScheduledEVMRequest {
        /// @notice The EVM request to be processed
        access(all) let request: FlowYieldVaultsEVM.EVMRequest
        /// @notice The transaction ID of the scheduled WorkerHandler
        access(all) let workerTransactionId: UInt64
        /// @notice The timestamp when the scheduled WorkerHandler is scheduled to execute
        access(all) let workerScheduledTimestamp: UFix64

        init(
            request: FlowYieldVaultsEVM.EVMRequest,
            workerTransactionId: UInt64,
            workerScheduledTimestamp: UFix64,
        ) {
            self.request = request
            self.workerTransactionId = workerTransactionId
            self.workerScheduledTimestamp = workerScheduledTimestamp
        }
    }

    // ============================================
    // Public Functions
    // ============================================

    /// @notice Returns the current SchedulerHandler paused state
    /// @return True if scheduler is paused, false otherwise
    access(all) view fun getIsSchedulerPaused(): Bool {
        return self.isSchedulerPaused
    }

    // ============================================
    // Initialization
    // ============================================

    init() {
        self.WorkerHandlerStoragePath = /storage/FlowYieldVaultsEVMWorkerOpsWorkerHandler
        self.SchedulerHandlerStoragePath = /storage/FlowYieldVaultsEVMWorkerOpsSchedulerHandler
        self.AdminStoragePath = /storage/FlowYieldVaultsEVMWorkerOpsAdmin

        self.SCHEDULER_BASE_EFFORT = "schedulerBaseEffort"
        self.SCHEDULER_PER_REQUEST_EFFORT = "schedulerPerRequestEffort"
        self.WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT = "workerCreateYieldVaultRequestEffort"
        self.WORKER_WITHDRAW_REQUEST_EFFORT = "workerWithdrawRequestEffort"
        self.WORKER_DEPOSIT_REQUEST_EFFORT = "workerDepositRequestEffort"
        self.WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT = "workerCloseYieldVaultRequestEffort"

        self.executionEffortConstants = {
            self.SCHEDULER_BASE_EFFORT: 700,
            self.SCHEDULER_PER_REQUEST_EFFORT: 1000,
            self.WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT: 5000,
            self.WORKER_WITHDRAW_REQUEST_EFFORT: 2000,
            self.WORKER_DEPOSIT_REQUEST_EFFORT: 2000,
            self.WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT: 5000
        }

        self.scheduledRequests = {}
        self.isSchedulerPaused = false

        self.schedulerWakeupInterval = 1.0
        self.maxProcessingRequests = 3

        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
