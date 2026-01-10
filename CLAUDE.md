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
2. **FlowYieldVaultsTransactionHandler.cdc** triggers `Worker.processRequests()` on schedule
3. **FlowYieldVaultsEVM.cdc** Worker fetches pending requests via `getPendingRequestsUnpacked()`
4. **Two-phase commit**: `startProcessing()` marks PROCESSING and deducts balance, `completeProcessing()` marks COMPLETED/FAILED (refunds credited to `claimableRefunds` on failure)

### Contract Components

| Contract                                | Location             | Purpose                             |
| --------------------------------------- | -------------------- | ----------------------------------- |
| `FlowYieldVaultsRequests.sol`           | `solidity/src/`      | EVM request queue + fund escrow     |
| `FlowYieldVaultsEVM.cdc`                | `cadence/contracts/` | Cadence worker processing requests  |
| `FlowYieldVaultsTransactionHandler.cdc` | `cadence/contracts/` | Auto-scheduler with adaptive delays |

### Key Design Patterns

- **COA Bridge**: Cadence Owned Account bridges funds between EVM and Cadence via FlowEVMBridge
- **Sentinel Values**: `NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF`, `NO_YIELDVAULT_ID = type(uint64).max`
- **Ownership Tracking**: Parallel mappings on both EVM (`userOwnsYieldVault`) and Cadence (`yieldVaultOwnershipLookup`) for O(1) lookups
- **Adaptive Scheduling**: TransactionHandler adjusts delay based on pending count (3s for >10, 5s for >=5, 7s for >=1, 30s idle)
- **Dynamic Execution Effort**: `baseEffortPerRequest * maxRequestsPerTx + baseOverhead`

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
| FlowYieldVaultsRequests (EVM)     | `0xBA0D3CF51d099163cb5DA56F0E3d80EbF2125A9b` |
| FlowYieldVaultsEVM (Cadence)      | `df111ffc5064198a`                           |
| FlowYieldVaultsTransactionHandler | `df111ffc5064198a`                           |

## Dependencies

This project depends on `lib/FlowYieldVaults` (git submodule) which contains the core YieldVaults Cadence protocol including `FlowYieldVaults.cdc` and `FlowYieldVaultsClosedBeta.cdc`.
