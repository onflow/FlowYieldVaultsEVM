import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowVaultsEVM"
import "FlowToken"
import "FungibleToken"

/// Handler contract for scheduled FlowVaultsEVM request processing
/// WITH AUTO-SCHEDULING: After each execution, automatically schedules the next one
access(all) contract FlowVaultsTransactionHandler {

    // ========================================
    // Constants
    // ========================================
    
    access(all) let HandlerStoragePath: StoragePath
    access(all) let HandlerPublicPath: PublicPath
    access(all) let AdminStoragePath: StoragePath
    
    /// 5 delay levels (in seconds)
    access(all) let DELAY_LEVELS: [UFix64]
    
    /// Thresholds for 5 delay levels (pending request counts)
    access(all) let LOAD_THRESHOLDS: [Int]
    
    // ========================================
    // State
    // ========================================
    
    /// When true, scheduled executions will skip processing and not schedule the next execution
    access(all) var isPaused: Bool
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event HandlerPaused()
    access(all) event HandlerUnpaused()
    
    access(all) event ScheduledExecutionTriggered(
        transactionId: UInt64,
        pendingRequests: Int,
        delayLevel: Int,
        nextExecutionDelay: UFix64
    )
    
    access(all) event NextExecutionScheduled(
        transactionId: UInt64,
        scheduledFor: UFix64,
        delaySeconds: UFix64,
        pendingRequests: Int
    )

    // ========================================
    // Admin Resource
    // ========================================
    
    access(all) resource Admin {
        access(all) fun pause() {
            FlowVaultsTransactionHandler.isPaused = true
            emit HandlerPaused()
        }
        
        access(all) fun unpause() {
            FlowVaultsTransactionHandler.isPaused = false
            emit HandlerUnpaused()
        }
    }

    // ========================================
    // Handler Resource
    // ========================================

    access(all) resource Handler: FlowTransactionScheduler.TransactionHandler {
        
        access(self) let workerCap: Capability<&FlowVaultsEVM.Worker>
        access(self) var executionCount: UInt64
        access(self) var lastExecutionTime: UFix64?
        
        init(workerCap: Capability<&FlowVaultsEVM.Worker>) {
            self.workerCap = workerCap
            self.executionCount = 0
            self.lastExecutionTime = nil
        }
        
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            log("=== FlowVaultsEVM Scheduled Execution Started ===")
            log("Transaction ID: ".concat(id.toString()))
            
            // Check if paused
            if FlowVaultsTransactionHandler.isPaused {
                log("⏸️  Handler is PAUSED - skipping execution and NOT scheduling next")
                log("=== FlowVaultsEVM Scheduled Execution Skipped (Paused) ===")
                return
            }
            
            let worker = self.workerCap.borrow()
                ?? panic("Could not borrow Worker capability")
            
            let pendingRequestsBefore = self.getPendingRequestCount(worker)
            log("Pending Requests Before: ".concat(pendingRequestsBefore.toString()))
            
            worker.processRequests()
            
            let pendingRequestsAfter = self.getPendingRequestCount(worker)
            log("Pending Requests After: ".concat(pendingRequestsAfter.toString()))
            
            self.executionCount = self.executionCount + 1
            self.lastExecutionTime = getCurrentBlock().timestamp
            
            let delayLevel = FlowVaultsTransactionHandler.getDelayLevel(pendingRequestsAfter)
            let nextDelay = FlowVaultsTransactionHandler.DELAY_LEVELS[delayLevel]
            
            emit ScheduledExecutionTriggered(
                transactionId: id,
                pendingRequests: pendingRequestsAfter,
                delayLevel: delayLevel,
                nextExecutionDelay: nextDelay
            )
            
            // AUTO-SCHEDULE: Schedule the next execution based on remaining workload
            self.scheduleNextExecution(nextDelay: nextDelay, pendingRequests: pendingRequestsAfter)
            
            log("=== FlowVaultsEVM Scheduled Execution Complete ===")
        }
        
        /// Schedule the next execution automatically
        access(self) fun scheduleNextExecution(nextDelay: UFix64, pendingRequests: Int) {
            log("=== Auto-Scheduling Next Execution ===")
            
            let future = getCurrentBlock().timestamp + nextDelay
            let priority = FlowTransactionScheduler.Priority.Medium
            let executionEffort: UInt64 = 7499
            
            // Estimate fees for the next execution
            let estimate = FlowTransactionScheduler.estimate(
                data: nil,
                timestamp: future,
                priority: priority,
                executionEffort: executionEffort
            )
            
            // Validate the estimate
            assert(
                estimate.timestamp != nil || priority == FlowTransactionScheduler.Priority.Low,
                message: estimate.error ?? "estimation failed"
            )
            
            // Withdraw fees from contract account
            let vaultRef = FlowVaultsTransactionHandler.account.storage
                .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
                ?? panic("missing FlowToken vault on contract account")
            
            let fees <- vaultRef.withdraw(amount: estimate.flowFee ?? 0.0) as! @FlowToken.Vault
            
            // Get the manager from contract account storage
            let manager = FlowVaultsTransactionHandler.account.storage
                .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                    from: FlowTransactionSchedulerUtils.managerStoragePath
                )
                ?? panic("Could not borrow Manager reference from contract account")
            
            // Get the handler type identifier - use the first (and should be only) handler type
            let handlerTypeIdentifiers = manager.getHandlerTypeIdentifiers()
            assert(handlerTypeIdentifiers.keys.length > 0, message: "No handler types found in manager")
            let handlerTypeIdentifier = handlerTypeIdentifiers.keys[0]
            
            // Schedule using the existing handler
            let transactionId = manager.scheduleByHandler(
                handlerTypeIdentifier: handlerTypeIdentifier,
                handlerUUID: nil,
                data: nil,
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
            
            log("Next execution scheduled for: ".concat(future.toString()))
            log("Transaction ID: ".concat(transactionId.toString()))
            log("Delay: ".concat(nextDelay.toString()).concat(" seconds"))
            log("=== Auto-Scheduling Complete ===")
        }

        access(all) view fun getViews(): [Type] {
            return [Type<StoragePath>(), Type<PublicPath>()]
        }

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
            let requests = worker.getPendingRequestIdsFromEVM()
            return requests.length
        }
        
        access(all) fun getStats(): {String: AnyStruct} {
            return {
                "executionCount": self.executionCount,
                "lastExecutionTime": self.lastExecutionTime
            }
        }
    }

    // ========================================
    // Public Functions
    // ========================================
    
    access(all) fun createHandler(workerCap: Capability<&FlowVaultsEVM.Worker>): @Handler {
        return <- create Handler(workerCap: workerCap)
    }
    
    /// Determine delay level based on pending request count (5 levels)
    access(all) fun getDelayLevel(_ pendingCount: Int): Int {
        var level = 4 // Default to slowest
        
        var i = 0
        while i < FlowVaultsTransactionHandler.LOAD_THRESHOLDS.length {
            if pendingCount >= FlowVaultsTransactionHandler.LOAD_THRESHOLDS[i] {
                level = i
                break
            }
            i = i + 1
        }
        
        return level
    }
    
    access(all) fun getDelayForPendingCount(_ pendingCount: Int): UFix64 {
        let level = self.getDelayLevel(pendingCount)
        return self.DELAY_LEVELS[level]
    }
    
    access(all) fun isPausedState(): Bool {
        return self.isPaused
    }
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        self.HandlerStoragePath = /storage/FlowVaultsTransactionHandler
        self.HandlerPublicPath = /public/FlowVaultsTransactionHandler
        self.AdminStoragePath = /storage/FlowVaultsTransactionHandlerAdmin
        
        // Initialize as unpaused
        self.isPaused = false
        
        // 5 delay levels (simplified)
        self.DELAY_LEVELS = [
            5.0,   // Level 0: High load (>=50 requests) - 5s
            15.0,  // Level 1: Medium-high load (>=20 requests) - 15s
            30.0,  // Level 2: Medium load (>=10 requests) - 30s
            45.0,  // Level 3: Low load (>=5 requests) - 45s
            60.0   // Level 4: Very low/Idle (<5 requests) - 60s
        ]
        
        // 5 thresholds
        self.LOAD_THRESHOLDS = [
            50,   // Level 0: High load
            20,   // Level 1: Medium-high load
            10,   // Level 2: Medium load
            5,    // Level 3: Low load
            0     // Level 4: Very low/Idle
        ]
        
        // Create and save Admin resource
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
