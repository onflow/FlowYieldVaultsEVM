# Flow Vaults Cross-VM Bridge: Technical Design

## Purpose

Enable Flow EVM users to interact with Flow Vaults's Cadence-based yield protocol through an asynchronous cross-VM bridge.

## Model

EVM users deposit FLOW and submit requests to a Solidity contract. A Cadence worker periodically processes these requests, bridges funds via COA, and manages Tide positions on their behalf.

---

## Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Flow EVM                                       │
│                                                                             │
│  ┌──────────────┐         ┌─────────────────────────┐                       │
│  │   EVM User   │────────▶│   FlowVaultsRequests    │                       │
│  │              │         │                         │                       │
│  │  - Deposit   │         │  - Request queue        │                       │
│  │  - Request   │◀────────│  - Fund escrow          │                       │
│  │  - Cancel    │         │  - Balance tracking     │                       │
│  └──────────────┘         └───────────┬─────────────┘                       │
│                                       │                                     │
└───────────────────────────────────────┼─────────────────────────────────────┘
                                        │ COA calls:
                                        │ - startProcessing()
                                        │ - completeProcessing()
┌───────────────────────────────────────┼─────────────────────────────────────┐
│                              Flow Cadence                                   │
│                                       ▼                                     │
│  ┌────────────────────────────────────────────────────────────┐             │
│  │                      FlowVaultsEVM                         │             │
│  │                                                            │             │
│  │  ┌─────────────────────────────────────────────────────┐   │             │
│  │  │                     Worker                          │   │             │
│  │  │                                                     │   │             │
│  │  │  Capabilities:                                      │   │             │
│  │  │  - coaCap (EVM.Call, EVM.Withdraw, EVM.Bridge)      │   │             │
│  │  │  - tideManagerCap (FungibleToken.Withdraw)          │   │             │
│  │  │  - betaBadgeCap (FlowVaultsClosedBeta.Beta)         │   │             │
│  │  │  - feeProviderCap (FungibleToken.Withdraw)          │   │             │
│  │  │                                                     │   │             │
│  │  │  Functions:                                         │   │             │
│  │  │  - processRequests()                                │   │             │
│  │  │  - processCreateTide()                              │   │             │
│  │  │  - processDepositToTide()                           │   │             │
│  │  │  - processWithdrawFromTide()                        │   │             │
│  │  │  - processCloseTide()                               │   │             │
│  │  └─────────────────────────────────────────────────────┘   │             │
│  │                                                            │             │
│  │  State:                                                    │             │
│  │  - tidesByEVMAddress: {String: [UInt64]}                   │             │
│  │  - tideOwnershipLookup: {String: {UInt64: Bool}}           │             │
│  │  - flowVaultsRequestsAddress: EVM.EVMAddress?              │             │
│  │  - maxRequestsPerTx: Int (default: 1)                      │             │
│  └────────────────────────────────────────────────────────────┘             │
│                              ▲                                              │
│                              │ triggers                                     │
│  ┌───────────────────────────┴────────────────────────────────-┐            │
│  │            FlowVaultsTransactionHandler                     │            │
│  │                                                             │            │
│  │  - Implements FlowTransactionScheduler.TransactionHandler   │            │
│  │  - Auto-schedules next execution after each run             │            │
│  │  - Adaptive delay based on pending request count            │            │
│  │  - Supports parallel transaction scheduling                 │            │
│  │  - Pausable via Admin resource                              │            │
│  └─────────────────────────────────────────────────────────────┘            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Core Components

#### 1. FlowVaultsRequests (Solidity - Flow EVM)

Request queue and fund escrow contract.

**Responsibilities:**
- Accept and queue user requests (CREATE_TIDE, DEPOSIT_TO_TIDE, WITHDRAW_FROM_TIDE, CLOSE_TIDE)
- Escrow deposited funds until processing
- Track user balances and pending request counts
- Enforce access control (allowlist/blocklist)
- Two-phase commit for atomic processing

