# Flow Vaults Cross-VM Bridge: Production Design

**Purpose**: Enable Flow EVM users to interact with Flow Vaults's Cadence-based yield protocol through an asynchronous cross-VM bridge.

**Model**: EVM users deposit FLOW and submit requests to a Solidity contract. A Cadence worker periodically processes these requests, bridges funds via COA, and manages Tide positions on their behalf.

---

## Architecture

### Core Components

**1. FlowVaultsRequests** (Solidity - Flow EVM)
- Request queue and fund escrow
- Accepts CREATE_TIDE, DEPOSIT_TO_TIDE, WITHDRAW_FROM_TIDE, CLOSE_TIDE requests
- Tracks user balances and pending requests
- Only authorized COA can withdraw escrowed funds

**2. FlowVaultsEVM** (Cadence)
- Worker that processes EVM requests on Cadence
- Polls FlowVaultsRequests contract at adaptive intervals
- Creates and manages Tide positions for EVM users
- Bridges FLOW between VMs via COA

**3. COA (Cadence Owned Account)**
- Bridge account controlled by FlowVaultsEVM Worker
- Withdraws escrowed funds from FlowVaultsRequests
- Executes Tide operations in Cadence
- Returns withdrawn funds directly to EVM users

**4. FlowVaultsTransactionHandler** (Cadence)
- Scheduled transaction handler with auto-scheduling
- Adapts processing frequency based on queue depth
- Pauses/resumes processing via admin controls

![Flow Vaults EVM Bridge Design](./create_tide.png)

---

## Data Structures

### FlowVaultsRequests (Solidity)

```solidity
struct Request {
    uint256 id;
    address user;
    RequestType requestType;      // CREATE_TIDE | DEPOSIT_TO_TIDE | WITHDRAW_FROM_TIDE | CLOSE_TIDE
    RequestStatus status;         // PENDING | COMPLETED | FAILED
    address tokenAddress;         // NATIVE_FLOW constant for $FLOW
    uint256 amount;
    uint64 tideId;               // For DEPOSIT/WITHDRAW/CLOSE operations
    uint256 timestamp;
    string message;              // Status details or error message
    string vaultIdentifier;      // Cadence vault type
    string strategyIdentifier;   // Cadence strategy type
}

// Key mappings
mapping(address => mapping(address => uint256)) public pendingUserBalances;
mapping(uint256 => Request) public requests;
uint256[] public pendingRequestIds;
```

### FlowVaultsEVM (Cadence)

```cadence
access(all) resource Worker {
    access(self) let coa: @EVM.CadenceOwnedAccount
    access(self) let tideManager: @FlowVaults.TideManager
    access(self) let betaBadge: &FlowVaultsClosedBeta.BetaBadge
    
    // Process up to MAX_REQUESTS_PER_TX requests
    access(all) fun processRequests()
    
    // Handle individual request types
    access(self) fun handleCreateTide(request: EVMRequest)
    access(self) fun handleDepositToTide(request: EVMRequest)
    access(self) fun handleWithdrawFromTide(request: EVMRequest)
    access(self) fun handleCloseTide(request: EVMRequest)
}

// Tide storage by EVM address
access(all) let tidesByEVMAddress: {String: [UInt64]}
```

---

## Request Processing Flow

### CREATE_TIDE
```
1. EVM User → FlowVaultsRequests.createTideRequest(amount, vaultId, strategyId)
2. Contract escrows FLOW and creates PENDING request
3. Worker polls → fetches pending requests
4. COA withdraws FLOW from FlowVaultsRequests
5. Worker creates Tide in Cadence via FlowVaults
6. Worker stores Tide ID mapped to user's EVM address
7. Worker updates request status to COMPLETED
```

### WITHDRAW_FROM_TIDE
```
1. EVM User → FlowVaultsRequests.withdrawFromTideRequest(tideId, amount)
2. Worker polls → fetches pending requests
3. Worker validates Tide ownership
4. Worker withdraws from Tide in Cadence
5. COA bridges FLOW back to EVM
6. COA transfers FLOW directly to user's EVM address
7. Worker updates request status to COMPLETED
```

### DEPOSIT_TO_TIDE
```
1. EVM User → FlowVaultsRequests.depositToTideRequest(tideId, amount)
2. Contract escrows FLOW
3. Worker polls → fetches request
4. COA withdraws FLOW from FlowVaultsRequests
5. Worker deposits to existing Tide
6. Worker updates request status to COMPLETED
```

