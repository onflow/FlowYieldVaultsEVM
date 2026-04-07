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
                                          │ - startProcessingBatch()
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
│  │  │  - feeProviderCap (FungibleToken.Withdraw, FungibleToken.Provider)│ │  │
│  │  │                                                                 │ │  │
│  │  │  Functions:                                                     │ │  │
│  │  │  - processRequest()                                             │ │  │
│  │  │  - preprocessRequests()                                         │ │  │
│  │  │  - markRequestAsFailed()                                        │ │  │
│  │  └─────────────────────────────────────────────────────────────────┘ │  │
│  │                                                                       │  │
│  │  State:                                                               │  │
│  │  - yieldVaultRegistry: {String: {UInt64: Bool}}                │  │
│  │  - flowYieldVaultsRequestsAddress: EVM.EVMAddress?                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                              ▲                                              │
│                              │ triggers                                     │
│  ┌───────────────────────────┴─────────────────────────────────────────┐   │
│  │                   FlowYieldVaultsEVMWorkerOps                        │   │
│  │                                                                      │   │
│  │  ┌─────────────────────┐    ┌─────────────────────────────────────┐ │   │
│  │  │   SchedulerHandler  │───▶│         WorkerHandler               │ │   │
│  │  │                     │    │                                     │ │   │
│  │  │  - Recurrent job    │    │  - Processes single request         │ │   │
│  │  │  - Schedules workers│    │  - Finalizes status on EVM          │ │   │
│  │  │  - Crash recovery   │    │  - Removes from scheduledRequests   │ │   │
│  │  │  - Preprocessing    │    └─────────────────────────────────────┘ │   │
│  │  └─────────────────────┘                                            │   │
│  │                                                                      │   │
│  │  State: scheduledRequests, isSchedulerPaused                        │   │
│  │  Config: schedulerWakeupInterval (1s), maxProcessingRequests (3)    │   │
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
mapping(address => uint256[]) public pendingRequestIdsByUser;

// Balance tracking
mapping(address => mapping(address => uint256)) public pendingUserBalances;  // Escrowed for active requests
mapping(address => mapping(address => uint256)) public claimableRefunds;     // Claimable from cancelled, dropped, failed, or success-path residual refunds

// Token configuration
mapping(address => TokenConfig) public allowedTokens;
uint256 public maxPendingRequestsPerUser;
bool public paused;

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
- Execute two-phase commit (startProcessingBatch → operation → completeProcessing)
- Create, deposit to, withdraw from, and close YieldVaults
- Bridge funds between EVM and Cadence via COA
- Track YieldVault ownership by EVM address

**Key State:**
```cadence
// YieldVault ownership tracking
access(all) let yieldVaultRegistry: {String: {UInt64: Bool}}

// Configuration (stored as contract-only vars; exposed via getters)
var flowYieldVaultsRequestsAddress: EVM.EVMAddress?

// Constants
access(all) let nativeFlowEVMAddress: EVM.EVMAddress  // 0xFFfF...FfFFFfF
```

#### 3. FlowYieldVaultsEVMWorkerOps (Cadence)

Worker orchestration contract with auto-scheduling and crash recovery.

**Resources:**
- **WorkerHandler**: Processes individual requests. Scheduled by SchedulerHandler to handle one request at a time.
- **SchedulerHandler**: Recurrent job that checks for pending requests and schedules WorkerHandlers based on available capacity.

**Responsibilities:**
- Implement `FlowTransactionScheduler.TransactionHandler` interface for both handlers
- SchedulerHandler checks for pending requests at fixed intervals
- SchedulerHandler calls `preprocessRequests()` which validates and transitions requests (PENDING → PROCESSING/FAILED)
- SchedulerHandler schedules WorkerHandlers for valid requests returned by `preprocessRequests()`
- SchedulerHandler identifies panicked WorkerHandlers and marks requests as FAILED
- WorkerHandler processes a single request and updates EVM state on completion
- Sequential scheduling for same-user requests to avoid block ordering issues
- Pausable for maintenance

**Key State:**
```cadence
// In-flight request tracking
access(self) var scheduledRequests: {UInt256: ScheduledEVMRequest}  // request id → tracking info
access(self) var isSchedulerPaused: Bool

// Configuration
access(self) var schedulerWakeupInterval: UFix64  // Default: 1.0 seconds
access(self) var maxProcessingRequests: UInt8     // Default: 3 concurrent workers
access(all) let executionEffortConstants: {String: UInt64}  // Configurable execution effort values
```

