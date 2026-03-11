# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cross-VM bridge enabling Flow EVM users to access Flow YieldVaults' Cadence-based yield farming protocol. EVM users submit requests through a Solidity contract, which are processed by a Cadence worker that manages YieldVault positions.

## Build & Test Commands

### Solidity (Foundry)

```bash
cd solidity && forge build          # Build contracts
cd solidity && forge test           # Run all tests
cd solidity && forge test -vvv      # Verbose test output
cd solidity && forge test --match-test testFunctionName  # Run single test
cd solidity && forge fmt            # Format code
```

### Cadence (Flow CLI)

```bash
./local/run_cadence_tests.sh        # Run all Cadence tests (cleans db, installs deps)
flow test cadence/tests/<file>.cdc  # Run single test file
flow deps install --skip-alias --skip-deployments  # Install dependencies
```

### Local Development

```bash
./local/setup_and_run_emulator.sh   # Start emulator
./local/deploy_full_stack.sh        # Deploy all contracts
./local/run_solidity_tests.sh       # Run Solidity tests on emulator
```

### Artifacts & Deployment

```bash
./scripts/export-artifacts.sh       # Export ABIs only
./scripts/export-artifacts.sh --network testnet --evm-address 0x...  # Export and update addresses
```

## Architecture

### Cross-VM Request Flow

1. **EVM User** calls `FlowYieldVaultsRequests.sol` (creates request, escrows funds)
2. **FlowYieldVaultsEVMWorkerOps.cdc** SchedulerHandler schedules WorkerHandlers to process requests
3. **FlowYieldVaultsEVM.cdc** Worker fetches pending requests via `getPendingRequestsUnpacked()`, then resolves `createVaultConfigId` against the local Cadence config registry for `CREATE_YIELDVAULT`
4. **Two-phase commit**: `startProcessingBatch()` marks PROCESSING and deducts balance, `completeProcessing()` marks COMPLETED/FAILED (refunds credited to `claimableRefunds` on failure)

### Contract Components

| Contract                                | Location             | Purpose                             |
| --------------------------------------- | -------------------- | ----------------------------------- |
| `FlowYieldVaultsRequests.sol`           | `solidity/src/`      | EVM request queue + fund escrow     |
| `FlowYieldVaultsEVM.cdc`                | `cadence/contracts/` | Cadence worker processing requests  |
| `FlowYieldVaultsEVMWorkerOps.cdc`       | `cadence/contracts/` | SchedulerHandler + WorkerHandler orchestration |

### Key Design Patterns

- **COA Bridge**: Cadence Owned Account bridges funds between EVM and Cadence via FlowEVMBridge
- **Immutable CREATE Configs**: EVM requests store `createVaultConfigId`; Cadence resolves identifiers locally; config onboarding should use `cadence/transactions/register_create_yieldvault_config_everywhere.cdc`
- **Sentinel Values**: `NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF`, `NO_YIELDVAULT_ID = type(uint64).max`
- **Ownership Tracking**: Parallel mappings on both EVM (`userOwnsYieldVault`) and Cadence (`yieldVaultOwnershipLookup`) for O(1) lookups
- **Scheduler/Worker Split**: SchedulerHandler runs at fixed interval, schedules WorkerHandlers for individual requests
- **Batch Preprocessing**: SchedulerHandler validates requests before scheduling workers; invalid requests fail early
- **Crash Recovery**: SchedulerHandler monitors WorkerHandler transactions and marks panicked requests as FAILED

### Request Types (must stay synchronized between contracts)

```
0: CREATE_YIELDVAULT      (requires deposit)
1: DEPOSIT_TO_YIELDVAULT  (requires deposit)
2: WITHDRAW_FROM_YIELDVAULT
3: CLOSE_YIELDVAULT
```

## Testing

### Cadence Tests

- `cadence/tests/evm_bridge_lifecycle_test.cdc` - Full request lifecycle
- `cadence/tests/access_control_test.cdc` - Security boundaries
- `cadence/tests/error_handling_test.cdc` - Edge cases
- `cadence/tests/test_helpers.cdc` - Shared test utilities

### Solidity Tests

- `solidity/test/FlowYieldVaultsRequests.t.sol` - Request creation, COA operations, pagination

## Configuration

### flow.json

- Contracts defined in `contracts` section with aliases per network (emulator, testing, testnet)
- Dependencies imported from Flow mainnet (FlowEVMBridge, FlowToken, FlowTransactionScheduler, etc.)
- Accounts: `emulator-account`, `emulator-flow-yield-vaults`, `testnet-account`

### foundry.toml

- Solidity 0.8.20, optimizer enabled (200 runs), via_ir enabled
- OpenZeppelin contracts via remapping `@openzeppelin/contracts/`

## Key Addresses

### Sentinel Values

- `NATIVE_FLOW`: `0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF` (native $FLOW token marker)
- `NO_YIELDVAULT_ID`: `type(uint64).max` / `UInt64.max` (no yieldvault sentinel)

### Testnet Deployment

| Contract                          | Address                                      |
| --------------------------------- | -------------------------------------------- |
| FlowYieldVaultsRequests (EVM)     | `0xF633C9dBf1a3964a895fCC4CA4404B6f8BA8141d` |
| FlowYieldVaultsEVM (Cadence)      | `df111ffc5064198a`                           |
| FlowYieldVaultsEVMWorkerOps       | `df111ffc5064198a`                           |

## Blockchain Execution Model (Critical for Code Review)

When reviewing this codebase, keep these fundamental blockchain properties in mind:

### Transaction Atomicity

**All blockchain transactions are atomic.** If any operation within a transaction panics/reverts, ALL state changes made during that transaction are rolled back completely. There is no "partial completion" scenario.

- In Cadence: `panic()` reverts all state changes in the transaction
- In Solidity: `revert()` or failed `require()` reverts all state changes
- This is **by design** and is the correct way to ensure data consistency

Therefore, patterns like:
```cadence
// This is SAFE - if processRequest panics, the remove never happened
scheduledRequests.remove(key: requestId)
processResult = worker.processRequest(request)  // if this panics, the line above reverts too
```

### Sequential Execution (No On-Chain Race Conditions)

**Blockchain transactions execute one at a time in a deterministic order.** There is no parallel execution within the same blockchain execution environment.

- Transactions are ordered within blocks and executed sequentially
- Two transactions cannot "race" against each other simultaneously
- What might look like a "race condition" is actually just transaction ordering, which is well-defined behavior

This means scenarios like "Transaction A completes but Transaction B sees stale state" are **impossible** within the same execution context. By the time Transaction B executes, Transaction A has either fully committed or fully reverted.

### Implications for This Codebase

1. **WorkerHandler/SchedulerHandler coordination** is safe because they run in separate transactions that execute sequentially
2. **Panic-based error handling** in `processRequest()` is the correct pattern - it ensures atomicity across Cadence and EVM state
3. **State removal before vs after processing** doesn't create race conditions - if processing fails, the entire transaction (including removal) reverts

## Dependencies

This project depends on `lib/FlowYieldVaults` (git submodule) which contains the core YieldVaults Cadence protocol including `FlowYieldVaults.cdc` and `FlowYieldVaultsClosedBeta.cdc`.