### CLOSE_TIDE
```
1. EVM User → FlowVaultsRequests.closeTideRequest(tideId)
2. Worker polls → fetches request
3. Worker closes Tide in Cadence
4. COA bridges all FLOW back to EVM
5. COA transfers FLOW to user's EVM address
6. Worker removes Tide from mapping
7. Worker updates request status to COMPLETED
```

---

## Adaptive Scheduling

The bridge uses **self-scheduling** with adaptive frequency based on queue depth:

### Scheduling Logic

```cadence
access(all) contract FlowVaultsTransactionHandler {
    // 5 delay levels (seconds)
    access(all) let DELAY_LEVELS: [UFix64]      // [3600.0, 600.0, 120.0, 30.0, 10.0]
    access(all) let LOAD_THRESHOLDS: [Int]      // [0, 5, 20, 50, 100]
    
    access(all) fun determineDelayForPendingCount(_ count: Int): UFix64 {
        // Returns appropriate delay based on queue depth
        // 0 requests → 1 hour
        // 1-5 requests → 10 minutes
        // 6-20 requests → 2 minutes
        // 21-50 requests → 30 seconds
        // 50+ requests → 10 seconds
    }
}
```

### Characteristics

| Queue Depth | Delay | Processing Rate |
|-------------|-------|-----------------|
| 0 requests | 1 hour | Minimal overhead |
| 1-5 requests | 10 minutes | Low activity |
| 6-20 requests | 2 minutes | Regular usage |
| 21-50 requests | 30 seconds | High activity |
| 50+ requests | 10 seconds | Peak demand |

### Benefits
- **Gas efficient**: Fixed batch size (MAX_REQUESTS_PER_TX, default 1)
- **Fully autonomous**: No off-chain monitoring required
- **Cost-effective**: Reduces fees during low usage
- **Adaptive**: Scales automatically with demand

---

## Balance Queries

### Separated State Model

Each VM maintains independent state:

**EVM Side** - Query escrowed funds:
```solidity
function getUserBalance(address user, address token) external view returns (uint256);
function getPendingRequestCount() external view returns (uint256);
```

**Cadence Side** - Query active Tide positions:
```cadence
access(all) fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64]
access(all) fun getTideDetails(tideId: UInt64): TideDetails // via FlowVaults
```

Users query both sides for complete picture:
- **Pending**: Funds escrowed in EVM awaiting processing
- **Active**: Tide positions with current balances and yield

---

## Security

### Access Control
- COA owned and controlled exclusively by FlowVaultsEVM Worker
- Only COA can withdraw from FlowVaultsRequests (onlyAuthorizedCOA modifier)
- Tides are non-transferable, tagged to EVM addresses
- Request validation prevents duplicate processing

### Fund Safety
- Funds remain escrowed until successful processing
- Failed operations rollback without losing funds
- Direct atomic transfers on withdrawals (no intermediate steps)

### Error Handling
- RequestFailed events with detailed reasons
- Circuit breaker for repeated failures
- Manual admin override capability

---

## Key Design Decisions

**1. Asynchronous Processing**
- Pull-based model: Worker polls for requests
- Enables batch processing for gas efficiency
- Fully on-chain, no off-chain dependencies

**2. Separated State Management**
- EVM tracks escrowed funds
- Cadence holds actual Tide positions
- No complex cross-VM synchronization

**3. Fixed Batch Processing**
- MAX_REQUESTS_PER_TX limits requests per transaction
- Prevents gas limit issues
- Predictable performance characteristics

**4. Adaptive Scheduling**
- Self-scheduling based on queue depth
- Scales frequency with demand
- Reduces costs during low activity

**5. Native FLOW Focus**
- Initial implementation supports native $FLOW only
- Uses constant NATIVE_FLOW address pattern
- Extensible for future ERC-20 support

---

## Testing

Comprehensive test coverage (42 tests, 100% passing):

- **Request Lifecycle** (8 tests): CREATE, DEPOSIT, WITHDRAW, CLOSE flows
- **Access Control** (15 tests): Authorization, ownership, security boundaries
- **Error Handling** (19 tests): Edge cases, failures, rollbacks

See `TESTING.md` for complete test documentation.

---

**Version**: 3.0 (pre-audit)  
**Status**: Deployed on Flow Testnet  
**Last Updated**: November 17, 2025