**Key State:**
```solidity
// Request tracking
mapping(uint256 => Request) public requests;
uint256[] public pendingRequestIds;
mapping(address => uint256) public userPendingRequestCount;

// Balance tracking
mapping(address => mapping(address => uint256)) public pendingUserBalances;

// Tide ownership (EVM-side mirror)
mapping(uint64 => bool) public validTideIds;
mapping(uint64 => address) public tideOwners;
mapping(address => uint64[]) public tidesByUser;
mapping(address => mapping(uint64 => bool)) public userOwnsTide;

// Access control
address public authorizedCOA;
bool public allowlistEnabled;
bool public blocklistEnabled;
mapping(address => bool) public allowlisted;
mapping(address => bool) public blocklisted;
```

#### 2. FlowVaultsEVM (Cadence)

Worker contract that processes EVM requests and manages Tide positions.

**Responsibilities:**
- Fetch pending requests from EVM via `getPendingRequestsUnpacked()`
- Execute two-phase commit (startProcessing → operation → completeProcessing)
- Create, deposit to, withdraw from, and close Tides
- Bridge funds between EVM and Cadence via COA
- Track Tide ownership by EVM address

**Key State:**
```cadence
// Tide ownership tracking
access(all) let tidesByEVMAddress: {String: [UInt64]}
access(all) let tideOwnershipLookup: {String: {UInt64: Bool}}

// Configuration
access(all) var flowVaultsRequestsAddress: EVM.EVMAddress?
access(all) var maxRequestsPerTx: Int  // Default: 1, max: 100

// Constants
access(all) let nativeFlowEVMAddress: EVM.EVMAddress  // 0xFFfF...FfFFFfF
```

#### 3. FlowVaultsTransactionHandler (Cadence)

Scheduled transaction handler with auto-scheduling.

**Responsibilities:**
- Implement `FlowTransactionScheduler.TransactionHandler` interface
- Trigger Worker's `processRequests()` on scheduled execution
- Auto-schedule next execution based on queue depth
- Support parallel transaction scheduling for high throughput
- Pausable for maintenance

**Key State:**
```cadence
// Delay configuration (pending count → delay in seconds)
access(all) let thresholdToDelay: {Int: UFix64}  // {50: 5.0, 20: 15.0, 10: 30.0, 5: 45.0, 0: 60.0}
access(all) let defaultDelay: UFix64  // 60.0

// Parallel processing
access(all) var maxParallelTransactions: Int  // Default: 1

// Control
access(all) var isPaused: Bool
```

#### 4. COA (Cadence Owned Account)

Bridge account controlled by the Worker.

**Capabilities Required:**
- `EVM.Call` - Call EVM contracts
- `EVM.Withdraw` - Withdraw native $FLOW from EVM
- `EVM.Bridge` - Bridge tokens between VMs

---

## Data Structures

### Request (Solidity)

```solidity
// Sentinel value for "no tide" (type(uint64).max)
uint64 public constant NO_TIDE_ID = type(uint64).max;

struct Request {
    uint256 id;                  // Auto-incrementing ID (starts at 1)
    address user;                // Request creator
    RequestType requestType;     // CREATE_TIDE | DEPOSIT_TO_TIDE | WITHDRAW_FROM_TIDE | CLOSE_TIDE
    RequestStatus status;        // PENDING | PROCESSING | COMPLETED | FAILED
    address tokenAddress;        // NATIVE_FLOW (0xFFfF...FfFFFfF) or ERC20 address
    uint256 amount;              // Amount in wei (0 for CLOSE_TIDE)
    uint64 tideId;               // Target Tide ID (NO_TIDE_ID for CREATE_TIDE until completed)
    uint256 timestamp;           // Block timestamp when created
    string message;              // Status message or error reason
    string vaultIdentifier;      // Cadence vault type (e.g., "A.xxx.FlowToken.Vault")
    string strategyIdentifier;   // Cadence strategy type (e.g., "A.xxx.Strategy.Type")
}

enum RequestType {
    CREATE_TIDE,        // 0
    DEPOSIT_TO_TIDE,    // 1
    WITHDRAW_FROM_TIDE, // 2
    CLOSE_TIDE          // 3
}

enum RequestStatus {
    PENDING,     // 0 - Awaiting processing
    PROCESSING,  // 1 - Being processed (balance deducted)
    COMPLETED,   // 2 - Successfully processed
    FAILED       // 3 - Failed (balance refunded)
}
```