**ScheduledEVMRequest:**
```cadence
access(all) struct ScheduledEVMRequest {
    access(all) let request: FlowYieldVaultsEVM.EVMRequest
    access(all) let workerTransactionId: UInt64
    access(all) let workerScheduledTimestamp: UFix64
}
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
    uint64 yieldVaultId;          // Target YieldVault Id (NO_YIELDVAULT_ID for CREATE_YIELDVAULT until completed; for others set at request creation)
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
    FAILED       // 3 - Failed (escrowed CREATE/DEPOSIT may credit a claimable refund)
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
       │                     │   getPendingRequestsUnpacked │               │
       │                     │◀───────────────────────│                     │
       │                     │     [EVMRequest]       │                     │
       │                     │───────────────────────▶│                     │
       │                     │                        │                     │
       │                     │   startProcessingBatch([id], [])  │                     │
       │                     │◀───────────────────────│                     │
       │                     │ Mark PROCESSING        │                     │
       │                     │ Deduct user balance    │                     │
       │                     │───────────────────────▶│                     │
       │                     │                        │                     │
       │                     │                        │ COA.withdraw(amount)│
       │                     │                        │ or withdrawTokens() │
       │                     │                        │────────────────────▶│
       │                     │                        │   $FLOW / ERC20     │
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
6. Worker calls startProcessingBatch() → PROCESSING, balance deducted
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
6. Worker calls startProcessingBatch() → PROCESSING
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
6. Worker calls startProcessingBatch() → PROCESSING
7. Worker closes YieldVault via YieldVaultManager, receives all funds
8. Worker bridges funds to EVM via COA.deposit()
9. COA transfers all $FLOW to user's EVM address
10. Worker removes YieldVault from ownership mappings
11. Worker calls completeProcessing() → COMPLETED
12. Contract unregisters YieldVault ownership
```

### Request Cancellation

```
1. User or admin calls cancelRequest(requestId)
2. Contract validates ownership (or admin) and PENDING status
3. Contract marks request as FAILED
4. Contract moves escrowed funds from pendingUserBalances to claimableRefunds
5. Contract decrements pending request count
6. User calls claimRefund(tokenAddress) to withdraw funds
```

### Refunds & Claiming

All refund scenarios use a pull pattern - funds are credited to `claimableRefunds` and must be withdrawn by the user via `claimRefund(tokenAddress)`:

| Scenario | What Happens |
|----------|--------------|
| After `startProcessingBatch()` (failed CREATE/DEPOSIT) | Funds credited to `claimableRefunds` |
| Successful CREATE/DEPOSIT with precision loss | Precision residual credited to `claimableRefunds` |
| User cancels request | Funds moved from `pendingUserBalances` to `claimableRefunds` |
| Admin drops request | Funds moved from `pendingUserBalances` to `claimableRefunds` |
| WITHDRAW/CLOSE | No escrowed funds on EVM side, so refunds are not applicable |

**Important:** `claimRefund()` only withdraws from `claimableRefunds`. It does NOT touch funds in `pendingUserBalances` (escrowed for active pending requests).

---

## Two-Phase Commit

The bridge uses a two-phase commit pattern for atomic state management:

### Phase 1: startProcessingBatch()

```solidity
function startProcessingBatch(uint256[] calldata successfulRequestIds, uint256[] calldata rejectedRequestIds) external onlyAuthorizedCOA {
    // 1. Mark rejectedRequestIds as FAILED
    // 2. Validate each successful request exists and is PENDING
    // 3. Mark successful requests as PROCESSING
    // 4. For CREATE_YIELDVAULT/DEPOSIT_TO_YIELDVAULT: Deduct user balance and transfer to COA
    // 5. Emit RequestProcessed events
}
```

**Purpose:** Prevents double-spending by atomically deducting user balance before Cadence operations begin.

### Phase 2: completeProcessing()

