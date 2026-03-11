# Flow YieldVaults EVM Integration

Cross-VM bridge enabling Flow EVM users to access Flow YieldVaults's Cadence-based yield farming protocol through asynchronous request processing.

## Overview

This bridge allows EVM users to interact with Flow YieldVaults (yield-generating positions) without leaving the EVM environment. Users submit requests through a Solidity contract, which are then processed by a Cadence worker that manages the actual YieldVault positions.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Flow EVM                                       │
│  ┌──────────────┐         ┌───────────────────────────┐                     │
│  │   EVM User   │────────▶│  FlowYieldVaultsRequests  │                     │
│  │              │         │   (Request Queue +        │                     │
│  │              │◀────────│    Fund Escrow)           │                     │
│  └──────────────┘         └─────────────┬─────────────┘                     │
│                                         │                                   │
└─────────────────────────────────────────┼───────────────────────────────────┘
                                          │ COA Bridge
┌─────────────────────────────────────────┼───────────────────────────────────┐
│                              Flow Cadence                                   │
│                                         ▼                                   │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                       FlowYieldVaultsEVM                              │  │
│  │  ┌────────────┐    ┌──────────────────┐    ┌─────────────────────┐    │  │
│  │  │   Worker   │───▶│ YieldVaultManager│───▶│  Flow YieldVaults   │    │  │
│  │  │  (+ COA)   │    │                  │    │    (YieldVaults)    │    │  │
│  │  └────────────┘    └──────────────────┘    └─────────────────────┘    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                              ▲                                              │
│  ┌───────────────────────────┴─────────────────────────────────────────┐    │
│  │                   FlowYieldVaultsEVMWorkerOps                       │    │
│  │  SchedulerHandler ──schedules──▶ WorkerHandler (per request)       │    │
│  │       (Auto-scheduling with FlowTransactionScheduler)               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Components

| Component | Description |
|-----------|-------------|
| **FlowYieldVaultsRequests** (Solidity) | Request queue and fund escrow on EVM. Accepts user requests and holds deposited funds until processed. |
| **FlowYieldVaultsEVM** (Cadence) | Worker contract that processes EVM requests, manages YieldVault positions, and bridges funds via COA. |
| **FlowYieldVaultsEVMWorkerOps** (Cadence) | Orchestration contract with SchedulerHandler (checks queue, schedules workers) and WorkerHandler (processes individual requests). Includes crash recovery for panicked workers. |
| **COA** (Cadence Owned Account) | Bridge account controlled by the Worker that moves funds between EVM and Cadence. |

## Supported Operations

| Operation | Description | Requires Deposit |
|-----------|-------------|------------------|
| `CREATE_YIELDVAULT` | Create a new yield-generating YieldVault position | Yes |
| `DEPOSIT_TO_YIELDVAULT` | Add funds to an existing YieldVault | Yes |
| `WITHDRAW_FROM_YIELDVAULT` | Withdraw funds from a YieldVault | No |
| `CLOSE_YIELDVAULT` | Close a YieldVault and withdraw all funds | No |

## Request Processing Flow

1. **User submits request** on EVM with optional fund deposit
2. **FlowYieldVaultsRequests** escrows funds and queues the request
3. **SchedulerHandler** fetches pending requests, calls `preprocessRequests()` to validate and transition (PENDING → PROCESSING), then schedules WorkerHandlers
4. **WorkerHandler** processes individual requests via `processRequest()`:
   - Execute Cadence operation (create/deposit/withdraw/close YieldVault)
   - `completeProcessing()`: Marks as COMPLETED or FAILED (on failure, credits `claimableRefunds`; user claims via `claimRefund`)
5. **Funds bridged** to user on withdrawal/close operations

## Quick Start

### Prerequisites

- Flow CLI installed
- Foundry installed
- Flow emulator or testnet access

### Local Development

```bash
# 1. Start emulator and deploy contracts
./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh

# 2. Create a YieldVault position from EVM
forge script ./solidity/script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
  --root ./solidity \
  --sig "createYieldVault(address)" $FLOW_VAULTS_REQUESTS_CONTRACT \
  --rpc-url http://localhost:8545 --broadcast --legacy

# 3. Process requests (triggers Worker)
flow transactions send ./cadence/transactions/process_requests.cdc 0 10 --signer emulator-flow-yield-vaults --compute-limit 9999
```

### Local Scripts and Sequence (Emulator)

Recommended sequence (run from repo root):

1. `./local/setup_and_run_emulator.sh`
2. `./local/deploy_full_stack.sh`
3. `./local/run_e2e_tests.sh`
4. `./local/run_admin_e2e_tests.sh`
5. `./local/run_worker_tests.sh`

