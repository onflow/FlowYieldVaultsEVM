# Tidal Cross-VM Bridge: EVM ↔ Cadence Design Document

## Executive Summary

This document outlines the architecture for enabling Flow EVM users to interact with Tidal's Cadence-based yield protocol through a scheduled cross-VM bridge pattern.

**Key Innovation**: EVM users deposit funds and submit requests to a Solidity contract, which are periodically processed by a Cadence worker that bridges funds and manages Tide positions on their behalf.

---

## Architecture Overview

### Components

#### 1. **TidalRequests** (Solidity - Flow EVM)
- **Purpose**: Request queue and fund escrow for EVM users
- **Location**: Flow EVM
- **Responsibilities**:
  - Accept user requests (CREATE_TIDE, DEPOSIT, WITHDRAW, CLOSE)
  - Escrow native $FLOW and ERC-20 tokens
  - Track per-user request queues
  - Track user balances across both VMs
  - Only allow fund withdrawals by the authorized COA

#### 2. **TidalEVMWorker** (Cadence)
- **Purpose**: Scheduled processor that executes EVM user requests on Cadence
- **Location**: Flow Cadence
- **Responsibilities**:
  - Poll TidalRequests contract at regular intervals (e.g., every 2 minutes or 1 hour)
  - Own and control the COA resource
  - Bridge funds between EVM and Cadence
  - Create and manage Tide positions tagged by EVM user address
  - Update request statuses and user balances in TidalRequests
  - Emit events for traceability

