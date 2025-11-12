# Flow Vaults EVM Integration

Bridge Flow EVM users to Cadence-based yield farming through asynchronous cross-VM requests.

## Quick Start
```bash
# 1. Start environment & deploy contracts
./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh

# 2. Create yield position from EVM
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCreateTide()" --rpc-url localhost:8545 --broadcast --legacy

# 3. Process request (Cadence worker)
flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal
```

## Architecture

**EVM Side:** Users deposit FLOW to `FlowVaultsRequests` contract and submit requests  
**Cadence Side:** `FlowVaultsEVM` processes requests, creates/manages Tide positions  
**Bridge:** COA (Cadence Owned Account) controls fund movement between VMs

## Request Types & Operations

All operations are performed using the unified `FlowVaultsTideOperations.s.sol` script:

### CREATE_TIDE - Open new yield position
```bash
# With default amount (10 FLOW)
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCreateTide()" --rpc-url localhost:8545 --broadcast --legacy

# With custom amount
AMOUNT=100000000000000000000 forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCreateTide()" --rpc-url localhost:8545 --broadcast --legacy
```

### DEPOSIT_TO_TIDE - Add funds to existing position
```bash
# With default amount (10 FLOW)
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runDepositToTide(uint64)" 42 --rpc-url localhost:8545 --broadcast --legacy

# With custom amount
AMOUNT=50000000000000000000 forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runDepositToTide(uint64)" 42 --rpc-url localhost:8545 --broadcast --legacy
```

### WITHDRAW_FROM_TIDE - Withdraw earnings
```bash
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runWithdrawFromTide(uint64,uint256)" 42 30000000000000000000 --rpc-url localhost:8545 --broadcast --legacy
```

### CLOSE_TIDE - Close position and return all funds
```bash
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCloseTide(uint64)" 42 --rpc-url localhost:8545 --broadcast --legacy
```

See `solidity/script/TIDE_OPERATIONS.md` for detailed usage documentation.

## Key Addresses

| Component | Address |
|-----------|---------|
| RPC | `localhost:8545` |
| FlowVaultsRequests | `0x153b84F377C6C7a7D93Bd9a717E48097Ca6Cfd11` |
| Deployer | `0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF` |
| User A | `0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69` |

## How It Works
```
EVM User → FlowVaultsRequests (escrow FLOW) → Worker polls requests → 
COA bridges funds → Create Tide on Cadence → Update EVM state
```

## Status

✅ **CREATE_TIDE** - Fully working  
🚧 **DEPOSIT/WITHDRAW/CLOSE** - In development

---

**Built on Flow** | [Docs](./docs) | [Architecture](./DESIGN.md)