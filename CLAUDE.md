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
cd solidity && forge fmt            # Format code
```

### Cadence (Flow CLI)
```bash
./local/run_cadence_tests.sh        # Run all Cadence tests
flow test cadence/tests/<file>.cdc  # Run single test file
flow deps install --skip-alias --skip-deployments  # Install dependencies
```

### Local Development
```bash
./local/setup_and_run_emulator.sh   # Start emulator
./local/deploy_full_stack.sh        # Deploy all contracts
./local/run_solidity_tests.sh       # Run Solidity tests
```

## Architecture

### Cross-VM Request Flow
1. **EVM User** calls `FlowYieldVaultsRequests.sol` (creates request, escrows funds)
2. **FlowYieldVaultsTransactionHandler.cdc** triggers `Worker.processRequests()` on schedule
3. **FlowYieldVaultsEVM.cdc** Worker fetches requests, executes Cadence operations
4. **Two-phase commit**: `startProcessing()` marks PROCESSING, `completeProcessing()` finalizes

### Contract Components

| Contract | Location | Purpose |
|----------|----------|---------|
| `FlowYieldVaultsRequests.sol` | `solidity/src/` | EVM request queue + fund escrow |
| `FlowYieldVaultsEVM.cdc` | `cadence/contracts/` | Cadence worker processing requests |
| `FlowYieldVaultsTransactionHandler.cdc` | `cadence/contracts/` | Auto-scheduler with adaptive delays |

### Key Design Patterns

- **COA Bridge**: Cadence Owned Account bridges funds between EVM and Cadence
- **Sentinel Values**: `NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF`, `NO_YIELDVAULT_ID = type(uint64).max`
- **Ownership Tracking**: Parallel mappings on both EVM (`userOwnsYieldVault`) and Cadence (`yieldVaultOwnershipLookup`) for O(1) lookups

### Request Types (must stay synchronized between contracts)
```
0: CREATE_YIELDVAULT      (requires deposit)
1: DEPOSIT_TO_YIELDVAULT  (requires deposit)
2: WITHDRAW_FROM_YIELDVAULT
3: CLOSE_YIELDVAULT
```

## Testing Files

- `cadence/tests/evm_bridge_lifecycle_test.cdc` - Full request lifecycle
- `cadence/tests/access_control_test.cdc` - Security boundaries
- `cadence/tests/error_handling_test.cdc` - Edge cases
- `solidity/test/` - Foundry tests for request creation, COA operations, pagination

## Configuration

### flow.json
- Contracts defined in `contracts` section with aliases per network
- Dependencies imported from Flow mainnet (FlowEVMBridge, FlowToken, etc.)
- Accounts: `emulator-account`, `emulator-flow-yield-vaults`, `testnet-account`

### foundry.toml
- Solidity 0.8.20, optimizer enabled (200 runs), via_ir enabled
- OpenZeppelin contracts via remapping `@openzeppelin/contracts/`

## Deployment Addresses

| Network | Contract | Address |
|---------|----------|---------|
| Testnet | FlowYieldVaultsRequests | `0x935936B21B397902B786B55A21d3CB3863C9E814` |
| Testnet | FlowYieldVaultsEVM | `4135b56ffc55ecef` |
