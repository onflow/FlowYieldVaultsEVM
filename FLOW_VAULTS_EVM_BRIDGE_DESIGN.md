# Flow Vaults Cross-VM Bridge: EVM ↔ Cadence Design Document

## Executive Summary

This document outlines the architecture for enabling Flow EVM users to interact with Flow Vaults's Cadence-based yield protocol through a scheduled cross-VM bridge pattern.

**Key Innovation**: EVM users deposit funds and submit requests to a Solidity contract, which are periodically processed by a Cadence worker that bridges funds and manages Tide positions on their behalf.

---

## Architecture Overview

### Components

#### 1. **FlowVaultsRequests** (Solidity - Flow EVM)
- **Purpose**: Request queue and fund escrow for EVM users
- **Location**: Flow EVM
- **Responsibilities**:
  - Accept user requests (CREATE_TIDE, DEPOSIT, WITHDRAW, CLOSE)
  - Escrow native $FLOW and ERC-20 tokens
  - Track per-user request queues
  - Track escrowed funds awaiting processing (not actual Tide balances)
  - Only allow fund withdrawals by the authorized COA

#### 2. **FlowVaultsEVM** (Cadence)
- **Purpose**: Scheduled processor that executes EVM user requests on Cadence
- **Location**: Flow Cadence
- **Responsibilities**:
  - Poll FlowVaultsRequests contract at regular intervals (e.g., every 2 minutes or 1 hour)
  - Own and control the COA resource
  - Bridge funds between EVM and Cadence
  - Create and manage Tide positions tagged by EVM user address
  - Update request statuses and user balances in FlowVaultsRequests
  - Emit events for traceability

