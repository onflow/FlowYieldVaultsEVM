# Flow YieldVaults Cross-VM Bridge: Technical Design

## Purpose

Enable Flow EVM users to interact with Flow YieldVaults's Cadence-based yield protocol through an asynchronous cross-VM bridge.

## Model

EVM users deposit FLOW and submit requests to a Solidity contract. A Cadence worker periodically processes these requests, bridges funds via COA, and manages YieldVault positions on their behalf.

---

## Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Flow EVM                                       │
│                                                                             │
│  ┌──────────────┐         ┌───────────────────────────┐                    │
│  │   EVM User   │────────▶│  FlowYieldVaultsRequests  │                    │
│  │              │         │                           │                    │
│  │  - Deposit   │         │  - Request queue          │                    │
│  │  - Request   │◀────────│  - Fund escrow            │                    │
│  │  - Cancel    │         │  - Balance tracking       │                    │
│  └──────────────┘         └─────────────┬─────────────┘                    │
│                                         │                                   │
└─────────────────────────────────────────┼───────────────────────────────────┘
                                          │ COA calls:
                                          │ - startProcessing()
                                          │ - completeProcessing()
┌─────────────────────────────────────────┼───────────────────────────────────┐
│                              Flow Cadence                                   │
│                                         ▼                                   │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                       FlowYieldVaultsEVM                              │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │  │
│  │  │                          Worker                                 │ │  │
│  │  │                                                                 │ │  │
│  │  │  Capabilities:                                                  │ │  │
│  │  │  - coaCap (EVM.Call, EVM.Withdraw, EVM.Bridge)                  │ │  │
│  │  │  - yieldVaultManagerCap (FungibleToken.Withdraw)                │ │  │
│  │  │  - betaBadgeCap (FlowYieldVaultsClosedBeta.Beta)                │ │  │
│  │  │  - feeProviderCap (FungibleToken.Withdraw)                      │ │  │
│  │  │                                                                 │ │  │
│  │  │  Functions:                                                     │ │  │
│  │  │  - processRequests()                                            │ │  │
│  │  │  - processCreateYieldVault()                                    │ │  │
│  │  │  - processDepositToYieldVault()                                 │ │  │
│  │  │  - processWithdrawFromYieldVault()                              │ │  │
│  │  │  - processCloseYieldVault()                                     │ │  │
│  │  └─────────────────────────────────────────────────────────────────┘ │  │
│  │                                                                       │  │
│  │  State:                                                               │  │
│  │  - yieldVaultsByEVMAddress: {String: [UInt64]}                        │  │
│  │  - yieldVaultOwnershipLookup: {String: {UInt64: Bool}}                │  │
│  │  - flowYieldVaultsRequestsAddress: EVM.EVMAddress?                    │  │
│  │  - maxRequestsPerTx: Int (default: 1)                                 │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                              ▲                                              │
│                              │ triggers                                     │
│  ┌───────────────────────────┴─────────────────────────────────────────┐   │
│  │              FlowYieldVaultsTransactionHandler                       │   │
│  │                                                                      │   │
│  │  - Implements FlowTransactionScheduler.TransactionHandler           │   │
│  │  - Auto-schedules next execution after each run                     │   │
│  │  - Adaptive delay based on pending request count                    │   │
│  │  - Single scheduled execution (parallel scheduling planned)         │   │
│  │  - Pausable via Admin resource                                      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Core Components

#### 1. FlowYieldVaultsRequests (Solidity - Flow EVM)

Request queue and fund escrow contract.

**Responsibilities:**
- Accept and queue user requests (CREATE_YIELDVAULT, DEPOSIT_TO_YIELDVAULT, WITHDRAW_FROM_YIELDVAULT, CLOSE_YIELDVAULT)
- Escrow deposited funds until processing
- Track user balances and pending request counts
- Enforce access control (allowlist/blocklist)
- Two-phase commit to coordinate cross-VM processing (non-atomic across VMs)