#### 3. **COA (Cadence Owned Account)**
- **Purpose**: Bridge account controlled by TidalEVMWorker
- **Ownership**: TidalEVMWorker holds the resource
- **Responsibilities**:
  - Withdraw funds from TidalRequests (via Solidity `onlyAuthorizedCOA` modifier)
  - Bridge funds from EVM to Cadence
  - Bridge funds from Cadence back to EVM for withdrawals (directly and atomically to user's EVM address)


![Tidal EVM Bridge Design](./create_tide.png)

*This diagram illustrates the complete flow for creating a new position (tide), from the user's initial request in the EVM environment through to the creation of the tide in Cadence.*

---

## Data Structures

### TidalRequests (Solidity)

```solidity
contract TidalRequests {
    // Constant address for native $FLOW token (similar to 1inch's approach)
    // Using a recognizable address pattern instead of address(0)
    address public constant NATIVE_FLOW = 0xFFFfFfFffffFFFffffFfFffffFfFfFfFFFFffffF;
    
    // Request types
    enum RequestType {
        CREATE_TIDE,
        DEPOSIT_TO_TIDE,
        WITHDRAW_FROM_TIDE,
        CLOSE_TIDE
    }
    
    // Request status
    enum RequestStatus {
        PENDING,
        PROCESSING,
        COMPLETED,
        FAILED
    }
    
    struct Request {
        uint256 id;              // Unique request identifier
        address user;            // EVM address of requester
        RequestType requestType; // Type of operation
        RequestStatus status;    // Current status
        address tokenAddress;    // NATIVE_FLOW or ERC-20 address
        uint256 amount;          // Amount (bi-directional: deposit or withdraw)
        uint64 tideId;          // Associated Tide ID (if applicable)
        uint256 timestamp;       // Request creation time
    }
    
    // User request queue: user address => array of requests
    mapping(address => Request[]) public userRequests;
    
    // User balances: user address => token address => balance
    // For native $FLOW, use NATIVE_FLOW constant as the token address
    // For ERC-20 tokens, use the actual token contract address
    mapping(address => mapping(address => uint256)) public userBalances;
    
    // Pending requests array for efficient processing
    mapping(uint256 => Request) public pendingRequests;
    uint256[] public pendingRequestIds;
    
    // Authorized COA address (only this address can withdraw)
    address public authorizedCOA;
    
    // Modifiers
    modifier onlyAuthorizedCOA() {
        require(msg.sender == authorizedCOA, "TidalRequests: caller is not authorized COA");
        _;
    }
    
    // Events
    event RequestCreated(uint256 indexed requestId, address indexed user, RequestType requestType, address indexed token, uint256 amount);
    event RequestProcessed(uint256 indexed requestId, RequestStatus status, uint64 tideId);
    event BalanceUpdated(address indexed user, address indexed token, uint256 newBalance);
    event FundsWithdrawn(address indexed to, address indexed token, uint256 amount);
    
    // Helper function to check if token is native FLOW
    function isNativeFlow(address token) public pure returns (bool) {
        return token == NATIVE_FLOW;
    }
}
```

### TidalEVMWorker (Cadence)

```cadence
access(all) contract TidalEVMWorker {
    // Storage paths
    access(all) let WorkerStoragePath: StoragePath
    access(all) let COAStoragePath: StoragePath
    
    // Tide storage: EVM address => array of Tide IDs
    // Stored as string hex addresses to avoid type conversion issues
    access(contract) let tidesByEVMAddress: {String: [UInt64]}
    
    // COA resource holder
    access(all) resource COAHolder {
        access(self) let coa: @EVM.CadenceOwnedAccount
        
        // Withdraw funds from TidalRequests contract
        access(all) fun withdrawFromEVM(amount: UFix64, tokenType: Type): @{FungibleToken.Vault}
        
        // Bridge funds back to EVM
        access(all) fun bridgeToEVM(vault: @{FungibleToken.Vault}, recipient: EVM.EVMAddress)
    }
    
    // Main worker resource
    access(all) resource Worker {
        // Process pending requests from TidalRequests
        access(all) fun processRequests()
        
        // Create a new Tide for an EVM user
        access(all) fun createTideForEVMUser(
            evmAddress: String,
            strategyType: Type,
            vault: @{FungibleToken.Vault}
        ): UInt64
        
        // Deposit to existing Tide
        access(all) fun depositToTide(
            evmAddress: String,
            tideId: UInt64,
            vault: @{FungibleToken.Vault}
        )
        
        // Withdraw from Tide
        access(all) fun withdrawFromTide(
            evmAddress: String,
            tideId: UInt64,
            amount: UFix64
        ): @{FungibleToken.Vault}
        
        // Close Tide and return all funds
        access(all) fun closeTide(
            evmAddress: String,
            tideId: UInt64
        ): @{FungibleToken.Vault}
    }
}
```

---

## Request Flow Diagrams

### 1. CREATE_TIDE Flow

```
EVM User A                TidalRequests          TidalEVMWorker           TidalYield         FlowScheduler
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
EVM User A                TidalRequests          TidalEVMWorker           TidalYield         FlowScheduler
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

The TidalEVMWorker uses **Flow's scheduled transaction capability** to periodically process pending requests from the EVM side. This is a key architectural component that enables the asynchronous bridge pattern.

### Scheduling Mechanism

```cadence
// Scheduled transaction registered with Flow
// Executes automatically every X minutes/hours
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&TidalEVMWorker.Worker>(
            from: TidalEVMWorker.WorkerStoragePath
        ) ?? panic("Could not borrow Worker")
    }
    
    execute {
        // This runs automatically on schedule
        worker.processRequests()
    }
}
```

### Error Handling in Scheduled Transactions

```cadence
access(all) fun processRequests() {
    let pendingRequests = self.fetchPendingRequests()
    
    for request in pendingRequests {
        // Try to process each request
        let success = self.processRequestSafely(request)
        
        if !success {
            // Mark as FAILED and continue to next
            // Don't let one failure stop entire batch
            self.markRequestFailed(request.id)
        }
    }
}

