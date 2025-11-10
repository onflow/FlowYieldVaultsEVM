# Flow Vaults EVM Integration

Bridge Flow EVM users to Cadence-based yield farming through asynchronous cross-VM requests.

## Quick Start
```bash
# 1. Start environment & deploy contracts
./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh

# 2. Create yield position from EVM
forge script ./solidity/script/CreateTideRequest.s.sol --rpc-url localhost:8545 --broadcast --legacy

# 3. Process request (Cadence worker)
flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal
```

## Architecture

**EVM Side:** Users deposit FLOW to `FlowVaultsRequests` contract and submit requests  
**Cadence Side:** `FlowVaultsEVM` processes requests, creates/manages Tide positions  
**Bridge:** COA (Cadence Owned Account) controls fund movement between VMs

## Request Types

- `CREATE_TIDE` - Open new yield position
- `DEPOSIT_TO_TIDE` - Add funds to existing position
- `WITHDRAW_FROM_TIDE` - Withdraw earnings
- `CLOSE_TIDE` - Close position and return all funds

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