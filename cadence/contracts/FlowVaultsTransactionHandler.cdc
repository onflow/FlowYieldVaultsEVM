import "FlowTransactionScheduler"
import "FlowVaultsEVM"

/// Handler contract for scheduled FlowVaultsEVM request processing
/// Intermediate version: 5 delay levels for simplicity
access(all) contract FlowVaultsTransactionHandler {

    // ========================================
    // Constants
    // ========================================
    
    access(all) let HandlerStoragePath: StoragePath
    access(all) let HandlerPublicPath: PublicPath
    
    /// 5 delay levels (in seconds)
    access(all) let DELAY_LEVELS: [UFix64]
    
    /// Thresholds for 5 delay levels (pending request counts)
    access(all) let LOAD_THRESHOLDS: [Int]
    
    // ========================================
    // Events
    // ========================================
    
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
            
            log("=== FlowVaultsEVM Scheduled Execution Complete ===")
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
            let requests = worker.getPendingRequestsFromEVM()
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
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        self.HandlerStoragePath = /storage/FlowVaultsTransactionHandler
        self.HandlerPublicPath = /public/FlowVaultsTransactionHandler
        
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
    }
}