```solidity
function completeProcessing(
    uint256 requestId,
    bool success,
    uint64 yieldVaultId,
    string calldata message,
    uint256 refundAmount
) external onlyAuthorizedCOA {
    // 1. Validate request is PROCESSING
    // 2. Validate refundAmount against the request lifecycle
    // 3. Mark as COMPLETED or FAILED
    // 4. Credit claimableRefunds when a failed CREATE/DEPOSIT or success-path precision residual must stay on EVM
    // 5. On CREATE_YIELDVAULT success: Register YieldVault ownership
    // 6. On CLOSE_YIELDVAULT success: Unregister YieldVault ownership
    // 7. Remove from pending queue
    // 8. Emit RequestProcessed event
}
```

**Purpose:** Finalizes the operation with proper cleanup. Refunds are credited for later claim when a failed CREATE/DEPOSIT must be returned on EVM or when a successful CREATE/DEPOSIT leaves a precision residual on EVM; cross-VM flow is not atomic.

---

## Scheduling & Request Processing

### SchedulerHandler Workflow

The SchedulerHandler runs at a fixed interval (`schedulerWakeupInterval`, default 1 second) and performs the following:

1. **Check if paused** - Skip scheduling if `isSchedulerPaused` is true
2. **Crash recovery** - Identify WorkerHandlers that panicked and mark their requests as FAILED
3. **Check capacity** - Calculate available slots: `maxProcessingRequests - scheduledRequests.length`
4. **Fetch pending requests** - Get up to `capacity` pending requests from EVM
5. **Preprocess requests** - Call `preprocessRequests()` which validates each request, fails invalid ones, and transitions valid ones to PROCESSING
6. **Schedule workers** - Create WorkerHandler transactions for each valid request
7. **Auto-reschedule** - Schedule next SchedulerHandler execution

### WorkerHandler Workflow

Each WorkerHandler is scheduled to process a single request:

1. **Process request** - Call `worker.processRequest(request)` which handles the actual operation
2. **Remove from tracking** - Remove request from `scheduledRequests` dictionary
3. **Finalize on EVM** - The worker calls `completeProcessing()` to mark COMPLETED or FAILED

### Sequential Same-User Scheduling

When multiple requests from the same EVM user are pending, they are scheduled with sequential delays to ensure ordering:

```cadence
// Track user request count for scheduling offset
let userScheduleOffset: {String: Int} = {}
for request in requests {
    let key = request.user.toString()
    if userScheduleOffset[key] == nil {
        userScheduleOffset[key] = 0
    }
    userScheduleOffset[key] = userScheduleOffset[key]! + 1

    // Offset delay by user request count
    delay = delay + userScheduleOffset[key]! as! UFix64

    // Schedule with computed delay
    // ...
}
```

### Crash Recovery

The SchedulerHandler monitors scheduled WorkerHandlers for failures:

```cadence
// For each scheduled request:
// 1. Check if scheduled timestamp has passed
// 2. Get transaction status from manager
// 3. If status is nil (cleaned up) or not Scheduled, the worker panicked
// 4. Mark request as FAILED with error message
// 5. Remove from scheduledRequests
```

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `schedulerWakeupInterval` | 1.0s | Fixed interval between SchedulerHandler executions |
| `maxProcessingRequests` | 3 | Maximum concurrent WorkerHandlers |

### Execution Effort Constants

Execution effort values are configurable via the `executionEffortConstants` dictionary and can be updated by the Admin using `setExecutionEffortConstants(key, value)`.

| Key | Default | Description |
|-----|---------|-------------|
| `schedulerBaseEffort` | 700 | Base effort for SchedulerHandler execution |
| `schedulerPerRequestEffort` | 1000 | Additional effort per request preprocessed |
| `workerCreateYieldVaultRequestEffort` | 5000 | Effort for CREATE_YIELDVAULT requests |
| `workerDepositRequestEffort` | 2000 | Effort for DEPOSIT_TO_YIELDVAULT requests |
| `workerWithdrawRequestEffort` | 2000 | Effort for WITHDRAW_FROM_YIELDVAULT requests |
| `workerCloseYieldVaultRequestEffort` | 5000 | Effort for CLOSE_YIELDVAULT requests |

Priority is dynamically determined based on execution effort:
- **Low**: effort ≤ 2500
- **Medium**: 2500 < effort < 7500
- **High**: effort ≥ 7500

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

// Get pending requests in unpacked arrays (pagination)
function getPendingRequestsUnpacked(uint256 startIndex, uint256 count) returns (...);

