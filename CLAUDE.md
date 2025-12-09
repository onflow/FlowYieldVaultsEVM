# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flow Vaults EVM Integration is a cross-VM bridge enabling Flow EVM users to access Flow Vaults's Cadence-based yield farming protocol through asynchronous request processing. Users submit requests through a Solidity contract on Flow EVM, which are then processed by a Cadence worker that manages Tide positions (yield-generating positions) on their behalf.

## Architecture

The system operates across two VMs:

### EVM Side (Solidity)
- **FlowVaultsRequests** (`solidity/src/FlowVaultsRequests.sol`) - Request queue and fund escrow contract that accepts user requests, escrows funds, and tracks balances

### Cadence Side (Flow)
- **FlowVaultsEVM** (`cadence/contracts/FlowVaultsEVM.cdc`) - Worker contract that processes EVM requests via COA (Cadence Owned Account), manages Tide positions, and bridges funds between VMs
- **FlowVaultsTransactionHandler** (`cadence/contracts/FlowVaultsTransactionHandler.cdc`) - Auto-scheduling handler that triggers request processing at adaptive intervals based on queue depth using FlowTransactionScheduler

### Bridge Architecture
The bridge uses a **two-phase commit** pattern:
1. **startProcessing()** - Marks request as PROCESSING, deducts user balance (prevents double-spending)
2. **Execute operation** - Create/deposit/withdraw/close Tide
3. **completeProcessing()** - Marks as COMPLETED or FAILED (automatic refunds on failure)

The COA (Cadence Owned Account) is the bridge between EVM and Cadence - it's authorized to process requests and move funds between VMs.

## Development Commands

### Local Development Setup
```bash
# Start emulator and deploy full stack (Cadence + Solidity)
./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh

# The setup script will output the deployed contract address
# Export it for use in other commands:
export FLOW_VAULTS_REQUESTS_CONTRACT=<address>
```

### Testing

**Solidity Tests** (37 tests - Foundry):
```bash
cd solidity && forge test           # Run all tests
cd solidity && forge test -vvv      # Verbose output
cd solidity && forge test --match-test test_CreateTide  # Specific test
cd solidity && forge test --gas-report  # Gas analysis
```

**Cadence Tests** (19 tests - Flow CLI):
```bash
# Run all Cadence tests
./local/run_cadence_tests.sh

# Run individual test files
flow test cadence/tests/evm_bridge_lifecycle_test.cdc
flow test cadence/tests/access_control_test.cdc
flow test cadence/tests/error_handling_test.cdc
```

### Processing Requests

After users submit requests via EVM, process them with:
```bash
# Process up to 10 pending requests
flow transactions send ./cadence/transactions/process_requests.cdc 0 10 \
  --signer tidal --compute-limit 9999
```

### EVM Operations (via Forge Scripts)

Default test accounts (LOCAL ONLY - never use on mainnet):
- `0x2` (Deployer): `0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF`
- `0x3` (User A - default): `0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69`
- `0x4` (User B): `0x1efF47bc3a10a45D4B230B5d10E37751FE6AA718`

```bash
# Create Tide (defaults: 10 FLOW, User A)
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --root ./solidity \
  --sig "createTide(address)" $FLOW_VAULTS_REQUESTS_CONTRACT \
  --rpc-url http://localhost:8545 --broadcast --legacy

# With custom amount and signer
USER_PRIVATE_KEY=0x4 AMOUNT=100000000000000000000 \
  forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --root ./solidity \
  --sig "createTide(address)" $FLOW_VAULTS_REQUESTS_CONTRACT \
  --rpc-url http://localhost:8545 --broadcast --legacy

# Deposit to existing Tide
AMOUNT=20000000000000000000 \
  forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --root ./solidity \
  --sig "depositToTide(address,uint64)" $FLOW_VAULTS_REQUESTS_CONTRACT <TIDE_ID> \
  --rpc-url http://localhost:8545 --broadcast --legacy

# Withdraw from Tide
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --root ./solidity \
  --sig "withdrawFromTide(address,uint64,uint256)" $FLOW_VAULTS_REQUESTS_CONTRACT <TIDE_ID> <AMOUNT> \
  --rpc-url http://localhost:8545 --broadcast --legacy

# Close Tide
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --root ./solidity \
  --sig "closeTide(address,uint64)" $FLOW_VAULTS_REQUESTS_CONTRACT <TIDE_ID> \
  --rpc-url http://localhost:8545 --broadcast --legacy
```