**Key State:**
```solidity
// Request tracking
mapping(uint256 => Request) public requests;
uint256[] public pendingRequestIds;
mapping(address => uint256) public userPendingRequestCount;

// Balance tracking
mapping(address => mapping(address => uint256)) public pendingUserBalances;  // Escrowed for active requests
mapping(address => mapping(address => uint256)) public claimableRefunds;     // Claimable from cancelled/failed

// YieldVault ownership (EVM-side mirror)
mapping(uint64 => bool) public validYieldVaultIds;
mapping(uint64 => address) public yieldVaultOwners;
mapping(address => uint64[]) public yieldVaultsByUser;
mapping(address => mapping(uint64 => bool)) public userOwnsYieldVault;

// Access control
address public authorizedCOA;
bool public allowlistEnabled;
bool public blocklistEnabled;
mapping(address => bool) public allowlisted;
mapping(address => bool) public blocklisted;
```

#### 2. FlowYieldVaultsEVM (Cadence)

Worker contract that processes EVM requests and manages YieldVault positions.

**Responsibilities:**
- Fetch pending requests from EVM via `getPendingRequestsUnpacked()`
- Execute two-phase commit (startProcessing → operation → completeProcessing)
- Create, deposit to, withdraw from, and close YieldVaults
- Bridge funds between EVM and Cadence via COA
- Track YieldVault ownership by EVM address

**Key State:**
```cadence
// YieldVault ownership tracking
access(all) let yieldVaultsByEVMAddress: {String: [UInt64]}
access(all) let yieldVaultOwnershipLookup: {String: {UInt64: Bool}}

// Configuration (stored as contract-only vars; exposed via getters)
var flowYieldVaultsRequestsAddress: EVM.EVMAddress?
var maxRequestsPerTx: Int  // Default: 1, max: 100

// Constants
access(all) let nativeFlowEVMAddress: EVM.EVMAddress  // 0xFFfF...FfFFFfF
```

#### 3. FlowYieldVaultsTransactionHandler (Cadence)

Scheduled transaction handler with auto-scheduling.

**Responsibilities:**
- Implement `FlowTransactionScheduler.TransactionHandler` interface
- Trigger Worker's `processRequests()` on scheduled execution
- Auto-schedule next execution based on queue depth
- Dynamic execution effort calculation based on request count
- Pausable for maintenance

**Key State:**
```cadence
// Delay configuration (pending count → delay in seconds)
access(contract) var thresholdToDelay: {Int: UFix64}  // {11: 3.0, 5: 5.0, 1: 7.0, 0: 30.0}
access(all) let defaultDelay: UFix64  // 30.0

// Execution effort parameters
access(contract) var baseEffortPerRequest: UInt64  // Default: 2000
access(contract) var baseOverhead: UInt64          // Default: 3000
access(contract) var idleExecutionEffort: UInt64   // Default: 5000 (for Medium priority)

// Control
access(contract) var isPaused: Bool
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
// Sentinel value for "no yieldvault" (type(uint64).max)
uint64 public constant NO_YIELDVAULT_ID = type(uint64).max;

struct Request {
    uint256 id;                  // Auto-incrementing ID (starts at 1)
    address user;                // Request creator
    RequestType requestType;     // CREATE_YIELDVAULT | DEPOSIT_TO_YIELDVAULT | WITHDRAW_FROM_YIELDVAULT | CLOSE_YIELDVAULT
    RequestStatus status;        // PENDING | PROCESSING | COMPLETED | FAILED
    address tokenAddress;        // NATIVE_FLOW (0xFFfF...FfFFFfF) or ERC20 address
    uint256 amount;              // Amount in wei (0 for CLOSE_YIELDVAULT)
    uint64 yieldVaultId;               // Target YieldVault Id (NO_YIELDVAULT_ID for CREATE_YIELDVAULT until completed)
    uint256 timestamp;           // Block timestamp when created
    string message;              // Status message or error reason
    string vaultIdentifier;      // Cadence vault type (e.g., "A.xxx.FlowToken.Vault")
    string strategyIdentifier;   // Cadence strategy type (e.g., "A.xxx.Strategy.Type")
}

enum RequestType {
    CREATE_YIELDVAULT,        // 0
    DEPOSIT_TO_YIELDVAULT,    // 1
    WITHDRAW_FROM_YIELDVAULT, // 2
    CLOSE_YIELDVAULT          // 3
}

enum RequestStatus {
    PENDING,     // 0 - Awaiting processing
    PROCESSING,  // 1 - Being processed (balance deducted)
    COMPLETED,   // 2 - Successfully processed
    FAILED       // 3 - Failed (refund credited; user must claim)
}

struct TokenConfig {
    bool isSupported;      // Whether the token is supported
    uint256 minimumBalance; // Minimum balance required for deposits
    bool isNative;         // Whether this is native FLOW token
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
    access(all) let yieldVaultId: UInt64
    access(all) let timestamp: UInt256
    access(all) let message: String
    access(all) let vaultIdentifier: String
    access(all) let strategyIdentifier: String
}
```