### EVMRequest (Cadence)

```cadence
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
    access(all) let vaultIdentifier: String
    access(all) let strategyIdentifier: String
}
```

### ProcessResult (Cadence)

```cadence
/// Sentinel value for "no tide" (UInt64.max)
access(all) let noTideId: UInt64 = UInt64.max

access(all) struct ProcessResult {
    access(all) let success: Bool
    access(all) let tideId: UInt64  // Uses noTideId as sentinel for "no tide"
    access(all) let message: String
}
```

---

## Request Processing Flows

### CREATE_TIDE

```
┌─────────────┐     ┌────────────────────┐     ┌─────────────────┐     ┌──────────────┐
│  EVM User   │     │ FlowVaultsRequests │     │  FlowVaultsEVM  │     │  Flow Vaults │
└──────┬──────┘     └─────────┬──────────┘     └────────┬────────┘     └──────┬───────┘
       │                      │                         │                      │
       │ createTide(token,    │                         │                      │
       │ amount, vault, strat)│                         │                      │
       │─────────────────────▶│                         │                      │
       │                      │ Escrow funds            │                      │
       │                      │ Create PENDING request  │                      │
       │◀─────────────────────│                         │                      │
       │     requestId        │                         │                      │
       │                      │                         │                      │
       │                      │     getPendingRequests  │                      │
       │                      │◀────────────────────────│                      │
       │                      │     [EVMRequest]        │                      │
       │                      │────────────────────────▶│                      │
       │                      │                         │                      │
       │                      │     startProcessing(id) │                      │
       │                      │◀────────────────────────│                      │
       │                      │ Mark PROCESSING         │                      │
       │                      │ Deduct user balance     │                      │
       │                      │────────────────────────▶│                      │
       │                      │                         │                      │
       │                      │                         │ COA.withdraw(amount) │
       │                      │                         │─────────────────────▶│
       │                      │                         │      $FLOW           │
       │                      │                         │◀─────────────────────│
       │                      │                         │                      │
       │                      │                         │ createTide(vault)    │
       │                      │                         │─────────────────────▶│
       │                      │                         │      tideId          │
       │                      │                         │◀─────────────────────│
       │                      │                         │                      │
       │                      │                         │ Store tideId mapping │
       │                      │                         │                      │
       │                      │ completeProcessing(id,  │                      │
       │                      │   true, tideId, msg)    │                      │
       │                      │◀────────────────────────│                      │
       │                      │ Mark COMPLETED          │                      │
       │                      │ Register Tide           │                      │
       │                      │────────────────────────▶│                      │
```

### DEPOSIT_TO_TIDE

```
1. User calls depositToTide(tideId, token, amount)
2. Contract validates Tide ownership
3. Contract escrows funds, creates PENDING request
4. Worker fetches request via getPendingRequestsUnpacked()
5. Worker validates Tide ownership (O(1) lookup)
6. Worker calls startProcessing() → PROCESSING, balance deducted
7. COA withdraws funds from its balance
8. Worker deposits to Tide via TideManager
9. Worker calls completeProcessing() → COMPLETED
```

### WITHDRAW_FROM_TIDE

