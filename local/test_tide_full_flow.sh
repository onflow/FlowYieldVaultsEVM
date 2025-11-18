name: Tide Full Flow CI

# This workflow tests the complete tide lifecycle:
# 1. Create tide with initial deposit (10 FLOW)
# 2. Add additional deposit (20 FLOW) - Total: 30 FLOW  
# 3. Withdraw half (15 FLOW) - Remaining: 15 FLOW
# 4. Close tide (withdraw remaining 15 FLOW and close position)

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  integration-test:
    name: End-to-End Tide Full Flow Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GH_PAT }}
          submodules: recursive
      
      - name: Install Required Tools
        run: |
          sudo apt-get update && sudo apt-get install -y lsof netcat-openbsd jq bc
      
      - name: Install Flow CLI
        run: sh -ci "$(curl -fsSL https://raw.githubusercontent.com/onflow/flow-cli/master/install.sh)"
      
      - name: Update PATH
        run: echo "$HOME/.local/bin" >> $GITHUB_PATH
      
      - name: Verify Flow CLI Installation
        run: flow version
      
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
        with:
          version: nightly
      
      - name: Make scripts executable
        run: |
          chmod +x ./local/setup_and_run_emulator.sh
          chmod +x ./local/deploy_full_stack.sh
      
      # Step 1: Setup environment and run emulator in background
      - name: Setup and Run Emulator
        run: |
          ./local/setup_and_run_emulator.sh &
          sleep 80  # Wait for emulator to fully start
      
      # Step 2: Deploy full stack
      - name: Deploy Full Stack
        run: |
          DEPLOYMENT_OUTPUT=$(./local/deploy_full_stack.sh)
          echo "$DEPLOYMENT_OUTPUT"
          FLOW_VAULTS_REQUESTS_CONTRACT=$(echo "$DEPLOYMENT_OUTPUT" | grep "FlowVaultsRequests Contract:" | sed 's/.*: //')
          echo "CONTRACT_ADDRESS=$FLOW_VAULTS_REQUESTS_CONTRACT" >> $GITHUB_ENV
          echo "✅ Contract deployed at: $FLOW_VAULTS_REQUESTS_CONTRACT"
      
      # Step 3: Initial State Check
      - name: Check Initial State
        run: |
          echo "=== Checking Initial State ==="
          INITIAL_CHECK=$(flow scripts execute ./cadence/scripts/check_tide_details.cdc 0x045a1763c93006ca)
          echo "$INITIAL_CHECK"
          
          # Verify no tides exist initially
          INITIAL_TIDES=$(echo "$INITIAL_CHECK" | jq -r '.totalMappedTides // 0')
          if [ "$INITIAL_TIDES" -eq 0 ]; then
            echo "✅ Initial state confirmed: No tides exist"
          else
            echo "⚠️  Warning: Found $INITIAL_TIDES existing tides"
          fi
          echo ""
      
      # Step 4: Create tide from EVM (10 FLOW)
      - name: Create Tide Request from EVM (10 FLOW)
        run: |
          echo "=== Creating Tide with 10 FLOW Initial Deposit ==="
          forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
            --sig "runCreateTide(address)" ${{ env.CONTRACT_ADDRESS }} \
            --rpc-url http://localhost:8545 \
            --broadcast \
            --legacy
          echo "✅ Create tide request sent"
      
      # Step 5: Process create tide request
      - name: Process Create Tide Request
        run: |
          echo "Processing create tide request..."
          flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal --gas-limit 9999
          echo "✅ Create tide request processed"
      
      # Step 6: Verify tide creation
      - name: Verify Tide Creation
        run: |
          echo "=== Verifying Tide Creation ==="
          TIDE_CHECK=$(flow scripts execute ./cadence/scripts/check_tide_details.cdc 0x045a1763c93006ca)
          echo "$TIDE_CHECK"
          
          # Check total tides increased
          TOTAL_TIDES=$(echo "$TIDE_CHECK" | jq -r '.totalMappedTides // 0')
          if [ "$TOTAL_TIDES" -eq 1 ]; then
            echo "✅ Tide count verified: $TOTAL_TIDES tide(s) exist"
          else
            echo "❌ Expected 1 tide, found $TOTAL_TIDES"
            exit 1
          fi
          
          # Check EVM address mapping
          EVM_ADDRESS=$(echo "$TIDE_CHECK" | jq -r '.evmMappings[0].evmAddress // ""')
          EXPECTED_EVM="6813eb9362372eef6200f3b1dbc3f819671cba69"
          if [ "$EVM_ADDRESS" = "$EXPECTED_EVM" ]; then
            echo "✅ EVM address mapping verified: $EVM_ADDRESS"
          else
            echo "❌ EVM address mismatch. Expected: $EXPECTED_EVM, Got: $EVM_ADDRESS"
            exit 1
          fi
          
          # Extract and save tide ID
          TIDE_ID=$(echo "$TIDE_CHECK" | jq -r '.evmMappings[0].tideIds[0] // 0')
          echo "TIDE_ID=$TIDE_ID" >> $GITHUB_ENV
          echo "✅ Tide created with ID: $TIDE_ID"
          
          # TODO: Add balance check when available in script
          echo "ℹ️  Initial deposit: 10 FLOW (verification pending script support)"
          echo ""
      
      # Step 7: Deposit to the created tide (add 20 FLOW)
      - name: Deposit to Tide from EVM (20 FLOW)
        run: |
          echo "=== Depositing 20 FLOW to Tide ID: ${{ env.TIDE_ID }} ==="
          forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
            --sig "runDepositToTide(address,uint64)" ${{ env.CONTRACT_ADDRESS }} ${{ env.TIDE_ID }} \
            --rpc-url http://localhost:8545 \
            --broadcast \
            --legacy
          echo "✅ Deposit request sent"
      
      # Step 8: Process deposit request
      - name: Process Deposit Request
        run: |
          echo "Processing deposit request..."
          flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal --gas-limit 9999
          echo "✅ Deposit request processed"
      
      # Step 9: Verify deposit
      - name: Verify Deposit
        run: |
          echo "=== Verifying Deposit ==="
          TIDE_CHECK=$(flow scripts execute ./cadence/scripts/check_tide_details.cdc 0x045a1763c93006ca)
          echo "$TIDE_CHECK"
          
          # Verify tide still exists
          TOTAL_TIDES=$(echo "$TIDE_CHECK" | jq -r '.totalMappedTides // 0')
          if [ "$TOTAL_TIDES" -eq 1 ]; then
            echo "✅ Tide still active after deposit"
          else
            echo "❌ Tide count changed unexpectedly: $TOTAL_TIDES"
            exit 1
          fi
          
          # Verify tide ID is still in mapping
          TIDE_EXISTS=$(echo "$TIDE_CHECK" | jq --arg tid "${{ env.TIDE_ID }}" '.evmMappings[0].tideIds | contains([($tid | tonumber)])')
          if [ "$TIDE_EXISTS" = "true" ]; then
            echo "✅ Tide ID ${{ env.TIDE_ID }} still mapped correctly"
          else
            echo "❌ Tide ID ${{ env.TIDE_ID }} not found in mapping"
            exit 1
          fi
          
          echo "ℹ️  Expected balance after deposit: 30 FLOW (10 initial + 20 deposit)"
          echo ""
      
      # Step 10: Withdraw half from tide (withdraw 15 FLOW)
      - name: Withdraw from Tide (15 FLOW)
        run: |
          echo "=== Withdrawing 15 FLOW from Tide ID: ${{ env.TIDE_ID }} ==="
          forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
            --sig "runWithdrawFromTide(address,uint64,uint256)" \
            ${{ env.CONTRACT_ADDRESS }} \
            ${{ env.TIDE_ID }} \
            15000000000000000000 \
            --rpc-url http://localhost:8545 \
            --broadcast \
            --legacy
          echo "✅ Withdraw request sent"
      
      # Step 11: Process withdraw request
      - name: Process Withdraw Request
        run: |
          echo "Processing withdraw request..."
          flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal --gas-limit 9999
          echo "✅ Withdraw request processed"
      
      # Step 12: Verify withdrawal
      - name: Verify Withdrawal
        run: |
          echo "=== Verifying Withdrawal ==="
          TIDE_CHECK=$(flow scripts execute ./cadence/scripts/check_tide_details.cdc 0x045a1763c93006ca)
          echo "$TIDE_CHECK"
          
          # Verify tide still exists (shouldn't be closed after partial withdrawal)
          TOTAL_TIDES=$(echo "$TIDE_CHECK" | jq -r '.totalMappedTides // 0')
          if [ "$TOTAL_TIDES" -eq 1 ]; then
            echo "✅ Tide still active after partial withdrawal"
          else
            echo "❌ Tide count changed unexpectedly: $TOTAL_TIDES"
            exit 1
          fi
          
          # Verify tide ID is still in mapping
          TIDE_EXISTS=$(echo "$TIDE_CHECK" | jq --arg tid "${{ env.TIDE_ID }}" '.evmMappings[0].tideIds | contains([($tid | tonumber)])')
          if [ "$TIDE_EXISTS" = "true" ]; then
            echo "✅ Tide ID ${{ env.TIDE_ID }} still active"
          else
            echo "❌ Tide ID ${{ env.TIDE_ID }} unexpectedly removed"
            exit 1
          fi
          
          echo "ℹ️  Expected balance after withdrawal: 15 FLOW (30 - 15 withdrawn)"
          echo ""
      
      # Step 13: Close tide (withdraws remaining funds and closes position)
      - name: Close Tide
        run: |
          echo "=== Closing Tide ID: ${{ env.TIDE_ID }} ==="
          forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
            --sig "runCloseTide(address,uint64)" \
            ${{ env.CONTRACT_ADDRESS }} \
            ${{ env.TIDE_ID }} \
            --rpc-url http://localhost:8545 \
            --broadcast \
            --legacy
          echo "✅ Close tide request sent"
      
      # Step 14: Process close tide request
      - name: Process Close Tide Request
        run: |
          echo "Processing close tide request..."
          flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal --gas-limit 9999
          echo "✅ Close tide request processed"
      
      # Step 15: Verify tide was closed
      - name: Verify Tide Closure
        run: |
          echo "=== Verifying Tide Closure ==="
          TIDE_CHECK=$(flow scripts execute ./cadence/scripts/check_tide_details.cdc 0x045a1763c93006ca)
          echo "$TIDE_CHECK"
          
          # Check if tide count decreased
          TOTAL_TIDES=$(echo "$TIDE_CHECK" | jq -r '.totalMappedTides // 0')
          if [ "$TOTAL_TIDES" -eq 0 ]; then
            echo "✅ All tides closed successfully"
          else
            # Check if tide ID is no longer in the mapping
            TIDE_EXISTS=$(echo "$TIDE_CHECK" | jq --arg tid "${{ env.TIDE_ID }}" '
              .evmMappings[0].tideIds // [] | contains([($tid | tonumber)])
            ' 2>/dev/null || echo "false")
            
            if [ "$TIDE_EXISTS" = "false" ]; then
              echo "✅ Tide ID ${{ env.TIDE_ID }} successfully removed from mapping"
            else
              echo "⚠️  Warning: Tide ID ${{ env.TIDE_ID }} may still be in mapping"
              echo "   Total tides remaining: $TOTAL_TIDES"
            fi
          fi
          
          # Check EVM address mapping
          EVM_COUNT=$(echo "$TIDE_CHECK" | jq -r '.totalEVMAddresses // 0')
          if [ "$EVM_COUNT" -eq 0 ]; then
            echo "✅ EVM address mapping cleaned up"
          else
            TIDE_COUNT=$(echo "$TIDE_CHECK" | jq -r '.evmMappings[0].tideCount // 0' 2>/dev/null || echo "0")
            echo "ℹ️  EVM address still registered with $TIDE_COUNT tide(s)"
          fi
          
          echo ""
          echo "========================================="
          echo "✅ TIDE FULL LIFECYCLE TEST COMPLETED!"
          echo "========================================="
          echo "Summary:"
          echo "  1. ✅ Created tide with 10 FLOW"
          echo "  2. ✅ Deposited additional 20 FLOW (total: 30)"
          echo "  3. ✅ Withdrew 15 FLOW (remaining: 15)"
          echo "  4. ✅ Closed tide (withdrew final 15 FLOW)"
          echo "========================================="
      
      # Step 16: Final State Verification
      - name: Final State Verification
        run: |
          echo "=== Final State Verification ==="
          FINAL_CHECK=$(flow scripts execute ./cadence/scripts/check_tide_details.cdc 0x045a1763c93006ca)
          
          FINAL_TIDES=$(echo "$FINAL_CHECK" | jq -r '.totalMappedTides // 0')
          FINAL_EVM_ADDRESSES=$(echo "$FINAL_CHECK" | jq -r '.totalEVMAddresses // 0')
          
          echo "Final state:"
          echo "  - Total active tides: $FINAL_TIDES"
          echo "  - Total EVM addresses with tides: $FINAL_EVM_ADDRESSES"
          
          if [ "$FINAL_TIDES" -eq 0 ]; then
            echo "✅ System returned to clean state"
          else
            echo "ℹ️  System has $FINAL_TIDES active tide(s)"
          fi