### ProcessResult (Cadence)

```cadence
/// Sentinel value for "no yieldvault" (UInt64.max)
access(all) let noYieldVaultId: UInt64 = UInt64.max

access(all) struct ProcessResult {
    access(all) let success: Bool
    access(all) let yieldVaultId: UInt64  // Uses noYieldVaultId as sentinel for "no yieldvault"
    access(all) let message: String
}
```

---

## Request Processing Flows

### CREATE_YIELDVAULT

```
┌─────────────┐  ┌─────────────────────-──┐  ┌──────────────────┐  ┌──────────────────┐
│  EVM User   │  │ FlowYieldVaultsRequests│  │FlowYieldVaultsEVM│  │ Flow YieldVaults │
└──────┬──────┘  └───────────┬─────────-──┘  └────────┬─────────┘  └────────┬─────────┘
       │                     │                        │                     │
       │ createYieldVault(   │                        │                     │
       │ token, amount,      │                        │                     │
       │ vault, strategy)    │                        │                     │
       │────────────────────▶│                        │                     │
       │                     │ Escrow funds           │                     │
       │                     │ Create PENDING request │                     │
       │◀────────────────────│                        │                     │
       │     requestId       │                        │                     │
       │                     │                        │                     │
       │                     │   getPendingRequests   │                     │
       │                     │◀───────────────────────│                     │
       │                     │     [EVMRequest]       │                     │
       │                     │───────────────────────▶│                     │
       │                     │                        │                     │
       │                     │   startProcessing(id)  │                     │
       │                     │◀───────────────────────│                     │
       │                     │ Mark PROCESSING        │                     │
       │                     │ Deduct user balance    │                     │
       │                     │───────────────────────▶│                     │
       │                     │                        │                     │
       │                     │                        │ COA.withdraw(amount)│
       │                     │                        │────────────────────▶│
       │                     │                        │      $FLOW          │
       │                     │                        │◀────────────────────│
       │                     │                        │                     │
       │                     │                        │ createYieldVault()  │
       │                     │                        │────────────────────▶│
       │                     │                        │   yieldVaultId      │
       │                     │                        │◀────────────────────│
       │                     │                        │                     │
       │                     │                        │ Store yieldVaultId  │
       │                     │                        │    mapping          │
       │                     │                        │                     │
       │                     │ completeProcessing(    │                     │
       │                     │   id, true,            │                     │
       │                     │   yieldVaultId, msg)   │                     │
       │                     │◀───────────────────────│                     │
       │                     │ Mark COMPLETED         │                     │
       │                     │ Register YieldVault    │                     │
       │                     │───────────────────────▶│                     │
```

### DEPOSIT_TO_YIELDVAULT

```
1. User calls depositToYieldVault(yieldVaultId, token, amount)
2. Contract validates YieldVault exists (ownership not required)
3. Contract escrows funds, creates PENDING request
4. Worker fetches request via getPendingRequestsUnpacked()
5. Worker does not require ownership for deposits (permissionless)
6. Worker calls startProcessing() → PROCESSING, balance deducted
7. COA withdraws funds from its balance
8. Worker deposits to YieldVault via YieldVaultManager
9. Worker calls completeProcessing() → COMPLETED
```

### WITHDRAW_FROM_YIELDVAULT

```
1. User calls withdrawFromYieldVault(yieldVaultId, amount)
2. Contract validates YieldVault ownership
3. Contract creates PENDING request (no escrow needed)
4. Worker fetches request via getPendingRequestsUnpacked()
5. Worker validates YieldVault ownership
6. Worker calls startProcessing() → PROCESSING
7. Worker withdraws from YieldVault via YieldVaultManager
8. Worker bridges funds to EVM via COA.deposit()
9. COA transfers $FLOW directly to user's EVM address
10. Worker calls completeProcessing() → COMPLETED
```

### CLOSE_YIELDVAULT