### Cadence Utilities

```bash
# Check COA status
flow scripts execute ./cadence/scripts/check_coa.cdc <flow_address>

# Get COA address
flow scripts execute ./cadence/scripts/get_coa_address.cdc <flow_address>

# Check pending requests
flow scripts execute ./cadence/scripts/check_pending_requests.cdc

# Check Tide details
flow scripts execute ./cadence/scripts/check_tide_details.cdc <tide_id>

# Check worker status
flow scripts execute ./cadence/scripts/check_worker_status.cdc

# Check handler status
flow scripts execute ./cadence/scripts/scheduler/check_handler_paused.cdc

# Pause/unpause handler
flow transactions send ./cadence/transactions/scheduler/pause_transaction_handler.cdc --signer tidal
flow transactions send ./cadence/transactions/scheduler/unpause_transaction_handler.cdc --signer tidal
```

## Key Data Structures

### Request Types (enum)
- `CREATE_TIDE` (0) - Create new yield position (requires deposit)
- `DEPOSIT_TO_TIDE` (1) - Add funds to existing Tide (requires deposit)
- `WITHDRAW_FROM_TIDE` (2) - Withdraw funds from Tide
- `CLOSE_TIDE` (3) - Close Tide and withdraw all funds

### Request Status Lifecycle
`PENDING` → `PROCESSING` → `COMPLETED` (or `FAILED` with automatic refund)

### Tide Ownership
Both VMs maintain O(1) ownership lookup:
- Solidity: `mapping(address => mapping(uint64 => bool)) userOwnsTide`
- Cadence: `{String: {UInt64: Bool}} tideOwnershipLookup`

Every operation verifies ownership before execution.

## Configuration & Limits

### FlowVaultsRequests (Solidity)
- **maxPendingRequestsPerUser**: Default 10 (0 = unlimited)
- **minimumBalance**: Default 1 FLOW for native FLOW deposits
- **NATIVE_FLOW**: Sentinel address `0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF`
- **NO_TIDE_ID**: Sentinel value `type(uint64).max` for "no tide"

### FlowVaultsEVM (Cadence)
- **maxRequestsPerTx**: Default 1, max 100 (requests processed per transaction)
- **noTideId**: Sentinel value `UInt64.max` for "no tide"

### FlowVaultsTransactionHandler (Cadence)
Adaptive scheduling delays based on queue depth:
- ≥50 pending: 5s delay (high load)
- ≥20 pending: 15s delay
- ≥10 pending: 30s delay
- ≥5 pending: 45s delay
- 0 pending: 60s delay (idle)

**maxParallelTransactions**: Default 1 (for high throughput scenarios)

## Important Patterns & Conventions

### Tide Ownership Verification
Always verify ownership before operations:
```solidity
// Solidity
require(userOwnsTide[user][tideId], "InvalidTideId");
```
```cadence
// Cadence
assert(
    self.tideOwnershipLookup[evmAddressHex]?[tideId] == true,
    message: "Tide not owned by EVM address"
)
```

### Two-Phase Commit Pattern
Never skip phases when processing requests:
1. Call `startProcessing()` first (deducts balance)
2. Execute the Cadence operation
3. Call `completeProcessing()` with result (refunds on failure)

### COA Authorization
Only the authorized COA can call:
- `startProcessing()`
- `completeProcessing()`
- `dropRequests()` (emergency only)