#### 3. **COA (Cadence Owned Account)**
- **Purpose**: Bridge account controlled by FlowVaultsEVM
- **Ownership**: FlowVaultsEVM holds the resource
- **Responsibilities**:
  - Withdraw funds from FlowVaultsRequests (via Solidity `onlyAuthorizedCOA` modifier)
  - Bridge funds from EVM to Cadence
  - Bridge funds from Cadence back to EVM for withdrawals (directly and atomically to user's EVM address)


![Flow Vaults EVM Bridge Design](./create_tide.png)

*This diagram illustrates the complete flow for creating a new position (tide), from the user's initial request in the EVM environment through to the creation of the tide in Cadence.*

---

## Data Structures

### FlowVaultsRequests (Solidity)

```solidity
contract FlowVaultsRequests {
    // ============================================
    // Constants
    // ============================================

    /// @notice Special address representing native $FLOW (similar to 1inch approach)
    /// @dev Using recognizable pattern instead of address(0) for clarity
    address public constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // ============================================
    // Enums
    // ============================================

    enum RequestType {
        CREATE_TIDE,
        DEPOSIT_TO_TIDE,
        WITHDRAW_FROM_TIDE,
        CLOSE_TIDE
    }

    enum RequestStatus {
        PENDING,
        PROCESSING,
        COMPLETED,
        FAILED
    }

    // ============================================
    // Structs
    // ============================================

    struct Request {
        uint256 id;
        address user;
        RequestType requestType;
        RequestStatus status;
        address tokenAddress;
        uint256 amount;
        uint64 tideId; // Only used for DEPOSIT/WITHDRAW/CLOSE
        uint256 timestamp;
        string message; // Error/status message (especially for failures)
    }

    // ============================================
    // State Variables
    // ============================================

    /// @notice Auto-incrementing request ID counter
    uint256 private _requestIdCounter;

    /// @notice Authorized COA address (controlled by FlowVaultsEVM)
    address public authorizedCOA;

    /// @notice Owner of the contract (for admin functions)
    address public owner;

    /// @notice User request history: user address => array of requests
    mapping(address => Request[]) public userRequests;

    /// @notice Pending user balances: user address => token address => balance
    /// @dev Tracks escrowed funds in the EVM contract awaiting processing
    /// Does NOT track actual Tide balances on Cadence side
    mapping(address => mapping(address => uint256)) public pendingUserBalances;

    /// @notice Pending requests for efficient worker processing
    mapping(uint256 => Request) public pendingRequests;
    uint256[] public pendingRequestIds;

    // ============================================
    // Events
    // ============================================

    event RequestCreated(
        uint256 indexed requestId,
        address indexed user,
        RequestType requestType,
        address indexed tokenAddress,
        uint256 amount,
        uint64 tideId
    );

    event RequestProcessed(
        uint256 indexed requestId,
        RequestStatus status,
        uint64 tideId,
        string message
    );

    event BalanceUpdated(
        address indexed user,
        address indexed tokenAddress,
        uint256 newBalance
    );

    event FundsWithdrawn(
        address indexed to,
        address indexed tokenAddress,
        uint256 amount
    );

    event AuthorizedCOAUpdated(address indexed oldCOA, address indexed newCOA);

    // ============================================
    // Modifiers
    // ============================================

    modifier onlyAuthorizedCOA() {
        require(
            msg.sender == authorizedCOA,
            "FlowVaultsRequests: caller is not authorized COA"
        );
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "FlowVaultsRequests: caller is not owner");
        _;
    }

    // ============================================
    // Key Functions
    // ============================================

    /// @notice Create a new Tide (deposit funds to create position)
    function createTide(address tokenAddress, uint256 amount) external payable returns (uint256);

    /// @notice Withdraw from existing Tide
    function withdrawFromTide(uint64 tideId, uint256 amount) external returns (uint256);

    /// @notice Close Tide and withdraw all funds
    function closeTide(uint64 tideId) external returns (uint256);

    /// @notice Withdraw funds from contract (only authorized COA)
    function withdrawFunds(address tokenAddress, uint256 amount) external onlyAuthorizedCOA;

    /// @notice Update request status (only authorized COA)
    function updateRequestStatus(uint256 requestId, RequestStatus status, uint64 tideId, string memory message) external onlyAuthorizedCOA;

    /// @notice Update user balance (only authorized COA)
    function updateUserBalance(address user, address tokenAddress, uint256 newBalance) external onlyAuthorizedCOA;

    /// @notice Get pending requests unpacked (for Cadence decoding)
    function getPendingRequestsUnpacked() external view returns (
        uint256[] memory ids,
        address[] memory users,
        uint8[] memory requestTypes,
        uint8[] memory statuses,
        address[] memory tokenAddresses,
        uint256[] memory amounts,
        uint64[] memory tideIds,
        uint256[] memory timestamps,
        string[] memory messages
    );

    /// @notice Helper function to check if token is native FLOW
    function isNativeFlow(address token) public pure returns (bool) {
        return token == NATIVE_FLOW;
    }
}
```

### FlowVaultsEVM (Cadence)

```cadence
access(all) contract FlowVaultsEVM {
    
    // ========================================
    // Paths
    // ========================================
    
    access(all) let WorkerStoragePath: StoragePath
    access(all) let WorkerPublicPath: PublicPath
    access(all) let AdminStoragePath: StoragePath
    
    // ========================================
    // State
    // ========================================
    
    /// Mapping of EVM addresses (as hex strings) to their Tide IDs
    /// Example: "0x1234..." => [1, 5, 12]
    access(all) let tidesByEVMAddress: {String: [UInt64]}
    
    /// FlowVaultsRequests contract address on EVM side
    /// Can only be set by Admin
    access(all) var flowVaultsRequestsAddress: EVM.EVMAddress?
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event WorkerInitialized(coaAddress: String)
    access(all) event FlowVaultsRequestsAddressSet(address: String)
    access(all) event RequestsProcessed(count: Int, successful: Int, failed: Int)
    access(all) event TideCreatedForEVMUser(evmAddress: String, tideId: UInt64, amount: UFix64)
    access(all) event TideClosedForEVMUser(evmAddress: String, tideId: UInt64, amountReturned: UFix64)
    access(all) event RequestFailed(requestId: UInt256, reason: String)

    // ========================================
    // Structs
    // ========================================
    
    /// Represents a request from EVM side
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
        
        init(
            id: UInt256,
            user: EVM.EVMAddress,
            requestType: UInt8,
            status: UInt8,
            tokenAddress: EVM.EVMAddress,
            amount: UInt256,
            tideId: UInt64,
            timestamp: UInt256,
            message: String
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
    
    /// Admin capability for managing the bridge
    /// Only the contract account should hold this
    access(all) resource Admin {
        access(all) fun setFlowVaultsRequestsAddress(_ address: EVM.EVMAddress)
        
        /// Create a new Worker with a capability instead of reference
        access(all) fun createWorker(
            coa: @EVM.CadenceOwnedAccount, 
            betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>
        ): @Worker
    }
    
    // ========================================
    // Worker Resource
    // ========================================
    
    access(all) resource Worker {
        /// COA resource for cross-VM operations
        access(self) let coa: @EVM.CadenceOwnedAccount
        
        /// TideManager to hold Tides for EVM users
        access(self) let tideManager: @FlowVaults.TideManager
        
        /// Capability to beta badge (instead of reference)
        access(self) let betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>
        
        /// Get COA's EVM address as string
        access(all) fun getCOAAddressString(): String
        
        /// Process all pending requests from FlowVaultsRequests contract
        access(all) fun processRequests()
        
        /// Process CREATE_TIDE request
        access(self) fun processCreateTide(_ request: EVMRequest): ProcessResult
        
        /// Process CLOSE_TIDE request
        access(self) fun processCloseTide(_ request: EVMRequest): ProcessResult
        
        /// Withdraw funds from FlowVaultsRequests contract via COA
        access(self) fun withdrawFundsFromEVM(amount: UFix64): @{FungibleToken.Vault}
        
        /// Bridge funds from Cadence back to EVM user (atomic)
        access(self) fun bridgeFundsToEVMUser(vault: @{FungibleToken.Vault}, recipient: EVM.EVMAddress)
        
        /// Update request status in FlowVaultsRequests
        access(self) fun updateRequestStatus(requestId: UInt256, status: UInt8, tideId: UInt64, message: String)
        
        /// Update user balance in FlowVaultsRequests
        access(self) fun updateUserBalance(user: EVM.EVMAddress, tokenAddress: EVM.EVMAddress, newBalance: UInt256)
        
        /// Get pending requests from FlowVaultsRequests contract
        access(all) fun getPendingRequestsFromEVM(): [EVMRequest]
    }
    
    // ========================================
    // Public Functions
    // ========================================
    
    /// Get Tide IDs for an EVM address
    access(all) fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64]
    
    /// Get FlowVaultsRequests address (read-only)
    access(all) fun getFlowVaultsRequestsAddress(): EVM.EVMAddress?

    /// Helper: Convert UInt256 (18 decimals) to UFix64 (8 decimals)
    access(self) fun ufix64FromUInt256(_ value: UInt256): UFix64

    /// Helper: Convert UFix64 (8 decimals) to UInt256 (18 decimals)
    access(self) fun uint256FromUFix64(_ value: UFix64): UInt256
}
```

---

## Request Flow Diagrams

### 1. CREATE_TIDE Flow

```
EVM User A                FlowVaultsRequests          FlowVaultsEVM           FlowVaults         FlowScheduler
    |                          |                       |                      |                    |
    |                          |                       |                      |                    |
    | 1. createRequest()       |                       |                      |                    |
    |--(NATIVE_FLOW, 1.0)----->|                       |                      |                    |
    |    + 1.0 $FLOW           |                       |                      |                    |
    |                          |                       |                      |                    |
    | 2. Store request         |                       |                      |                    |
    |    in userRequests       |                       |                      |                    |
    |    mapping               |                       |                      |                    |
    |                          |                       |                      |                    |
    | 3. Update userBalances   |                       |                      |                    |
    |    [userA][NATIVE_FLOW]  |                       |                      |                    |
    |    += 1.0                |                       |                      |                    |
    |                          |                       |                      |                    |
    | 4. Add to pending queue  |                       |                      |                    |
    |    pendingRequestIds[]   |                       |                      |                    |
    |                          |                       |                      |                    |
    |<-----RequestCreated------|                       |                      |                    |
    |     event (id=1)         |                       |                      |                    |
    |                          |                       |                      |                    |
    |                          |                       |<-- 5. SCHEDULED TXN ---|                   |
    |                          |                       |    Every X minutes   |                   |
    |                          |                       |    (e.g. 2min/1hr)   |                   |
    |                          |                       |                      |                    |
    |                          | 6. getPendingRequests()|                     |                    |
    |                          |<----------------------|                      |                    |
    |                          |                       |                      |                    |
    |                          |---[Request{id=1}]---->|                      |                    |
    |                          |                       |                      |                    |
    |                          |                       | 7. Mark PROCESSING   |                    |
    |                          |<--updateRequestStatus-|                      |                    |
    |                          |   (id=1, PROCESSING)  |                      |                    |
    |                          |                       |                      |                    |
    |                          | 8. withdrawFunds()    |                      |                    |
    |                          |<--(NATIVE_FLOW, 1.0)--|                      |                    |
    |                          |    via COA (authorized)|                     |                    |
    |                          |                       |                      |                    |
    |                          |---1.0 FLOW transfer-->|                      |                    |
    |                          |   to COA EVM address  |                      |                    |
    |                          |                       |                      |                    |
    |                          |                       | 9. COA.withdraw()    |                    |
    |                          |                       |    EVM → Cadence     |                    |
    |                          |                       |                      |                    |
    |                          |                       |<--@FlowToken.Vault---|                    |
    |                          |                       |   (1.0 FLOW)         |                    |
    |                          |                       |                      |                    |
    |                          |                       | 10. createTide()     |                    |
    |                          |                       |---(strategyType)---->|                    |
    |                          |                       |  + vault (1.0 FLOW)  |                    |
    |                          |                       |                      |                    |
    |                          |                       |                      | 11. Create Tide    |
    |                          |                       |                      |     resource       |
    |                          |                       |                      |     with strategy  |
    |                          |                       |                      |                    |
    |                          |                       | 12. Store Tide       |                    |
    |                          |                       |<--Tide (id=42)-------|                    |
    |                          |                       |                      |                    |
    |                          |                       | 13. Map in storage:  |                    |
    |                          |                       |     tidesByEVMAddr   |                    |
    |                          |                       |     [userA] = [42]   |                    |
    |                          |                       |                      |                    |
    |                          | 14. Update balance    |                      |                    |
    |                          |<--updateUserBalance---|                      |                    |
    |                          |   (userA, NATIVE_FLOW,|                      |                    |
    |                          |    newBalance=0)      |                      |                    |
    |                          |                       |                      |                    |
    |<--BalanceUpdated---------|                       |                      |                    |
    |   event (userA, 0)       |                       |                      |                    |
    |                          |                       |                      |                    |
    |                          | 15. Mark COMPLETED    |                      |                    |
    |                          |<--updateRequestStatus-|                      |                    |
    |                          |   (id=1, COMPLETED,   |                      |                    |
    |                          |    tideId=42)         |                      |                    |
    |                          |                       |                      |                    |
    |                          | 16. Remove from       |                      |                    |
    |                          |     pending queue     |                      |                    |
    |                          |                       |                      |                    |
    |<--RequestProcessed-------|                       |                      |                    |
    |   event (id=1,           |                       |                      |                    |
    |          COMPLETED,      |                       |                      |                    |
    |          tideId=42)      |                       |                      |                    |
    |                          |                       |                      |                    |
    | ✅ User can now query    |                       |                      |                    |
    |    their Tide ID: 42     |                       |                      |                    |
```

### 2. WITHDRAW_FROM_TIDE Flow

```
EVM User A                FlowVaultsRequests          FlowVaultsEVM           FlowVaults         FlowScheduler
    |                          |                       |                      |                    |
    | 1. createRequest()       |                       |                      |                    |
    |--(WITHDRAW, 0.5, tid=42)-|                       |                      |                    |
    |    no FLOW sent          |                       |                      |                    |
    |                          |                       |                      |                    |
    | 2. Store request         |                       |                      |                    |
    |    requestType=WITHDRAW  |                       |                      |                    |
    |    tideId=42, amount=0.5 |                       |                      |                    |
    |                          |                       |                      |                    |
    | 3. Add to pending queue  |                       |                      |                    |
    |                          |                       |                      |                    |
    |<-----RequestCreated------|                       |                      |                    |
    |     event (id=2)         |                       |                      |                    |
    |                          |                       |                      |                    |
    |                          |                       |<-- 4. SCHEDULED TXN ---|                   |
    |                          |                       |    (next interval)   |                   |
    |                          |                       |                      |                    |
    |                          | 5. getPendingRequests()|                     |                    |
    |                          |<----------------------|                      |                    |
    |                          |---[Request{id=2}]---->|                      |                    |
    |                          |                       |                      |                    |
    |                          |                       | 6. Validate request  |                    |
    |                          |                       |    Check tideId=42   |                    |
    |                          |                       |    exists for userA  |                    |
    |                          |                       |                      |                    |
    |                          | 7. Mark PROCESSING    |                      |                    |
    |                          |<--updateRequestStatus-|                      |                    |
    |                          |   (id=2, PROCESSING)  |                      |                    |
    |                          |                       |                      |                    |
    |                          |                       | 8. withdrawFromTide()|                    |
    |                          |                       |---(tideId=42, 0.5)-->|                    |
    |                          |                       |                      |                    |
    |                          |                       |                      | 9. Withdraw from   |
    |                          |                       |                      |    Tide resource   |
    |                          |                       |                      |    Update balance  |
    |                          |                       |                      |                    |
    |                          |                       |<--@FlowToken.Vault---|                    |
    |                          |                       |   (0.5 FLOW)         |                    |
    |                          |                       |                      |                    |
    |                          |                       | 10. Get user's EVM   |                    |
    |                          |                       |     address from     |                    |
    |                          |                       |     request          |                    |
    |                          |                       |                      |                    |
    |                          |                       | 11. recipientAddress |                    |
    |                          |                       |     .deposit()       |                    |
    |                          |                       |     Cadence → EVM    |                    |
    |                          |                       |     (ATOMIC!)        |                    |
    |                          |                       |                      |                    |
    |<----0.5 FLOW received----|                       |                      |                    |
    |     directly to wallet   |                       |                      |                    |
    |                          |                       |                      |                    |
    |                          | 12. Optional: Update  |                      |                    |
    |                          |     accounting        |                      |                    |
    |                          |<--updateUserBalance---|                      |                    |
    |                          |   (userA, NATIVE_FLOW,|                      |                    |
    |                          |    decreased)         |                      |                    |
    |                          |                       |                      |                    |
    |<--BalanceUpdated---------|                       |                      |                    |
    |   event (if needed)      |                       |                      |                    |
    |                          |                       |                      |                    |
    |                          | 13. Mark COMPLETED    |                      |                    |
    |                          |<--updateRequestStatus-|                      |                    |
    |                          |   (id=2, COMPLETED)   |                      |                    |
    |                          |                       |                      |                    |
    |                          | 14. Remove from       |                      |                    |
    |                          |     pending queue     |                      |                    |
    |                          |                       |                      |                    |
    |<--RequestProcessed-------|                       |                      |                    |
    |   event (id=2,           |                       |                      |                    |
    |          COMPLETED)      |                       |                      |                    |
    |                          |                       |                      |                    |
    | ✅ User received 0.5 FLOW|                       |                      |                    |
    |    in their EVM wallet   |                       |                      |                    |
```

---

## Flow Scheduled Transactions Integration

### Overview

The FlowVaultsEVM uses **Flow's scheduled transaction capability** to periodically process pending requests from the EVM side. This is a key architectural component that enables the asynchronous bridge pattern.

### Scheduling Mechanism

The scheduling mechanism uses Flow's built-in scheduled transaction system with a **handler pattern** that stores a capability to the Worker resource.

#### 1. FlowVaultsTransactionHandler Contract

First, create a handler contract that implements the `FlowTransactionScheduler.TransactionHandler` interface:

```cadence
import "FlowTransactionScheduler"
import "FlowVaultsEVM"

access(all) contract FlowVaultsTransactionHandler {

    /// Handler resource that implements the Scheduled Transaction interface
    access(all) resource Handler: FlowTransactionScheduler.TransactionHandler {
        
        /// Capability to the FlowVaultsEVM Worker
        /// This is stored in the handler to avoid direct storage borrowing
        access(self) let workerCap: Capability<&FlowVaultsEVM.Worker>
        
        init(workerCap: Capability<&FlowVaultsEVM.Worker>) {
            self.workerCap = workerCap
        }
        
        /// Called automatically by the scheduler
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let worker = self.workerCap.borrow()
                ?? panic("Could not borrow Worker capability")
            
            // Execute the actual processing logic
            worker.processRequests()
            
            log("FlowVaultsEVM scheduled transaction executed (id: ".concat(id.toString()).concat(")"))
        }

        access(all) view fun getViews(): [Type] {
            return [Type<StoragePath>(), Type<PublicPath>()]
        }

        access(all) fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<StoragePath>():
                    return /storage/FlowVaultsTransactionHandler
                case Type<PublicPath>():
                    return /public/FlowVaultsTransactionHandler
                default:
                    return nil
            }
        }
    }

    /// Factory for the handler resource
    access(all) fun createHandler(workerCap: Capability<&FlowVaultsEVM.Worker>): @Handler {
        return <- create Handler(workerCap: workerCap)
    }
}
```

#### 2. Initialize Handler (One-time Setup)

```cadence
import "FlowVaultsTransactionHandler"
import "FlowTransactionScheduler"
import "FlowVaultsEVM"

transaction() {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability) &Account) {
        // Create a capability to the Worker
        let workerCap = signer.capabilities.storage
            .issue<&FlowVaultsEVM.Worker>(FlowVaultsEVM.WorkerStoragePath)
        
        // Create and save the handler with the worker capability
        if signer.storage.borrow<&AnyResource>(from: /storage/FlowVaultsTransactionHandler) == nil {
            let handler <- FlowVaultsTransactionHandler.createHandler(workerCap: workerCap)
            signer.storage.save(<-handler, to: /storage/FlowVaultsTransactionHandler)
        }

        // Issue an entitled capability for the scheduler to call executeTransaction
        let _ = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(/storage/FlowVaultsTransactionHandler)

        // Issue a public capability for general access
        let publicCap = signer.capabilities.storage
            .issue<&{FlowTransactionScheduler.TransactionHandler}>(/storage/FlowVaultsTransactionHandler)
        signer.capabilities.publish(publicCap, at: /public/FlowVaultsTransactionHandler)
    }
}
```

#### 3. Schedule the Recurring Transaction

```cadence
import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowToken"
import "FungibleToken"

/// Schedule FlowVaultsEVM request processing at a future timestamp
transaction(
    delaySeconds: UFix64,        // e.g., 120.0 for 2 minutes
    priority: UInt8,             // 0=High, 1=Medium, 2=Low
    executionEffort: UInt64      // Must be >= 10, recommend 1000+
) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue, GetStorageCapabilityController, PublishCapability) &Account) {
        let future = getCurrentBlock().timestamp + delaySeconds

        let pr = priority == 0
            ? FlowTransactionScheduler.Priority.High
            : priority == 1
                ? FlowTransactionScheduler.Priority.Medium
                : FlowTransactionScheduler.Priority.Low

        // Get the entitled handler capability
        var handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>? = nil
        let controllers = signer.capabilities.storage.getControllers(forPath: /storage/FlowVaultsTransactionHandler)
        
        for controller in controllers {
            if let cap = controller.capability as? Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}> {
                handlerCap = cap
                break
            }
        }

        // Initialize manager if not present
        if signer.storage.borrow<&AnyResource>(from: FlowTransactionSchedulerUtils.managerStoragePath) == nil {
            let manager <- FlowTransactionSchedulerUtils.createManager()
            signer.storage.save(<-manager, to: FlowTransactionSchedulerUtils.managerStoragePath)

            let managerCapPublic = signer.capabilities.storage
                .issue<&{FlowTransactionSchedulerUtils.Manager}>(FlowTransactionSchedulerUtils.managerStoragePath)
            signer.capabilities.publish(managerCapPublic, at: FlowTransactionSchedulerUtils.managerPublicPath)
        }

        // Borrow the manager
        let manager = signer.storage
            .borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
                from: FlowTransactionSchedulerUtils.managerStoragePath
            ) ?? panic("Could not borrow Manager")

        // Estimate and withdraw fees
        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Missing FlowToken vault")

        let est = FlowTransactionScheduler.estimate(
            data: nil,
            timestamp: future,
            priority: pr,
            executionEffort: executionEffort
        )

        let fees <- vaultRef.withdraw(amount: est.flowFee ?? 0.0) as! @FlowToken.Vault

        // Schedule the transaction
        let transactionId = manager.schedule(
            handlerCap: handlerCap ?? panic("Could not get handler capability"),
            data: nil,
            timestamp: future,
            priority: pr,
            executionEffort: executionEffort,
            fees: <-fees
        )

        log("Scheduled FlowVaultsEVM processing (id: "
            .concat(transactionId.toString())
            .concat(") at ")
            .concat(future.toString()))
    }
}
```

**Key Architecture Points:**
- The **Handler** stores a capability to the Worker (not a direct reference)
- The **scheduled transaction** calls the Handler through its entitled capability
- The **Handler** uses its stored Worker capability to execute `processRequests()`
- This pattern enables proper separation of concerns and follows Flow best practices

---

## Smart Dynamic Scheduling for Scale

### Problem Statement

As discussed with Joshua, processing all requests in a single scheduled transaction is problematic:
- Each EVM call consumes significant gas
- Gas limits restrict the number of requests processable per transaction
- High user volume could lead to request backlogs
- **We should not assume unlimited capacity** - must design with batch limits from day one

### Solution: Self-Scheduling with Adaptive Frequency

Instead of assuming unlimited capacity, the system uses a **self-scheduling pattern** where:
1. Each execution processes a **fixed maximum** number of requests (e.g., 10, determined by gas benchmarking)
2. After processing, the handler **checks remaining queue depth**
3. The handler **schedules its own next execution** with adaptive timing based on load

### Implementation

#### 1. Batch Processing Constant

```cadence
access(all) contract FlowVaultsEVM {
    /// Maximum requests to process per transaction (determined by gas benchmarking)
    access(all) let MAX_REQUESTS_PER_TX: Int
    
    init() {
        // ... other initialization ...
        self.MAX_REQUESTS_PER_TX = 10 // Set based on testing
    }
}
```

#### 2. Modified Worker.processRequests()

```cadence
access(all) fun processRequests() {
    pre {
        FlowVaultsEVM.flowVaultsRequestsAddress != nil: "FlowVaultsRequests address not set"
    }
    
    // 1. Get pending requests from FlowVaultsRequests
    let allRequests = self.getPendingRequestsFromEVM()
    
    // 2. Process only up to MAX_REQUESTS_PER_TX
    let batchSize = allRequests.length < FlowVaultsEVM.MAX_REQUESTS_PER_TX 
        ? allRequests.length 
        : FlowVaultsEVM.MAX_REQUESTS_PER_TX
    
    var successCount = 0
    var failCount = 0
    var i = 0
    
    while i < batchSize {
        let success = self.processRequestSafely(allRequests[i])
        if success {
            successCount = successCount + 1
        } else {
            failCount = failCount + 1
        }
        i = i + 1
    }
    
    emit RequestsProcessed(count: batchSize, successful: successCount, failed: failCount)
    
    // 3. Schedule next execution based on remaining queue depth
    let remainingRequests = allRequests.length - batchSize
    self.scheduleNextExecution(remainingCount: remainingRequests)
}
```

#### 3. Adaptive Scheduling Logic

```cadence
access(self) fun scheduleNextExecution(remainingCount: Int) {
    // Determine delay based on queue depth
    let delay: UFix64
    
    if remainingCount > 50 {
        // High load: process again in 10 seconds
        delay = 10.0
    } else if remainingCount > 0 {
        // Normal load: process again in 2 minutes
        delay = 120.0
    } else {
        // Empty queue: check again in 1 hour
        delay = 3600.0
    }
    
    // Calculate future timestamp
    let nextRunTime = getCurrentBlock().timestamp + delay
    
    // Get scheduler manager and fees
    let manager = // ... borrow manager from contract account
    let vaultRef = // ... borrow vault from contract account
    
    // Estimate fees
    let est = FlowTransactionScheduler.estimate(
        data: nil,
        timestamp: nextRunTime,
        priority: FlowTransactionScheduler.Priority.Medium,
        executionEffort: 5000
    )
    
    let fees <- vaultRef.withdraw(amount: est.flowFee ?? 0.0)
    
    // Schedule next run
    let transactionId = manager.schedule(
        handlerCap: self.getHandlerCapability(),
        data: nil,
        timestamp: nextRunTime,
        priority: FlowTransactionScheduler.Priority.Medium,
        executionEffort: 5000,
        fees: <-fees
    )
    
    log("Scheduled next execution (id: "
        .concat(transactionId.toString())
        .concat(") for ")
        .concat(nextRunTime.toString())
        .concat(" with ")
        .concat(remainingCount.toString())
        .concat(" requests remaining"))
}
```

#### 4. Get Pending Count (New Function)

Add to FlowVaultsRequests Solidity contract:

```solidity
/// @notice Get count of pending requests (gas-efficient)
function getPendingRequestCount() external view returns (uint256) {
    return pendingRequestIds.length;
}
```

The Worker can call this for lightweight queue depth checks without fetching all request data.

### Scaling Characteristics

| Queue Depth | Delay | Processing Rate | Use Case |
|-------------|-------|-----------------|----------|
| 0 requests | 1 hour | Minimal overhead | Low activity periods |
| 1-50 requests | 2 minutes | Normal processing | Regular usage |
| 50+ requests | 10 seconds | High-throughput mode | Peak demand |

### Benefits

1. **Gas Efficiency**: Each transaction stays well under gas limits
2. **Fully Autonomous**: No off-chain monitoring needed - system scales itself
3. **Adaptive**: Automatically scales processing frequency with demand
4. **Cost-Effective**: Reduces scheduled transaction fees during low usage
5. **Predictable**: Fixed batch size makes gas usage predictable
6. **No Assumption of Unlimited Capacity**: Built with scaling constraints from day one

### Trade-offs

- **Processing Delay**: Users may wait up to MAX_DELAY (e.g., 1 hour) for processing during low activity
- **Complexity**: More sophisticated than simple fixed-interval scheduling

### Failover & Reliability

**What if scheduled transaction fails?**

1. **Automatic Retry:** Flow will retry failed scheduled transactions
2. **Circuit Breaker:** Pause scheduling if failure rate > threshold
3. **Manual Intervention:** Admin can trigger manual processing
4. **Fallback Queue:** Requests remain in EVM contract until processed

```cadence
access(all) fun processRequests() {
    // Check circuit breaker
    if self.isCircuitBroken() {
        emit ScheduledExecutionSkipped(reason: "Circuit breaker active")
        return
    }
    
    // Attempt processing with error recovery
    self.processWithErrorRecovery()
}
```

### Failure Event Emission

When a request fails during processing, the system emits detailed events for monitoring and debugging:

```cadence
access(all) event RequestFailed(
    requestId: UInt256, 
    reason: String
)
```

---

### 1. **Request Queue Pattern**
- **Decision**: Use a pull-based model where FlowVaultsEVM polls for requests
- **Rationale**: 
  - fully on-chain no off-chain event listeners
  - Worker can process multiple requests in one transaction (if gas < 9999, need some tests to estimate)

### 2. **Fund Escrow in FlowVaultsRequests**
- **Decision**: Funds remain in FlowVaultsRequests until processed
- **Rationale**:
  - Security: Only authorized COA can withdraw
  - Transparency: Easy to audit locked funds
  - Rollback safety: Failed requests don't lose funds

### 3. **Separated State Management Across VMs**
- **Decision**: Each VM maintains its own relevant state independently
  - **EVM (FlowVaultsRequests)**: Tracks escrowed funds awaiting processing via `userBalances`
  - **Cadence (FlowVaultsEVM)**: Holds actual Tide positions and real-time balances
- **Rationale**:
  - The Solidity contract cannot track real-time Tide balances from Cadence
  - Maintaining duplicate state across VMs is neither necessary nor feasible given the asynchronous bridge design
  - Users query each side independently:
    - EVM queries show funds in escrow (pending processing)
    - Cadence queries show actual Tide positions and current balances
  - Simpler architecture without cross-VM synchronization complexity

### 4. **Tide Storage by EVM Address**
- **Decision**: Store Tides in FlowVaultsEVM tagged by EVM address string
- **Rationale**:
  - Clear ownership mapping
  - Efficient lookups for subsequent operations
  - Supports multiple Tides per user

### 5. **Native $FLOW vs ERC-20 Tokens**
- **Decision**: Use a constant address `NATIVE_FLOW` for native token
- **Rationale**:
  - Follows DeFi best practices (similar to 1inch, Uniswap, etc.)
  - Address pattern: `0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF` (recognizable)
  - Different transfer mechanisms (native value transfer vs ERC-20 transferFrom)
  - Can conditionally integrate Flow EVM Bridge for ERC-20s

---

## Balance Query Architecture

### Separated State Model

The bridge maintains **independent state on each VM** rather than attempting real-time synchronization:

#### EVM Side (FlowVaultsRequests)
```solidity
// Query escrowed funds awaiting processing
function getUserBalance(address user, address token) external view returns (uint256) {
    return pendingUserBalances[user][token];
}
```

**Use case**: Check how much FLOW a user has deposited but not yet processed into a Tide

#### Cadence Side (FlowVaultsEVM / FlowVaults)
```cadence
// Query actual Tide positions and balances
access(all) fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64]

// Users can then query individual Tide details through FlowVaults
access(all) fun getTideBalance(tideId: UInt64): UFix64
```

**Use case**: Check actual Tide positions and their current balances including any yield earned

### User Experience

Users need to query **both sides** to get a complete picture:

1. **Pending/Escrowed**: Query EVM contract for funds awaiting processing
2. **Active Positions**: Query Cadence for actual Tide balances

**Frontend Integration**: 
- Aggregate queries from both VMs in the UI
- Show combined view: "Pending: X FLOW | Active in Tides: Y FLOW"
- Use events to track state transitions

**No Cross-VM Balance Sync**: The asynchronous nature of the bridge makes real-time balance synchronization impractical and unnecessary. Each VM is the source of truth for its domain.

---

## Outstanding Questions & Alignment Needed

### 1. **Multi-Token Support**
- **Question**: When do we integrate the Flow EVM Bridge for ERC-20 tokens?
  - Phase 1: Native $FLOW only
  - Phase 2: ERC-20 support via bridge
- **Question**: How do we handle token allow list?
  - Which tokens from the Cadence side are supported?
- **Alignment**: "We can conditionally incorporate the EVM bridge with the already onboarded tokens on the Cadence side"

### 2. **Request Lifecycle & Timeouts**
- **Question**: Can users cancel pending requests?

### 3. **Balance Queries**
- **Clarification**: The system maintains separated state:
  - EVM users query `FlowVaultsRequests.getUserBalance()` for escrowed funds awaiting processing
  - For actual Tide balances, users must query Cadence directly (e.g., via read-only Cadence scripts)
  - No real-time cross-VM balance synchronization
- **Question**: Should we provide a unified balance query interface that aggregates both?
  - Potential solution: Off-chain indexer or frontend aggregation

### 4. **State Consistency**
- **Question**: What happens if FlowVaultsEVM updates Cadence state but fails to update FlowVaultsRequests?
  - Retry mechanism?
  - Manual reconciliation?

### 5. **Multi-Tide Management**
- **Question**: How do users specify which Tide to interact with for deposits/withdrawals?
  - Request includes tideId parameter
  - Automatic selection (e.g., newest Tide)
- **Question**: Limits on Tides per user?

---

## Security Considerations

### Access Control
1. **COA Authorization**: Only FlowVaultsEVM can control the COA
2. **Withdrawal Authorization**: Only COA can withdraw from FlowVaultsRequests
3. **Tide Ownership**: Tides are tagged by EVM address and non-transferable
4. **Request Validation**: Prevent duplicate processing of requests

### Fund Safety
1. **Escrow Security**: Funds locked until successful processing
2. **Rollback Protection**: Failed operations don't lose funds

### Unbounded Array Risk (Tide Storage)

**Problem**: The current design stores all Tide IDs per user in an array (`tidesByEVMAddress: {String: [UInt64]}`). If a user creates many Tides, this array could grow unbounded, causing:
- **Iteration Issues**: Operations that verify Tide ownership must iterate through the array
- **Gas/Computation Limits**: Large arrays could exceed transaction limits
- **Locked Funds**: User funds could be stuck if array becomes too large to process

---

## Implementation Phases

### Phase 1: MVP (Native $FLOW only)
- Deploy FlowVaultsRequests contract to Flow EVM
- Deploy FlowVaultsEVM to Cadence
- Support CREATE_TIDE and CLOSE_TIDE operations
- Manual trigger for processRequests()

### Phase 2: Full Operations
- Add DEPOSIT_TO_TIDE and WITHDRAW_FROM_TIDE
- Automated scheduled processing
- Event tracing and monitoring

### Phase 3: Multi-Token Support
- Integrate Flow EVM Bridge for ERC-20 tokens
- Token allow list system
- Multi-token balance tracking

### Phase 4: Optimization & Scale
- Request prioritization
- Batch processing optimization
- Advanced error handling and reconciliation

---

## Testings

### Integration Tests
- End-to-end CREATE_TIDE flow
- End-to-end WITHDRAW flow
- Multi-request batching
- Error scenarios and rollbacks

### Stress Tests
- Maximum requests per transaction
- Computation limit analysis

---

## Comparison with Existing FlowVaults Transactions

The Cadence transactions provided (`create_tide.cdc`, `deposit_to_tide.cdc`, `withdraw_from_tide.cdc`, `close_tide.cdc`) demonstrate the native Cadence flow. Key differences in the EVM bridge approach:

| Aspect | Native Cadence | EVM Bridge |
|--------|----------------|------------|
| User Identity | Flow account with BetaBadge | EVM address |
| Transaction Signer | User's Flow account | FlowVaultsEVM (on behalf of user) |
| Fund Source | User's Cadence vault | FlowVaultsRequests escrow |
| Tide Storage | User's TideManager | FlowVaultsEVM (tagged by EVM address) |
| Processing | Immediate (single txn) | Asynchronous (scheduled polling) |
| Beta Access | User holds BetaBadge | COA/Worker holds BetaBadge |

---

## Next Steps

1. **Alignment Meeting**: Review this document with Navid and Kan to resolve outstanding questions
2. **Technical Specification**: Detailed function signatures and state machine diagrams
3. **Prototype Development**: Implement Phase 1 MVP on testnet
4. **Security Audit**: Review design with security team before mainnet deployment
5. **Documentation**: User-facing guides for EVM users interacting with FlowVaults

---

**Document Version**: 2.0  
**Last Updated**: November 3, 2025  
**Authors**: Lionel, Navid (based on discussions)  
**Reviewed By**: Joshua (PR comments), Pending (Kan, engineering team)  
**Updates**: Code extracts updated with final contract implementations; improvements based on Joshua's feedback