```
1. User calls withdrawFromTide(tideId, amount)
2. Contract validates Tide ownership
3. Contract creates PENDING request (no escrow needed)
4. Worker fetches request via getPendingRequestsUnpacked()
5. Worker validates Tide ownership
6. Worker calls startProcessing() → PROCESSING
7. Worker withdraws from Tide via TideManager
8. Worker bridges funds to EVM via COA.deposit()
9. COA transfers $FLOW directly to user's EVM address
10. Worker calls completeProcessing() → COMPLETED
```

### CLOSE_TIDE

```
1. User calls closeTide(tideId)
2. Contract validates Tide ownership
3. Contract creates PENDING request (amount = 0)
4. Worker fetches request via getPendingRequestsUnpacked()
5. Worker validates Tide ownership
6. Worker calls startProcessing() → PROCESSING
7. Worker closes Tide via TideManager, receives all funds
8. Worker bridges funds to EVM via COA.deposit()
9. COA transfers all $FLOW to user's EVM address
10. Worker removes Tide from ownership mappings
11. Worker calls completeProcessing() → COMPLETED
12. Contract unregisters Tide ownership
```

### Request Cancellation

```
1. User calls cancelRequest(requestId)
2. Contract validates ownership and PENDING status
3. Contract marks request as FAILED
4. Contract refunds escrowed funds to user
5. Contract decrements pending request count
```

---

## Two-Phase Commit

The bridge uses a two-phase commit pattern for atomic state management:

### Phase 1: startProcessing()

```solidity
function startProcessing(uint256 requestId) external onlyAuthorizedCOA {
    // 1. Validate request exists and is PENDING
    // 2. Mark as PROCESSING
    // 3. For CREATE_TIDE/DEPOSIT_TO_TIDE: Deduct user balance
    // 4. Emit RequestProcessed event
}
```

**Purpose:** Prevents double-spending by atomically deducting user balance before Cadence operations begin.

### Phase 2: completeProcessing()

```solidity
function completeProcessing(
    uint256 requestId,
    bool success,
    uint64 tideId,
    string calldata message
) external onlyAuthorizedCOA {
    // 1. Validate request is PROCESSING
    // 2. Mark as COMPLETED or FAILED
    // 3. On failure: Refund user balance
    // 4. On CREATE_TIDE success: Register Tide ownership
    // 5. On CLOSE_TIDE success: Unregister Tide ownership
    // 6. Remove from pending queue
    // 7. Emit RequestProcessed event
}
```

**Purpose:** Finalizes the operation with proper cleanup. Automatic refunds on failure ensure funds are never lost.

---

## Adaptive Scheduling

### Delay Thresholds

| Pending Requests | Delay (seconds) | Description |
|------------------|-----------------|-------------|
| >= 50 | 5 | High load - rapid processing |
| >= 20 | 15 | Medium-high load |
| >= 10 | 30 | Medium load |
| >= 5 | 45 | Low load |
| 0 | 60 | Idle - minimal overhead |

### Scheduling Logic

```cadence
access(all) fun getDelayForPendingCount(_ pendingCount: Int): UFix64 {
    // Find highest threshold that pendingCount meets
    var bestThreshold: Int? = nil

    for threshold in self.thresholdToDelay.keys {
        if pendingCount >= threshold {
            if bestThreshold == nil || threshold > bestThreshold! {
                bestThreshold = threshold
            }
        }
    }

    return self.thresholdToDelay[bestThreshold] ?? self.defaultDelay
}
```

### Parallel Processing

When pending requests exceed `maxRequestsPerTx`, the handler schedules multiple parallel transactions:

```cadence
// Calculate needed transactions
let neededTransactions = (pendingRequests + maxRequestsPerTx - 1) / maxRequestsPerTx
let parallelCount = min(neededTransactions, maxParallelTransactions)

// Schedule parallelCount transactions at the same timestamp
for i in 0..<parallelCount {
    manager.scheduleByHandler(...)
}
```

---

## Balance Queries

### EVM Side