```
1. User calls closeYieldVault(yieldVaultId)
2. Contract validates YieldVault ownership
3. Contract creates PENDING request (amount = 0)
4. Worker fetches request via getPendingRequestsUnpacked()
5. Worker validates YieldVault ownership
6. Worker calls startProcessing() → PROCESSING
7. Worker closes YieldVault via YieldVaultManager, receives all funds
8. Worker bridges funds to EVM via COA.deposit()
9. COA transfers all $FLOW to user's EVM address
10. Worker removes YieldVault from ownership mappings
11. Worker calls completeProcessing() → COMPLETED
12. Contract unregisters YieldVault ownership
```

### Request Cancellation

```
1. User calls cancelRequest(requestId)
2. Contract validates ownership and PENDING status
3. Contract marks request as FAILED
4. Contract moves escrowed funds from pendingUserBalances to claimableRefunds
5. Contract decrements pending request count
6. User calls claimRefund(tokenAddress) to withdraw funds
```

### Refunds & Claiming

All refund scenarios use a pull pattern - funds are credited to `claimableRefunds` and must be withdrawn by the user via `claimRefund(tokenAddress)`:

| Scenario | What Happens |
|----------|--------------|
| After `startProcessing()` (failed CREATE/DEPOSIT) | Funds credited to `claimableRefunds` |
| User cancels request | Funds moved from `pendingUserBalances` to `claimableRefunds` |
| Admin drops request | Funds moved from `pendingUserBalances` to `claimableRefunds` |
| WITHDRAW/CLOSE | No escrowed funds on EVM side, so refunds are not applicable |

**Important:** `claimRefund()` only withdraws from `claimableRefunds`. It does NOT touch funds in `pendingUserBalances` (escrowed for active pending requests).

---

## Two-Phase Commit

The bridge uses a two-phase commit pattern for atomic state management:

### Phase 1: startProcessing()

```solidity
function startProcessing(uint256 requestId) external onlyAuthorizedCOA {
    // 1. Validate request exists and is PENDING
    // 2. Mark as PROCESSING
    // 3. For CREATE_YIELDVAULT/DEPOSIT_TO_YIELDVAULT: Deduct user balance and transfer to COA
    // 4. Emit RequestProcessed event
}
```

**Purpose:** Prevents double-spending by atomically deducting user balance before Cadence operations begin.

### Phase 2: completeProcessing()

```solidity
function completeProcessing(
    uint256 requestId,
    bool success,
    uint64 yieldVaultId,
    string calldata message
) external onlyAuthorizedCOA {
    // 1. Validate request is PROCESSING
    // 2. Mark as COMPLETED or FAILED
    // 3. On failure: Credit claimableRefunds (user must call claimRefund)
    // 4. On CREATE_YIELDVAULT success: Register YieldVault ownership
    // 5. On CLOSE_YIELDVAULT success: Unregister YieldVault ownership
    // 6. Remove from pending queue
    // 7. Emit RequestProcessed event
}
```

**Purpose:** Finalizes the operation with proper cleanup. On failure, refunds are credited for later claim; cross-VM flow is not atomic.

---

## Adaptive Scheduling

### Delay Thresholds

| Pending Requests | Delay (seconds) | Description |
|------------------|-----------------|-------------|
| >= 11 | 3 | High load - rapid processing |
| >= 5 | 5 | Medium load |
| >= 1 | 7 | Low load |
| 0 | 30 | Idle - minimal overhead |

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

### Execution Effort Calculation

The handler dynamically calculates execution effort based on the maximum requests per transaction:

```cadence
access(all) fun calculateExecutionEffortAndPriority(_ requestCount: Int): {String: AnyStruct} {
    let calculated = self.baseEffortPerRequest * UInt64(requestCount) + self.baseOverhead
    
    // If calculated > 7500, need High priority (max 9999)
    // Otherwise use Medium priority (max 7500)
    if calculated > 7500 {
        let capped = calculated < 9999 ? calculated : 9999
        return {
            "effort": capped,
            "priority": 0 as UInt8  // High priority
        }
    } else {
        return {
            "effort": calculated,
            "priority": 1 as UInt8  // Medium priority
        }
    }
}
```

When idle (no pending requests), the handler uses Medium priority to ensure sufficient computation budget. The execution effort is set to the computed value (based on `maxRequestsPerTx`) but capped at `idleExecutionEffort` (5000, suitable for Medium priority). This ensures efficient handling of burst arrivals while providing adequate computation resources.