access(all) fun processRequestSafely(_ request: Request): Bool {
    // Wrap in error handling
    if let result = self.tryProcessRequest(request) {
        return true
    } else {
        // Log error and return false
        return false
    }
}
```

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

## Key Design Decisions

### 1. **Request Queue Pattern**
- **Decision**: Use a pull-based model where TidalEVMWorker polls for requests
- **Rationale**: 
  - fully on-chain no off-chain event listeners
  - Worker can process multiple requests in one transaction (if gas < 9999, need some tests to estimate)

### 2. **Fund Escrow in TidalRequests**
- **Decision**: Funds remain in TidalRequests until processed
- **Rationale**:
  - Security: Only authorized COA can withdraw
  - Transparency: Easy to audit locked funds
  - Rollback safety: Failed requests don't lose funds

### 3. **Balance Tracking on Both Sides**
- **Decision**: Maintain userBalances mapping in TidalRequests
- **Rationale**:
  - Enables validation without cross-VM calls
  - Provides efficient balance queries for EVM users
  - Supports multi-token accounting

### 4. **Tide Storage by EVM Address**
- **Decision**: Store Tides in TidalEVMWorker tagged by EVM address string
- **Rationale**:
  - Clear ownership mapping
  - Efficient lookups for subsequent operations
  - Supports multiple Tides per user

### 5. **Native $FLOW vs ERC-20 Tokens**
- **Decision**: Use a constant address `NATIVE_FLOW` for native token
- **Rationale**:
  - Follows DeFi best practices (similar to 1inch, Uniswap, etc.)
  - Address pattern: `0xFFFfFfFffffFFFffffFfFffffFfFfFfFFFFffffF` (recognizable)
  - Different transfer mechanisms (native value transfer vs ERC-20 transferFrom)
  - Can conditionally integrate Flow EVM Bridge for ERC-20s

---

## Outstanding Questions & Alignment Needed

### 1. **Processing Schedule & Computation Limits**
- **Question**: What is the optimal interval for processRequests()?
  - Options: Every 2 minutes, hourly, on-demand?
- **Question**: How many requests can be processed in a single transaction?
  - Need to benchmark computation limits
  - May need request prioritization or batching strategy
- **Navid's Note**: "We assume all TidalRequests can be executed in 1 scheduled transaction... have to evaluate in future what the upper limit is"

### 2. **Multi-Token Support**
- **Question**: When do we integrate the Flow EVM Bridge for ERC-20 tokens?
  - Phase 1: Native $FLOW only
  - Phase 2: ERC-20 support via bridge
- **Question**: How do we handle token whitelisting?
  - Which tokens from the Cadence side are supported?
- **Alignment**: "We can conditionally incorporate the EVM bridge with the already onboarded tokens on the Cadence side"

### 3. **Request Lifecycle & Timeouts**
- **Question**: Can users cancel pending requests?

### 4. **State Consistency**
- **Question**: What happens if TidalEVMWorker updates Cadence state but fails to update TidalRequests?
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
1. **COA Authorization**: Only TidalEVMWorker can control the COA
2. **Withdrawal Authorization**: Only COA can withdraw from TidalRequests
3. **Tide Ownership**: Tides are tagged by EVM address and non-transferable
4. **Request Validation**: Prevent duplicate processing of requests

### Fund Safety
1. **Escrow Security**: Funds locked until successful processing
2. **Rollback Protection**: Failed operations don't lose funds
3. **Balance Reconciliation**: userBalances must match actual holdings

### Attack Vectors to Consider
1. **Request Spam**: Rate limiting on createRequest()
4. **Balance Manipulation**: Atomic updates to prevent discrepancies

---

## Implementation Phases

### Phase 1: MVP (Native $FLOW only)
- Deploy TidalRequests contract to Flow EVM
- Deploy TidalEVMWorker to Cadence
- Support CREATE_TIDE and CLOSE_TIDE operations
- Manual trigger for processRequests()

### Phase 2: Full Operations
- Add DEPOSIT_TO_TIDE and WITHDRAW_FROM_TIDE
- Automated scheduled processing
- Event tracing and monitoring

### Phase 3: Multi-Token Support
- Integrate Flow EVM Bridge for ERC-20 tokens
- Token whitelisting system
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

## Comparison with Existing Tidal Transactions

The Cadence transactions provided (`create_tide.cdc`, `deposit_to_tide.cdc`, `withdraw_from_tide.cdc`, `close_tide.cdc`) demonstrate the native Cadence flow. Key differences in the EVM bridge approach:

| Aspect | Native Cadence | EVM Bridge |
|--------|----------------|------------|
| User Identity | Flow account with BetaBadge | EVM address |
| Transaction Signer | User's Flow account | TidalEVMWorker (on behalf of user) |
| Fund Source | User's Cadence vault | TidalRequests escrow |
| Tide Storage | User's TideManager | TidalEVMWorker (tagged by EVM address) |
| Processing | Immediate (single txn) | Asynchronous (scheduled polling) |
| Beta Access | User holds BetaBadge | COA/Worker holds BetaBadge |

---

## Next Steps

1. **Alignment Meeting**: Review this document with Navid and Kan to resolve outstanding questions
2. **Technical Specification**: Detailed function signatures and state machine diagrams
3. **Prototype Development**: Implement Phase 1 MVP on testnet
4. **Security Audit**: Review design with security team before mainnet deployment
5. **Documentation**: User-facing guides for EVM users interacting with Tidal

---

**Document Version**: 1.0  
**Last Updated**: October 27, 2025  
**Authors**: Lionel, Navid (based on discussions)  
**Reviewed By**: Pending (Kan, engineering team)