```solidity
// User's escrowed balance
function getUserPendingBalance(address user, address tokenAddress) returns (uint256);

// Pending request count
function getPendingRequestCount() returns (uint256);

// User's pending request count
function getUserPendingRequestCount(address user) returns (uint256);

// User's Tide IDs
function getTideIDsForUser(address user) returns (uint64[] memory);

// Ownership check (O(1))
function doesUserOwnTide(address user, uint64 tideId) returns (bool);
```

### Cadence Side

```cadence
// Tide IDs by EVM address
access(all) view fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64]

// Ownership check (O(1))
access(all) view fun doesEVMAddressOwnTide(evmAddress: String, tideId: UInt64): Bool
```

---

## Security

### Access Control

| Component | Mechanism | Details |
|-----------|-----------|---------|
| FlowVaultsRequests | `onlyAuthorizedCOA` | Only COA can call processing functions |
| FlowVaultsRequests | `onlyOwner` | Admin functions restricted to owner |
| FlowVaultsRequests | `onlyAllowlisted` | Optional whitelist for users |
| FlowVaultsRequests | `notBlocklisted` | Optional blacklist for users |
| FlowVaultsEVM | Capability-based | Worker requires valid COA, TideManager, BetaBadge caps |
| FlowVaultsTransactionHandler | Admin resource | Pause/unpause restricted to Admin holder |

### Tide Ownership Verification

Both EVM and Cadence maintain ownership state with O(1) lookup:

```solidity
// Solidity
mapping(address => mapping(uint64 => bool)) public userOwnsTide;
```

```cadence
// Cadence
access(all) let tideOwnershipLookup: {String: {UInt64: Bool}}
```

Every operation verifies ownership before execution.

### Fund Safety

1. **Escrow Model:** Funds held in contract until successful processing
2. **Two-Phase Commit:** Balance deducted before operation, refunded on failure
3. **Atomic Transfers:** No intermediate states where funds can be lost
4. **ReentrancyGuard:** Solidity contract protected against reentrancy

### Input Validation

```cadence
// EVMRequest validation in constructor
pre {
    requestType >= RequestType.CREATE_TIDE.rawValue &&
    requestType <= RequestType.CLOSE_TIDE.rawValue:
        "Invalid request type"

    requestType == RequestType.CLOSE_TIDE.rawValue || amount > 0:
        "Amount must be greater than 0 for non-close operations"
}
```

---

## Events

### FlowVaultsRequests (Solidity)

| Event | Description |
|-------|-------------|
| `RequestCreated` | New request submitted |
| `RequestProcessed` | Request status changed |
| `RequestCancelled` | User cancelled request |
| `BalanceUpdated` | User's escrowed balance changed |
| `FundsWithdrawn` | Funds transferred out |
| `AuthorizedCOAUpdated` | COA address changed |
| `AllowlistEnabled` | Allowlist toggled |
| `BlocklistEnabled` | Blocklist toggled |
| `TokenConfigured` | Token configuration changed |

### FlowVaultsEVM (Cadence)

| Event | Description |
|-------|-------------|
| `WorkerInitialized` | Worker created with COA |
| `FlowVaultsRequestsAddressSet` | EVM contract address configured |
| `RequestsProcessed` | Batch processing completed |
| `TideCreatedForEVMUser` | New Tide created |
| `TideDepositedForEVMUser` | Deposit to Tide |
| `TideWithdrawnForEVMUser` | Withdrawal from Tide |
| `TideClosedForEVMUser` | Tide closed |
| `RequestFailed` | Request processing failed |
| `MaxRequestsPerTxUpdated` | Configuration changed |

### FlowVaultsTransactionHandler (Cadence)

| Event | Description |
|-------|-------------|
| `HandlerPaused` | Processing paused |
| `HandlerUnpaused` | Processing resumed |
| `ScheduledExecutionTriggered` | Handler executed |
| `ParallelExecutionsScheduled` | Next executions scheduled |
| `ExecutionSkipped` | Execution skipped (paused or error) |

---

## Error Handling

### Solidity Errors