---

## Balance Queries

### EVM Side

```solidity
// User's escrowed balance (funds tied to active pending requests)
function getUserPendingBalance(address user, address tokenAddress) returns (uint256);

// User's claimable refund (funds available to withdraw via claimRefund)
function getClaimableRefund(address user, address tokenAddress) returns (uint256);

// Pending request count
function getPendingRequestCount() returns (uint256);

// User's pending request count
function getUserPendingRequestCount(address user) returns (uint256);

// User's YieldVault Ids
function getYieldVaultIdsForUser(address user) returns (uint64[] memory);

// Ownership check (O(1))
function doesUserOwnYieldVault(address user, uint64 yieldVaultId) returns (bool);

// Get pending request IDs array
function getPendingRequestIds() returns (uint256[] memory);

// Get single request by ID
function getRequest(uint256 requestId) returns (Request memory);

// Check if token is native FLOW
function isNativeFlow(address tokenAddress) returns (bool);

// Claim refunded funds from claimableRefunds (does NOT touch pendingUserBalances)
function claimRefund(address tokenAddress) external;
```

### Cadence Side

```cadence
// YieldVault Ids by EVM address
access(all) view fun getYieldVaultIdsForEVMAddress(_ evmAddress: String): [UInt64]

// Ownership check (O(1))
access(all) view fun doesEVMAddressOwnYieldVault(evmAddress: String, yieldVaultId: UInt64): Bool

// Handler execution statistics (FlowYieldVaultsTransactionHandler)
access(all) view fun getStats(): {String: AnyStruct}
// Returns: {"executionCount": Int, "lastExecutionTime": UFix64}
```

---

## Security

### Access Control

| Component | Mechanism | Details |
|-----------|-----------|---------|
| FlowYieldVaultsRequests | `onlyAuthorizedCOA` | Only COA can call processing functions |
| FlowYieldVaultsRequests | `onlyOwner` | Admin functions restricted to owner |
| FlowYieldVaultsRequests | `onlyAllowlisted` | Optional whitelist for users |
| FlowYieldVaultsRequests | `notBlocklisted` | Optional blacklist for users |
| FlowYieldVaultsEVM | Capability-based | Worker requires valid COA, YieldVaultManager, BetaBadge caps |
| FlowYieldVaultsTransactionHandler | Admin resource | Pause/unpause restricted to Admin holder |

### YieldVault Ownership Verification

Both EVM and Cadence maintain ownership state with O(1) lookup:

```solidity
// Solidity
mapping(address => mapping(uint64 => bool)) public userOwnsYieldVault;
```

```cadence
// Cadence
access(all) let yieldVaultOwnershipLookup: {String: {UInt64: Bool}}
```

Ownership is verified for CREATE/WITHDRAW/CLOSE. Deposits are permissionless by design.

### Fund Safety

1. **Escrow Model:** Funds held in contract until processing begins; refunds are claimable on failure
2. **Two-Phase Commit:** Balance deducted before operation, credited back on failure
3. **Cross-VM Non-Atomicity:** Funds can be in transit between EVM and Cadence; stuck PROCESSING is possible without admin recovery
4. **ReentrancyGuard:** Solidity contract protected against reentrancy

### Input Validation

```cadence
// EVMRequest validation in constructor
pre {
    requestType >= RequestType.CREATE_YIELDVAULT.rawValue &&
    requestType <= RequestType.CLOSE_YIELDVAULT.rawValue:
        "Invalid request type"

    requestType == RequestType.CLOSE_YIELDVAULT.rawValue || amount > 0:
        "Amount must be greater than 0 for non-close operations"
}
```

---

## Events

### FlowYieldVaultsRequests (Solidity)

| Event | Description |
|-------|-------------|
| `RequestCreated` | New request submitted |
| `RequestProcessed` | Request status changed |
| `RequestCancelled` | Request cancelled by user/admin; refund credited |
| `RefundCredited` | Refund became claimable (pull pattern) |
| `RefundClaimed` | User claimed a refund |
| `BalanceUpdated` | User's escrowed balance changed |
| `FundsWithdrawn` | Funds transferred out |
| `AuthorizedCOAUpdated` | COA address changed |
| `AllowlistEnabled` | Allowlist toggled |
| `BlocklistEnabled` | Blocklist toggled |
| `TokenConfigured` | Token configuration changed |
| `AddressesAddedToAllowlist` | Batch allowlist additions |
| `AddressesRemovedFromAllowlist` | Batch allowlist removals |
| `AddressesAddedToBlocklist` | Batch blocklist additions |
| `AddressesRemovedFromBlocklist` | Batch blocklist removals |
| `MaxPendingRequestsPerUserUpdated` | Config change |
| `YieldVaultIdRegistered` | New YieldVault registered |
| `RequestsDropped` | Admin dropped requests |