// Get pending requests for a user in unpacked arrays (includes tracked-token escrow+refund balances)
// Returns (..., address[] memory balanceTokens, uint256[] memory pendingBalances, uint256[] memory claimableRefundsArray)
function getPendingRequestsByUserUnpacked(address user) returns (...);

// Get single request by ID
function getRequest(uint256 requestId) returns (Request memory);

// Check if YieldVault Id is valid
function isYieldVaultIdValid(uint64 yieldVaultId) returns (bool);

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

// Pending requests for a specific EVM address
access(all) fun getPendingRequestsForEVMAddress(_ evmAddressHex: String): PendingRequestsInfo

// Total pending request count (public query)
access(all) fun getPendingRequestCount(): Int

// Scheduler paused status (FlowYieldVaultsEVMWorkerOps)
access(all) view fun getIsSchedulerPaused(): Bool

// Execution effort constants (FlowYieldVaultsEVMWorkerOps)
access(all) let executionEffortConstants: {String: UInt64}
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
| FlowYieldVaultsRequests | `whenNotPaused` | New request creation blocked when paused |
| FlowYieldVaultsEVM | Capability-based | Worker requires valid COA, YieldVaultManager, BetaBadge caps |
| FlowYieldVaultsEVMWorkerOps | Admin resource | Pause/unpause scheduler restricted to Admin holder |

### YieldVault Ownership Verification

Both EVM and Cadence maintain ownership state with O(1) lookup:

```solidity
// Solidity
mapping(address => mapping(uint64 => bool)) public userOwnsYieldVault;
```

```cadence
// Cadence
access(all) let yieldVaultRegistry: {String: {UInt64: Bool}}
```

Ownership is verified for WITHDRAW/CLOSE on both EVM and Cadence. Deposits are permissionless; CREATE only validates identifiers.

### Fund Safety

1. **Escrow Model:** Funds held in contract until processing begins; failed CREATE/DEPOSIT and success-path precision residuals become claimable refunds
2. **Two-Phase Commit:** Balance deducted before operation, then reconciled on completion via success/failure finalization plus any explicit refund amount
3. **Cross-VM Non-Atomicity:** Funds can be in transit between EVM and Cadence; stuck PROCESSING is possible without admin recovery
4. **ReentrancyGuard:** Solidity contract protected against reentrancy

### Input Validation