| Error | Cause |
|-------|-------|
| `NotAuthorizedCOA` | Non-COA calling restricted function |
| `NotOwner` | Non-owner calling admin function |
| `NotInAllowlist` | User not whitelisted |
| `Blocklisted` | User is blacklisted |
| `AmountMustBeGreaterThanZero` | Zero amount deposit |
| `TokenNotSupported` | Unsupported token |
| `RequestNotFound` | Invalid request ID |
| `NotRequestOwner` | Cancelling another user's request |
| `CanOnlyCancelPending` | Cancelling non-pending request |
| `RequestAlreadyFinalized` | Processing completed request |
| `InsufficientBalance` | Not enough funds |
| `BelowMinimumBalance` | Deposit below minimum |
| `TooManyPendingRequests` | User at limit |
| `InvalidTideId` | Tide not owned by user |

### Cadence Error Handling

Failed operations return `ProcessResult` with `success: false` and descriptive message. The Worker emits `RequestFailed` events and calls `completeProcessing(success: false)` to trigger refunds.

---

## Configuration

### Admin Functions

#### FlowVaultsRequests

```solidity
function setAuthorizedCOA(address _coa) external onlyOwner;
function setAllowlistEnabled(bool _enabled) external onlyOwner;
function setBlocklistEnabled(bool _enabled) external onlyOwner;
function batchAddToAllowlist(address[] calldata _addresses) external onlyOwner;
function batchRemoveFromAllowlist(address[] calldata _addresses) external onlyOwner;
function batchAddToBlocklist(address[] calldata _addresses) external onlyOwner;
function batchRemoveFromBlocklist(address[] calldata _addresses) external onlyOwner;
function setTokenConfig(address token, bool supported, uint256 min, bool native) external onlyOwner;
function setMaxPendingRequestsPerUser(uint256 _max) external onlyOwner;
function dropRequests(uint256[] calldata requestIds) external onlyOwner;
```

#### FlowVaultsEVM

```cadence
// Admin resource functions
access(all) fun setFlowVaultsRequestsAddress(_ address: EVM.EVMAddress)
access(all) fun updateFlowVaultsRequestsAddress(_ address: EVM.EVMAddress)
access(all) fun updateMaxRequestsPerTx(_ newMax: Int)  // 1-100
access(all) fun createWorker(...): @Worker
```

#### FlowVaultsTransactionHandler

```cadence
// Admin resource functions
access(all) fun pause()
access(all) fun unpause()
access(all) fun setMaxParallelTransactions(count: Int)
```

---

## Token Support

### Native $FLOW

- Address: `0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF`
- Minimum: 1 FLOW (configurable)
- Transfer: `msg.value` for deposits, `call{value}` for withdrawals

### ERC-20 Tokens

- Onboarded via FlowEVMBridge
- Uses `FlowEVMBridgeConfig.getTypeAssociated()` for type lookup
- Transfer: `SafeERC20.safeTransferFrom` / `safeTransfer`
- Bridging: `coaRef.withdrawTokens()` / `depositTokens()`

---

## Deployment

### Prerequisites

1. Flow account with FLOW for deployment and fees
2. FlowVaultsClosedBeta.BetaBadge for Tide creation
3. FlowVaults.TideManager for managing positions
4. COA with sufficient capabilities

### Deployment Order

1. Deploy `FlowVaultsRequests` on EVM with COA address
2. Deploy `FlowVaultsEVM` on Cadence
3. Deploy `FlowVaultsTransactionHandler` on Cadence
4. Configure `FlowVaultsEVM` with EVM contract address
5. Create Worker with required capabilities
6. Create Handler with Worker capability
7. Register Handler with FlowTransactionScheduler
8. Schedule initial execution

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Initial | Basic request/response flow |
| 2.0 | - | Added two-phase commit |
| 3.0 | Nov 2025 | Adaptive scheduling, parallel processing, O(1) ownership lookup |