### FlowYieldVaultsEVM (Cadence)

| Event | Description |
|-------|-------------|
| `WorkerInitialized` | Worker created with COA |
| `FlowYieldVaultsRequestsAddressSet` | EVM contract address configured |
| `RequestsProcessed` | Batch processing completed |
| `YieldVaultCreatedForEVMUser` | New YieldVault created |
| `YieldVaultDepositedForEVMUser` | Deposit to YieldVault |
| `YieldVaultWithdrawnForEVMUser` | Withdrawal from YieldVault |
| `YieldVaultClosedForEVMUser` | YieldVault closed |
| `RequestFailed` | Request processing failed |
| `MaxRequestsPerTxUpdated` | Configuration changed |
| `WithdrawFundsFromEVMFailed` | Failed to withdraw funds from EVM |

### FlowYieldVaultsTransactionHandler (Cadence)

| Event | Description |
|-------|-------------|
| `HandlerPaused` | Processing paused |
| `HandlerUnpaused` | Processing resumed |
| `ScheduledExecutionTriggered` | Handler executed |
| `NextExecutionScheduled` | Next execution scheduled |
| `ExecutionSkipped` | Execution skipped (paused or error) |
| `AllExecutionsStopped` | All executions cancelled and fees refunded |
| `ThresholdToDelayUpdated` | Threshold config change |
| `ExecutionEffortParamsUpdated` | Execution effort parameters changed |

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
| `InvalidYieldVaultId` | YieldVault not owned by user |
| `InvalidCOAAddress` | Invalid COA address provided |
| `EmptyAddressArray` | Empty array passed to batch functions |
| `CannotAllowlistZeroAddress` | Cannot add zero address to allowlist |
| `MsgValueMustEqualAmount` | msg.value must equal amount for native FLOW |
| `MsgValueMustBeZero` | msg.value must be zero for ERC20 tokens |
| `TransferFailed` | Token transfer failed |

### Cadence Error Handling

Failed operations return `ProcessResult` with `success: false` and descriptive message. The Worker emits `RequestFailed` and calls `completeProcessing(success: false)` to credit refunds for later `claimRefund`.

---

## Configuration

### Admin Functions

#### FlowYieldVaultsRequests

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

#### FlowYieldVaultsEVM

```cadence
// Admin resource functions
access(all) fun setFlowYieldVaultsRequestsAddress(_ address: EVM.EVMAddress)
access(all) fun updateFlowYieldVaultsRequestsAddress(_ address: EVM.EVMAddress)
access(all) fun updateMaxRequestsPerTx(_ newMax: Int)  // 1-100
access(all) fun createWorker(...): @Worker
```

#### FlowYieldVaultsTransactionHandler

```cadence
// Admin resource functions
access(all) fun pause()
access(all) fun unpause()
access(all) fun setThresholdToDelay(newThresholds: {Int: UFix64})
access(all) fun setExecutionEffortParams(baseEffortPerRequest: UInt64, baseOverhead: UInt64, idleExecutionEffort: UInt64)
access(all) fun stopAll()  // Emergency: pause + cancel all scheduled executions with refunds
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
2. FlowYieldVaultsClosedBeta.BetaBadge for YieldVault creation
3. FlowYieldVaults.YieldVaultManager for managing positions
4. COA with sufficient capabilities

### Deployment Order

1. Deploy `FlowYieldVaultsRequests` on EVM with COA address
2. Deploy `FlowYieldVaultsEVM` on Cadence
3. Deploy `FlowYieldVaultsTransactionHandler` on Cadence
4. Configure `FlowYieldVaultsEVM` with EVM contract address
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
| 3.0 | Nov 2025 | Adaptive scheduling, O(1) ownership lookup |
| 3.1 | Dec 2025 | Removed parallel processing, added dynamic execution effort calculation |
