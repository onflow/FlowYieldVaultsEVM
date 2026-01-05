# Flow YieldVaults EVM Integration - Copilot Instructions

## Architecture Overview

Cross-VM bridge enabling Flow EVM users to access Cadence-based yield vaults. The async request flow:

1. **EVM User** → `FlowYieldVaultsRequests.sol` (request queue + fund escrow)
2. **Scheduler** → `FlowYieldVaultsTransactionHandler.cdc` triggers processing
3. **Worker** → `FlowYieldVaultsEVM.cdc` fetches requests via COA, executes Cadence ops
4. **Two-phase commit**: `startProcessing()` → execute → `completeProcessing()`

## Critical Constants (must stay synchronized)

```solidity
// Solidity sentinel values
address NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
uint64 NO_YIELDVAULT_ID = type(uint64).max;
```

```cadence
// Cadence equivalents
let nativeFlowEVMAddress: EVM.EVMAddress  // same as NATIVE_FLOW
let noYieldVaultId: UInt64 = UInt64.max
```

Request types (0-3) and status enums must match exactly between contracts.

## Build & Test Commands

```bash
# Solidity (Foundry)
cd solidity && forge build && forge test -vvv

# Cadence - MUST clean imports first
./local/run_cadence_tests.sh  # Cleans imports, installs deps, runs all tests
flow test cadence/tests/<file>.cdc  # Single test (after deps installed)

# Local full stack
./local/setup_and_run_emulator.sh  # Start emulator (wait for EVM gateway)
./local/deploy_full_stack.sh       # Deploy all contracts
```

## Key Patterns

### Ownership Tracking (Dual-state)

Both contracts maintain parallel ownership mappings for O(1) lookups:

- Solidity: `userOwnsYieldVault[address][yieldVaultId]`
- Cadence: `yieldVaultOwnershipLookup[evmAddrString][yieldVaultId]`

### COA Bridge Pattern

Worker holds `coaCap` capability to:

- Call EVM contracts (`EVM.Call`)
- Withdraw FLOW from EVM (`EVM.Withdraw`)
- Bridge tokens (`EVM.Bridge`)

### Adaptive Scheduling

`FlowYieldVaultsTransactionHandler` adjusts delay based on queue depth:

- `≥11 pending`: 3s delay
- `≥5 pending`: 5s delay
- `≥1 pending`: 7s delay
- `0 pending`: 30s idle delay

## File Structure

| File                                                      | Purpose                                           |
| --------------------------------------------------------- | ------------------------------------------------- |
| `solidity/src/FlowYieldVaultsRequests.sol`                | EVM request queue + escrow                        |
| `cadence/contracts/FlowYieldVaultsEVM.cdc`                | Worker + YieldVaultManager                        |
| `cadence/contracts/FlowYieldVaultsTransactionHandler.cdc` | Auto-scheduler                                    |
| `cadence/tests/test_helpers.cdc`                          | Shared test utilities (deployContracts, setupCOA) |

## Testing Notes

- Cadence tests require `flow deps install --skip-alias --skip-deployments` before running
- Tests use mock EVM addresses like `0x0000...0011`
- Test accounts use well-known private keys (`0x2`-`0x6`) - **never use on mainnet**
- Always clean `./imports/` and `./db/` directories before running Cadence tests

## Common Gotchas

1. **Amount units**: EVM uses wei (10^18), Cadence uses UFix64. Conversion required.
2. **Type identifiers**: Vault/strategy identifiers are Cadence type strings like `A.xxx.FlowToken.Vault`
3. **Request IDs start at 1**, not 0 (Solidity `nextRequestId` initialized to 1)
4. **Pending requests array**: Must be managed carefully - pagination via `getPendingRequestsUnpacked(offset, limit)`