Notes:
- These scripts expect `flow`, `forge`, `cast`, `curl`, `bc`, `lsof`, and `git` on PATH.
- `./local/deploy_full_stack.sh` writes the deployed EVM contract address to `./local/.deployed_contract_address`.
- `./local/deploy_full_stack.sh` also registers the default local `CREATE_YIELDVAULT` config as ID `1`.
- The E2E scripts read `./local/.deployed_contract_address` or use `FLOW_VAULTS_REQUESTS_CONTRACT` if set.

Local script reference:
- `./local/setup_and_run_emulator.sh`: Initializes submodules, clears `./db` and `./imports`, kills processes on ports 8080/8545/3569/8888, starts Flow emulator + EVM gateway, and sets up FlowYieldVaults dependencies.
- `./local/deploy_full_stack.sh`: Funds local EVM EOAs, deploys `FlowYieldVaultsRequests` to the local EVM, deploys Cadence contracts, sets up the Worker, registers the default local `CREATE_YIELDVAULT` config, and writes `./local/.deployed_contract_address`.
- `./local/run_e2e_tests.sh`: Runs end-to-end user flows (create/deposit/withdraw/close/cancel). Requires emulator/gateway running and a deployed contract address.
- `./local/run_admin_e2e_tests.sh`: Runs end-to-end admin flows (allowlist/blocklist, token config, max requests, admin cancel/drop). Requires emulator/gateway running and a deployed contract address.
- `./local/run_worker_tests.sh`: Runs scheduled worker tests (SchedulerHandler, WorkerHandler, pause/unpause, crash recovery). Requires emulator/gateway running and a deployed contract address.
- `./local/run_cadence_tests.sh`: Runs Cadence tests with `flow test`. Cleans `./db` and `./imports` first (stop emulator if you need to preserve state).
- `./local/run_solidity_tests.sh`: Runs Solidity tests with `forge test`.
- `./local/testnet-e2e.sh`: Testnet CLI for state checks and user/admin actions. Run `./local/testnet-e2e.sh --help` for commands. Uses `PRIVATE_KEY` and `TESTNET_RPC_URL` if set; admin commands require `testnet-account` in `flow.json`. Update the hardcoded `CONTRACT` address in the script when deploying a new version.
- `./local/deploy_and_verify.sh`: Testnet deploy/verify flow using COA and KMS. Requires a `.env` file, a configured `testnet-account` signer, and an initial `CREATE_YIELDVAULT` config via `INITIAL_CREATE_VAULT_CONFIG_ID`, `INITIAL_CREATE_VAULT_IDENTIFIER`, and `INITIAL_CREATE_STRATEGY_IDENTIFIER` unless you explicitly skip registration.

Testnet sequence (optional):
1. Create `.env` with the variables expected by `./local/deploy_and_verify.sh` (KMS/signing config, RPCs, etc).
2. Run `./local/deploy_and_verify.sh` to deploy and capture the EVM contract address.
3. Update the `CONTRACT` value in `./local/testnet-e2e.sh` and use `./local/testnet-e2e.sh --help` to drive actions.

### EVM Operations

All user operations are available through `FlowYieldVaultsYieldVaultOperations.s.sol`.

#### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `USER_PRIVATE_KEY` | Private key for signing transactions | `0x3` (test account) |
| `AMOUNT` | Amount in wei for create/deposit operations | `10000000000000000000` (10 FLOW) |
| `CREATE_VAULT_CONFIG_ID` | Registered `CREATE_YIELDVAULT` config ID | `1` |

#### Commands

```bash
# CREATE_YIELDVAULT - Open new yield position (default: 10 FLOW, default account)
forge script ./solidity/script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
  --root ./solidity \
  --sig "createYieldVault(address)" $FLOW_VAULTS_REQUESTS_CONTRACT \
  --rpc-url http://localhost:8545 --broadcast --legacy

# CREATE_YIELDVAULT - Custom amount (100 FLOW) and config ID with custom signer
USER_PRIVATE_KEY=0xYOUR_PRIVATE_KEY AMOUNT=100000000000000000000 CREATE_VAULT_CONFIG_ID=2 \
  forge script ./solidity/script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
  --root ./solidity \
  --sig "createYieldVault(address)" $FLOW_VAULTS_REQUESTS_CONTRACT \
  --rpc-url http://localhost:8545 --broadcast --legacy

# DEPOSIT_TO_YIELDVAULT - Add 20 FLOW to existing position
AMOUNT=20000000000000000000 \
  forge script ./solidity/script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
  --root ./solidity \
  --sig "depositToYieldVault(address,uint64)" $FLOW_VAULTS_REQUESTS_CONTRACT <YIELDVAULT_ID> \
  --rpc-url http://localhost:8545 --broadcast --legacy

# WITHDRAW_FROM_YIELDVAULT - Withdraw specific amount (15 FLOW)
forge script ./solidity/script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
  --root ./solidity \
  --sig "withdrawFromYieldVault(address,uint64,uint256)" $FLOW_VAULTS_REQUESTS_CONTRACT <YIELDVAULT_ID> 15000000000000000000 \
  --rpc-url http://localhost:8545 --broadcast --legacy

# CLOSE_YIELDVAULT - Close position and withdraw all
forge script ./solidity/script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
  --root ./solidity \
  --sig "closeYieldVault(address,uint64)" $FLOW_VAULTS_REQUESTS_CONTRACT <YIELDVAULT_ID> \
  --rpc-url http://localhost:8545 --broadcast --legacy
```