```cadence
// EVMRequest validation in constructor
pre {
    requestType >= RequestType.CREATE_YIELDVAULT.rawValue &&
    requestType <= RequestType.CLOSE_YIELDVAULT.rawValue:
        "Invalid request type"

    status >= RequestStatus.PENDING.rawValue &&
    status <= RequestStatus.FAILED.rawValue:
        "Invalid status"

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
| `Paused` | Contract paused |
| `Unpaused` | Contract unpaused |
| `YieldVaultIdRegistered` | New YieldVault registered |
| `YieldVaultIdUnregistered` | YieldVault unregistered (closed) |
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
| `WithdrawFundsFromEVMFailed` | Failed to withdraw funds from EVM |
| `EVMAllowlistStatusChanged` | Allowlist status changed on EVM |
| `EVMAllowlistUpdated` | Addresses added/removed from allowlist on EVM |
| `EVMBlocklistStatusChanged` | Blocklist status changed on EVM |
| `EVMBlocklistUpdated` | Addresses added/removed from blocklist on EVM |
| `EVMTokenConfigured` | Token configuration changed on EVM |
| `EVMAuthorizedCOAUpdated` | Authorized COA updated on EVM |
| `EVMMaxPendingRequestsPerUserUpdated` | Max pending requests per user updated on EVM |
| `EVMRequestsDropped` | Requests dropped on EVM |
| `EVMRequestCancelled` | Request cancelled on EVM |

### FlowYieldVaultsEVMWorkerOps (Cadence)

| Event | Description |
|-------|-------------|
| `SchedulerPaused` | Scheduler paused - no new workers scheduled |
| `SchedulerUnpaused` | Scheduler resumed |
| `WorkerHandlerExecuted` | WorkerHandler processed a request (includes result) |
| `SchedulerHandlerExecuted` | SchedulerHandler completed execution cycle |
| `WorkerHandlerPanicDetected` | WorkerHandler panicked, request marked as FAILED |
| `WorkerHandlerScheduled` | WorkerHandler scheduled to process a request |
| `AllExecutionsStopped` | All scheduled executions cancelled and fees refunded |

---

## Error Handling

### Solidity Errors

| Error | Cause |
|-------|-------|
| `NotAuthorizedCOA` | Non-COA calling restricted function |
| `NotInAllowlist` | User not whitelisted |
| `Blocklisted` | User is blacklisted |
| `ContractPaused` | Contract is paused |
| `AmountMustBeGreaterThanZero` | Zero amount deposit |
| `TokenNotSupported` | Unsupported token |
| `RequestNotFound` | Invalid request ID |
| `NotRequestOwner` | Cancelling another user's request |
| `CanOnlyCancelPending` | Cancelling non-pending request |
| `InvalidRequestState` | Request is not in correct state |
| `InsufficientBalance` | Not enough funds |
| `BelowMinimumBalance` | Deposit below minimum |
| `TooManyPendingRequests` | User at limit |
| `InvalidYieldVaultId` | YieldVault not owned by user |
| `InvalidCOAAddress` | Invalid COA address provided |
| `EmptyAddressArray` | Empty array passed to batch functions |
| `CannotAllowlistZeroAddress` | Cannot add zero address to allowlist |
| `EmptyVaultIdentifier` | Empty vault identifier for CREATE |
| `EmptyStrategyIdentifier` | Empty strategy identifier for CREATE |
| `NoRefundAvailable` | No refund available to claim |
| `MsgValueMustEqualAmount` | msg.value must equal amount for native FLOW |
| `MsgValueMustBeZero` | msg.value must be zero for ERC20 tokens |
| `TransferFailed` | Token transfer failed |

### Cadence Error Handling

Failed operations return `ProcessResult` with `success: false` and descriptive message. The Worker emits `RequestFailed` and calls `completeProcessing(..., refundAmount)` to credit any failed escrowed amount for later `claimRefund`. Successful CREATE/DEPOSIT requests may also credit a smaller precision-residual refund during completion.

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
function pause() external onlyOwner;
function unpause() external onlyOwner;
function dropRequests(uint256[] calldata requestIds) external onlyOwner;
```

#### FlowYieldVaultsEVM

```cadence
// Admin resource functions
access(all) fun setFlowYieldVaultsRequestsAddress(_ address: EVM.EVMAddress)
access(all) fun updateFlowYieldVaultsRequestsAddress(_ address: EVM.EVMAddress)
access(all) fun createWorker(...): @Worker
```

#### FlowYieldVaultsEVMWorkerOps

```cadence
// Admin resource functions
access(all) fun pauseScheduler()   // Stop scheduling new workers (in-flight workers continue)
access(all) fun unpauseScheduler() // Resume scheduling
access(all) fun setMaxProcessingRequests(maxProcessingRequests: UInt8)  // Set max concurrent workers
access(all) fun setExecutionEffortConstants(key: String, value: UInt64)  // Update execution effort
access(all) fun setSchedulerWakeupInterval(schedulerWakeupInterval: UFix64)  // Set scheduler interval
access(all) fun createWorkerHandler(workerCap: ...) -> @WorkerHandler
access(all) fun createSchedulerHandler(workerCap: ...) -> @SchedulerHandler
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

1. Deploy `FlowYieldVaultsRequests` on EVM with COA and WFLOW addresses
2. Deploy `FlowYieldVaultsEVM` on Cadence
3. Deploy `FlowYieldVaultsEVMWorkerOps` on Cadence
4. Configure `FlowYieldVaultsEVM` with EVM contract address
5. Create Worker with required capabilities (COA, YieldVaultManager, BetaBadge, FeeProvider)
6. Create WorkerHandler and SchedulerHandler via WorkerOps Admin
7. Register handlers with FlowTransactionScheduler Manager
8. Schedule initial WorkerHandler (for registration) and SchedulerHandler

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Initial | Basic request/response flow |
| 2.0 | - | Added two-phase commit |
| 3.0 | Nov 2025 | Adaptive scheduling, O(1) ownership lookup |
| 3.1 | Dec 2025 | Removed parallel processing, added dynamic execution effort calculation |
| 3.2 | Feb 2026 | Refactored preprocessing into `preprocessRequests()`, WorkerHandler fetches request by ID |