### Access Control
- **allowlistEnabled**: Optional whitelist for request creation
- **blocklistEnabled**: Optional blacklist (takes precedence over allowlist)
- **Admin functions**: Restricted to contract owner (Solidity) or Admin resource holder (Cadence)

## Network Configuration

### Accounts (from flow.json)
- **emulator-account**: `f8d6e0586b0a20c7` (service account)
- **tidal**: `045a1763c93006ca` (deploys FlowVaultsEVM and Handler)
- **testnet-account**: `4135b56ffc55ecef` (testnet deployments)

### Networks
- **emulator**: `127.0.0.1:3569`
- **testnet**: `access.devnet.nodes.onflow.org:9000`
- **EVM Gateway (local)**: `http://localhost:8545`

### Contract Aliases
- **FlowVaultsEVM**: `045a1763c93006ca` (emulator), `4135b56ffc55ecef` (testnet)
- **FlowVaultsTransactionHandler**: Same as FlowVaultsEVM
- **FlowVaults** (dependency): `045a1763c93006ca` (emulator), `3bda2f90274dbc9b` (testnet)

## Testing Coverage

**Total: 56 tests (100% passing)**
- Solidity: 37 tests covering request lifecycle, COA operations, pagination, multi-user isolation, admin functions, allowlist/blocklist
- Cadence: 19 tests covering request processing, access control, error handling, edge cases

Test helpers available in `cadence/tests/test_helpers.cdc`.

## Dependencies

### Solidity
- Foundry toolchain
- OpenZeppelin contracts (via git submodule: `lib/openzeppelin-contracts`)
- Forge-std (via git submodule)

### Cadence
- Flow CLI
- Flow Vaults contracts (via git submodule: `lib/flow-vaults-sc`)
- Multiple Flow ecosystem contracts (see flow.json dependencies section)

### External Integrations
- **FlowEVMBridge**: Token bridging between VMs
- **FlowTransactionScheduler**: Auto-scheduling for request processing
- **FlowVaultsClosedBeta**: Beta access control (BetaBadge required for Worker creation)

## Documentation Files

- **README.md**: User-facing documentation, quick start, and usage examples
- **FLOW_VAULTS_EVM_BRIDGE_DESIGN.md**: Detailed technical design, architecture diagrams, data flows
- **TESTING.md**: Complete test suite documentation
- **EVM_INTEGRATION_IMPLEMENTATION_GUIDE.md**: Implementation guide (may contain historical implementation notes)

## Common Workflows

### Adding New Request Types
1. Update `RequestType` enum in FlowVaultsRequests.sol
2. Add corresponding case in FlowVaultsEVM.cdc `processRequests()`
3. Implement new `process<Type>()` function in Worker
4. Add tests in both Solidity and Cadence
5. Update documentation

### Debugging Failed Requests
1. Check request status: `requests[requestId]` in FlowVaultsRequests
2. Review `message` field for error details
3. Check `RequestProcessed` events on-chain
4. Review Worker logs for Cadence-side errors
5. Verify Tide ownership if applicable

### Modifying Adaptive Scheduling
1. Update `thresholdToDelay` mapping in FlowVaultsTransactionHandler.cdc
2. Use `update_threshold_to_delay.cdc` transaction
3. Test with various queue depths
4. Monitor execution timing via events

## Security Considerations

- **Fund Safety**: Two-phase commit ensures atomic balance updates with automatic refunds on failure
- **Access Control**: COA authorization, allowlist/blocklist, admin-only functions
- **Tide Ownership**: Double verification (EVM + Cadence) prevents unauthorized access
- **Reentrancy Protection**: ReentrancyGuard on Solidity contract
- **Input Validation**: Pre/post conditions on all critical functions

## Build Configuration

### Solidity (foundry.toml)
- Solc version: 0.8.20
- Optimizer: enabled (200 runs)
- Via IR: enabled for better optimization
- Remappings: OpenZeppelin contracts

### Cadence
No special build configuration - uses standard Flow CLI deployment