#### Default Test Accounts

| Private Key | Address | Description | Funded |
|-------------|---------|-------------|--------|
| `0x2` | `0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF` | Deployer | 50.46 FLOW |
| `0x3` | `0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69` | User A (default) | 1234.12 FLOW |
| `0x4` | `0x1efF47bc3a10a45D4B230B5d10E37751FE6AA718` | User B | 500 FLOW |
| `0x5` | `0xe1AB8145F7E55DC933d51a18c793F901A3A0b276` | User C | 500 FLOW |
| `0x6` | `0xE57bFE9F44b819898F47BF37E5AF72a0783e1141` | User D | 500 FLOW |

> **Note**: These are well-known test private keys. Never use them on mainnet or with real funds!

## Contract Addresses

| Network | Contract | Address |
|---------|----------|---------|
| Testnet | FlowYieldVaultsRequests | `0xF633C9dBf1a3964a895fCC4CA4404B6f8BA8141d` |
| Testnet | FlowYieldVaultsEVM | Deployed on Cadence |
| Testnet | FlowYieldVaultsEVMWorkerOps | Deployed on Cadence |

Source of truth for published addresses: `deployments/contract-addresses.json`.

## Testing

### Solidity Tests

```bash
cd solidity && forge test
```

Coverage includes:
- User request creation and validation
- COA authorization and operations
- Request lifecycle (pending → processing → completed/failed)
- Cancellation and refunds
- Pagination and queries
- Multi-user isolation
- Allowlist/blocklist functionality

### Cadence Tests

```bash
./local/run_cadence_tests.sh
```

Or run individual test files:

```bash
flow test cadence/tests/evm_bridge_lifecycle_test.cdc
flow test cadence/tests/access_control_test.cdc
flow test cadence/tests/error_handling_test.cdc
```

Coverage includes:
- Request lifecycle (CREATE, DEPOSIT, WITHDRAW, CLOSE)
- Access control and security boundaries
- Error handling and edge cases
- YieldVault ownership verification

### E2E Tests (Emulator)

```bash
./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh
./local/run_e2e_tests.sh
./local/run_admin_e2e_tests.sh
```

Testnet E2E uses `deployments/contract-addresses.json` to auto-load addresses (see `./local/testnet-e2e.sh`).

## Configuration

### FlowYieldVaultsRequests (Solidity)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NATIVE_FLOW` | `0xFFfF...FfFFFfF` | Sentinel address for native $FLOW |
| `maxPendingRequestsPerUser` | 10 | Max pending requests per user (0 = unlimited) |
| `minimumBalance` | 1 FLOW | Minimum deposit for native $FLOW |

### FlowYieldVaultsEVMWorkerOps (Cadence)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `schedulerWakeupInterval` | 1.0s | Fixed interval between scheduler executions |
| `maxProcessingRequests` | 3 | Maximum concurrent WorkerHandlers |


## Security

### Access Control

- **FlowYieldVaultsRequests**: Only authorized COA can process requests and withdraw funds
- **FlowYieldVaultsEVM**: Worker holds capabilities for COA, YieldVaultManager, and BetaBadge
- **YieldVault Ownership**: Verified for CREATE/WITHDRAW/CLOSE; deposits are permissionless to allow gifts/protocol deposits

### Fund Safety

- Funds are escrowed until processing begins; failed CREATE/DEPOSIT credit refunds to `claimableRefunds` (user calls `claimRefund`)
- Two-phase commit keeps EVM-side balance updates consistent; cross-VM flow is not atomic
- Request cancellation and admin drop move escrowed funds to `claimableRefunds` (pull pattern)

### Access Lists

- **Allowlist**: Optional whitelist for request creation
- **Blocklist**: Optional blacklist to block specific addresses

## Documentation

- [Frontend Integration](./FRONTEND_INTEGRATION.md) - Guide for frontend developers
- [Architecture Design](./FLOW_YIELD_VAULTS_EVM_BRIDGE_DESIGN.md) - Detailed bridge design and data flows
- [Testing](./TESTING.md) - Test suite documentation

## License

MIT
