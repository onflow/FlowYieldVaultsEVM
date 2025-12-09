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
│  │              FlowYieldVaultsTransactionHandler                      │    │
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
| **FlowYieldVaultsTransactionHandler** (Cadence) | Auto-scheduling handler that triggers request processing at adaptive intervals based on queue depth. |
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
3. **FlowYieldVaultsTransactionHandler** triggers `worker.processRequests()` at scheduled intervals
4. **Worker.processRequests()** fetches pending requests from EVM via `getPendingRequestsUnpacked()`
5. **For each request**, two-phase commit:
   - `startProcessing()`: Marks request as PROCESSING, deducts user balance (for CREATE_YIELDVAULT/DEPOSIT_TO_YIELDVAULT)
   - Execute Cadence operation (create/deposit/withdraw/close YieldVault)
   - `completeProcessing()`: Marks as COMPLETED or FAILED (refunds on failure)
6. **Funds bridged** to user on withdrawal/close operations

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

### EVM Operations

All user operations are available through `FlowYieldVaultsYieldVaultOperations.s.sol`.

#### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `USER_PRIVATE_KEY` | Private key for signing transactions | `0x3` (test account) |
| `AMOUNT` | Amount in wei for create/deposit operations | `10000000000000000000` (10 FLOW) |
| `VAULT_IDENTIFIER` | Cadence vault type identifier | `A.0ae53cb6e3f42a79.FlowToken.Vault` |
| `STRATEGY_IDENTIFIER` | Cadence strategy type identifier | `A.045a1763c93006ca.FlowYieldVaultsStrategies.TracerStrategy` |

#### Commands

```bash
# CREATE_YIELDVAULT - Open new yield position (default: 10 FLOW, default account)
forge script ./solidity/script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
  --root ./solidity \
  --sig "createYieldVault(address)" $FLOW_VAULTS_REQUESTS_CONTRACT \
  --rpc-url http://localhost:8545 --broadcast --legacy

# CREATE_YIELDVAULT - Custom amount (100 FLOW) with custom signer
USER_PRIVATE_KEY=0xYOUR_PRIVATE_KEY AMOUNT=100000000000000000000 \
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
| Testnet | FlowYieldVaultsRequests | `0x935936B21B397902B786B55A21d3CB3863C9E814` |
| Testnet | FlowYieldVaultsEVM | Deployed on Cadence |
| Testnet | FlowYieldVaultsTransactionHandler | Deployed on Cadence |

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

## Configuration

### FlowYieldVaultsRequests (Solidity)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NATIVE_FLOW` | `0xFFfF...FfFFFfF` | Sentinel address for native $FLOW |
| `maxPendingRequestsPerUser` | 10 | Max pending requests per user (0 = unlimited) |
| `minimumBalance` | 1 FLOW | Minimum deposit for native $FLOW |

### FlowYieldVaultsEVM (Cadence)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxRequestsPerTx` | 1 | Requests processed per transaction (1-100) |

### FlowYieldVaultsTransactionHandler (Cadence)

| Pending Requests | Delay | Description |
|------------------|-------|-------------|
| ≥50 | 5s | High load |
| ≥20 | 15s | Medium-high load |
| ≥10 | 30s | Medium load |
| ≥5 | 45s | Low load |
| 0 | 60s | Idle |

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxParallelTransactions` | 1 | Max parallel scheduled transactions |
| `isPaused` | false | Pause/resume processing |

## Security

### Access Control

- **FlowYieldVaultsRequests**: Only authorized COA can process requests and withdraw funds
- **FlowYieldVaultsEVM**: Worker holds capabilities for COA, YieldVaultManager, and BetaBadge
- **YieldVault Ownership**: YieldVaults are tagged to EVM addresses and verified on every operation

### Fund Safety

- Funds remain escrowed until successful processing
- Two-phase commit ensures atomic balance updates
- Failed operations trigger automatic refunds
- Request cancellation returns deposited funds

### Access Lists

- **Allowlist**: Optional whitelist for request creation
- **Blocklist**: Optional blacklist to block specific addresses

## Documentation

- [Frontend Integration](./FRONTEND_INTEGRATION.md) - Guide for frontend developers
- [Architecture Design](./FLOW_VAULTS_EVM_BRIDGE_DESIGN.md) - Detailed bridge design and data flows
- [Testing](./TESTING.md) - Test suite documentation

## License

MIT
