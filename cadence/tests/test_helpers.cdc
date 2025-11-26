import Test

import "EVM"
import "FlowToken"
import "FlowVaults"
import "FlowVaultsEVM"
import "FlowVaultsClosedBeta"

/* --- Test Accounts --- */

access(all) let admin = Test.getAccount(0x0000000000000007) // testing alias

/* --- Mock EVM Addresses --- */

access(all) let mockRequestsAddr = EVM.addressFromString("0x0000000000000000000000000000000000000002")
access(all) let nativeFlowAddr = EVM.addressFromString("0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF")

/* --- Mock Vault and Strategy Identifiers --- */

access(all) let mockVaultIdentifier = "A.0ae53cb6e3f42a79.FlowToken.Vault"
access(all) let mockStrategyIdentifier = "A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy"

/* --- Setup helpers --- */

// Deploys all required contracts for FlowVaultsEVM
access(all) fun deployContracts() {
    // Deploy standard libraries first
    var err = Test.deployContract(
        name: "ViewResolver",
        path: "../../imports/1d7e57aa55817448/ViewResolver.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "Burner",
        path: "../../imports/f233dcee88fe0abe/Burner.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy DeFiActions dependencies
    err = Test.deployContract(
        name: "DeFiActionsMathUtils",
        path: "../../imports/92195d814edf9cb0/DeFiActionsMathUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../imports/92195d814edf9cb0/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../imports/92195d814edf9cb0/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FlowVaults dependencies
    err = Test.deployContract(
        name: "FlowVaultsClosedBeta",
        path: "../../lib/flow-vaults-sc/cadence/contracts/FlowVaultsClosedBeta.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "FlowVaults",
        path: "../../lib/flow-vaults-sc/cadence/contracts/FlowVaults.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FlowEVMBridge dependencies for FlowEVMBridgeUtils
    // First deploy interfaces
    err = Test.deployContract(
        name: "FlowEVMBridgeHandlerInterfaces",
        path: "../../imports/1e4aa0b87d10b141/FlowEVMBridgeHandlerInterfaces.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "IBridgePermissions",
        path: "../../imports/1e4aa0b87d10b141/IBridgePermissions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "ICrossVM",
        path: "../../imports/1e4aa0b87d10b141/ICrossVM.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "ICrossVMAsset",
        path: "../../imports/1e4aa0b87d10b141/ICrossVMAsset.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "CrossVMMetadataViews",
        path: "../../imports/1d7e57aa55817448/CrossVMMetadataViews.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "CrossVMNFT",
        path: "../../imports/1e4aa0b87d10b141/CrossVMNFT.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy custom association types
    err = Test.deployContract(
        name: "FlowEVMBridgeCustomAssociationTypes",
        path: "../../imports/1e4aa0b87d10b141/FlowEVMBridgeCustomAssociationTypes.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "FlowEVMBridgeCustomAssociations",
        path: "../../imports/1e4aa0b87d10b141/FlowEVMBridgeCustomAssociations.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FlowEVMBridgeConfig
    err = Test.deployContract(
        name: "FlowEVMBridgeConfig",
        path: "../../imports/1e4aa0b87d10b141/FlowEVMBridgeConfig.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy Serialize (dependency of SerializeMetadata)
    err = Test.deployContract(
        name: "Serialize",
        path: "../../imports/1e4aa0b87d10b141/Serialize.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "SerializeMetadata",
        path: "../../imports/1e4aa0b87d10b141/SerializeMetadata.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FlowEVMBridgeUtils (required by FlowVaultsEVM)
    err = Test.deployContract(
        name: "FlowEVMBridgeUtils",
        path: "../../imports/1e4aa0b87d10b141/FlowEVMBridgeUtils.cdc",
        arguments: ["0x0000000000000000000000000000000000000000"]
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FlowEVMBridge interface contracts
    err = Test.deployContract(
        name: "IEVMBridgeNFTMinter",
        path: "../../imports/1e4aa0b87d10b141/IEVMBridgeNFTMinter.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "IEVMBridgeTokenMinter",
        path: "../../imports/1e4aa0b87d10b141/IEVMBridgeTokenMinter.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "IFlowEVMNFTBridge",
        path: "../../imports/1e4aa0b87d10b141/IFlowEVMNFTBridge.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "IFlowEVMTokenBridge",
        path: "../../imports/1e4aa0b87d10b141/IFlowEVMTokenBridge.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy CrossVMToken
    err = Test.deployContract(
        name: "CrossVMToken",
        path: "../../imports/1e4aa0b87d10b141/CrossVMToken.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Note: We skip deploying FlowEVMBridge, FlowEVMBridgeNFTEscrow, FlowEVMBridgeTokenEscrow,
    // and FlowEVMBridgeTemplates as they have access control issues and are not needed.
    // FlowVaultsEVM only requires FlowEVMBridgeUtils and FlowEVMBridgeConfig which are already deployed.
    
    // Deploy FlowVaultsEVM
    err = Test.deployContract(
        name: "FlowVaultsEVM",
        path: "../contracts/FlowVaultsEVM.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

/* --- Transaction execution helpers --- */

access(all)
fun _executeTransaction(_ path: String, _ args: [AnyStruct], _ signer: Test.TestAccount): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: [signer.address],
        signers: [signer],
        arguments: args
    )
    return Test.executeTransaction(txn)
}

access(all)
fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

/* --- FlowVaultsEVM specific transaction helpers --- */

access(all)
fun updateRequestsAddress(_ signer: Test.TestAccount, _ address: String): Test.TransactionResult {
    return _executeTransaction(
        "../transactions/update_flow_vaults_requests_address.cdc",
        [address],
        signer
    )
}

access(all)
fun updateMaxRequests(_ signer: Test.TestAccount, _ maxRequests: Int): Test.TransactionResult {
    return _executeTransaction(
        "../transactions/update_max_requests.cdc",
        [maxRequests],
        signer
    )
}

access(all)
fun setupWorkerWithBadge(_ admin: Test.TestAccount): Test.TransactionResult {
    return _executeTransaction(
        "transactions/setup_worker_for_test.cdc",
        [],
        admin
    )
}

access(all)
fun setupCOA(_ signer: Test.TestAccount): Test.TransactionResult {
    return _executeTransaction(
        "../transactions/setup_coa.cdc",
        [],
        signer
    )
}

/* --- FlowVaultsEVM specific script helpers --- */

access(all)
fun getTideIDsForEVMAddress(_ evmAddress: String): [UInt64]? {
    let res = _executeScript("../scripts/check_user_tides.cdc", [evmAddress])
    if res.status == Test.ResultStatus.succeeded {
        return res.returnValue as! [UInt64]?
    }
    return nil
}

access(all)
fun getRequestsAddress(): String? {
    let res = _executeScript("../scripts/get_contract_state.cdc", [admin.address])
    if res.status == Test.ResultStatus.succeeded {
        if let state = res.returnValue as? {String: AnyStruct} {
            let address = state["flowVaultsRequestsAddress"] as! String?
            // Return nil if the address is "Not set"
            if address == "Not set" {
                return nil
            }
            return address
        }
    }
    return nil
}

access(all)
fun getMaxRequestsConfig(): Int? {
    let res = _executeScript("../scripts/get_max_requests_config.cdc", [])
    if res.status == Test.ResultStatus.succeeded {
        if let result = res.returnValue as? {String: AnyStruct} {
            return result["currentMaxRequestsPerTx"] as! Int?
        }
    }
    return nil
}

access(all)
fun getCOAAddress(_ accountAddress: Address): String? {
    let res = _executeScript("../scripts/get_coa_address.cdc", [accountAddress])
    if res.status == Test.ResultStatus.succeeded {
        return res.returnValue as! String?
    }
    return nil
}

/* --- Beta access helpers --- */

access(all)
fun grantBeta(_ admin: Test.TestAccount, _ grantee: Test.TestAccount): Test.TransactionResult {
    // The grant_beta transaction always requires 2 authorizers: admin and user
    // Even when admin grants to themselves, we need both authorizers
    let betaTxn = Test.Transaction(
        code: Test.readFile("../../lib/flow-vaults-sc/cadence/transactions/flow-vaults/admin/grant_beta.cdc"),
        authorizers: [admin.address, grantee.address],
        signers: [admin, grantee],
        arguments: []
    )
    return Test.executeTransaction(betaTxn)
}

/* --- EVMRequest creation helper --- */

access(all)
fun createEVMRequest(
    id: UInt256,
    user: EVM.EVMAddress,
    requestType: UInt8,
    status: UInt8,
    tokenAddress: EVM.EVMAddress,
    amount: UInt256,
    tideId: UInt64,
    timestamp: UInt256,
    message: String,
    vaultIdentifier: String,
    strategyIdentifier: String
): FlowVaultsEVM.EVMRequest {
    return FlowVaultsEVM.EVMRequest(
        id: id,
        user: user,
        requestType: requestType,
        status: status,
        tokenAddress: tokenAddress,
        amount: amount,
        tideId: tideId,
        timestamp: timestamp,
        message: message,
        vaultIdentifier: vaultIdentifier,
        strategyIdentifier: strategyIdentifier
    )
}

/* --- ProcessResult creation helper --- */

access(all)
fun createProcessResult(
    success: Bool,
    tideId: UInt64,
    message: String
): FlowVaultsEVM.ProcessResult {
    return FlowVaultsEVM.ProcessResult(
        success: success,
        tideId: tideId,
        message: message
    )
}

/* --- Constants --- */

// Request type constants
access(all) let REQUEST_TYPE_CREATE: UInt8 = 0
access(all) let REQUEST_TYPE_DEPOSIT: UInt8 = 1
access(all) let REQUEST_TYPE_WITHDRAW: UInt8 = 2
access(all) let REQUEST_TYPE_CLOSE: UInt8 = 3

// Request status constants
access(all) let REQUEST_STATUS_PENDING: UInt8 = 0
access(all) let REQUEST_STATUS_COMPLETED: UInt8 = 1
access(all) let REQUEST_STATUS_FAILED: UInt8 = 2
