import Test

import "EVM"
import "FlowToken"
import "FlowYieldVaults"
import "FlowYieldVaultsEVM"
import "FlowYieldVaultsClosedBeta"

/* --- Test Accounts --- */

access(all) let admin = Test.getAccount(0x0000000000000007) // testing alias

/* --- Mock EVM Addresses --- */

access(all) let mockRequestsAddr = EVM.addressFromString("0x0000000000000000000000000000000000000002")
access(all) let nativeFlowAddr = EVM.addressFromString("0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF")

/* --- Mock Vault and Strategy Identifiers --- */

access(all) let mockVaultIdentifier = "A.0ae53cb6e3f42a79.FlowToken.Vault"
access(all) let mockStrategyIdentifier = "A.045a1763c93006ca.MockStrategies.TracerStrategy"

/* --- Embedded EVM mock bytecode --- */

// Regenerate with the repo's Foundry defaults from solidity/foundry.toml:
// `cd solidity && forge inspect src/test/PendingRequestsByUserQueryMock.sol:ERC20DecimalsOnlyMock bytecode`
access(all) let erc20DecimalsOnlyMockBytecode = "60a03461006257601f61011338819003918201601f19168301916001600160401b0383118484101761006657808492602094604052833981010312610062575160ff81168103610062576080526040516098908161007b823960805181603a0152f35b5f80fd5b634e487b7160e01b5f52604160045260245ffdfe60808060405260043610156011575f80fd5b5f90813560e01c63313ce567146025575f80fd5b34605e5781600319360112605e5760209060ff7f0000000000000000000000000000000000000000000000000000000000000000168152f35b5080fdfea26469706673582212203c866ad60ad80831e09284cb4b396975c6e952f53d1755f246b0f36dcd9c903664736f6c63430008140033"

// Regenerate with the repo's Foundry defaults from solidity/foundry.toml:
// `cd solidity && forge inspect src/test/PendingRequestsByUserQueryMock.sol:PendingRequestsByUserQueryMock bytecode`
access(all) let pendingRequestsByUserQueryMockBytecode = "60c03461008857601f6109c838819003918201601f19168301916001600160401b0383118484101761008c57808492604094855283398101031261008857610052602061004b836100a0565b92016100a0565b9060805260a05260405161091390816100b58239608051818181610404015261067d015260a051818181610441015261075b0152f35b5f80fd5b634e487b7160e01b5f52604160045260245ffd5b51906001600160a01b03821682036100885756fe60806040526004361015610011575f80fd5b5f803560e01c636b67542814610025575f80fd5b346101875760209081600319360112610187576004356001600160a01b038116810361018357610054906103a2565b9b9c94969d939792989199909a604051809e6101a080835282016100779161018a565b9086818303910152610088916101bd565b8d810360408f0152610099916101bd565b8c810360608e01526100aa916101f3565b8b810360808d01526100bb9161018a565b908a820360a08c015280808d5193848152019c01925b828110610165575050505093610134610152946101256101619895610116610143966101088f8f9e9c8f60c081840391015261018a565b8d810360e08f01529061022f565b908b82036101008d015261022f565b908982036101208b015261022f565b908782036101408901526101f3565b9085820361016087015261018a565b9083820361018085015261018a565b0390f35b835167ffffffffffffffff168d529b81019b928101926001016100d1565b5080fd5b80fd5b9081518082526020808093019301915f5b8281106101a9575050505090565b83518552938101939281019260010161019b565b9081518082526020808093019301915f5b8281106101dc575050505090565b835160ff16855293810193928101926001016101ce565b9081518082526020808093019301915f5b828110610212575050505090565b83516001600160a01b031685529381019392810192600101610204565b90808083519081815260208080809301948460051b01019501935f9384915b84831061025f575050505050505090565b9091929394959684601f198084840301855289518051908185528a5b8281106102a757505080840183018a9052601f011690910181019781019695949360010192019061024e565b81810185015186820186015289940161027b565b604051906020820182811067ffffffffffffffff8211176102db57604052565b634e487b7160e01b5f52604160045260245ffd5b604051906080820182811067ffffffffffffffff8211176102db57604052565b604051906060820182811067ffffffffffffffff8211176102db57604052565b80511561033c5760200190565b634e487b7160e01b5f52603260045260245ffd5b80516001101561033c5760400190565b80516002101561033c5760600190565b6103786102ef565b906003825281905f5b60608082101561039b579060209182828701015201610381565b5050909150565b906103ab6102ef565b90600382526060366020840137816103c16102ef565b60038152606036602083013780916103d76102ef565b906003825260603660208401376011829760018060a01b036103f88461032f565b5261040283610350565b7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b0316905261043783610360565b6001600160a01b037f00000000000000000000000000000000000000000000000000000000000000008116909152160361084e575050506104766102ef565b60038152916060366020850137829461048d6102ef565b6003815290606036602084013781956104a46102ef565b60038152606036602083013780966104ba6102ef565b6003815292606036602086013783976104d16102ef565b6003815295606036602089013786986104e86102ef565b600381529760603660208b013780899a6105006102ef565b600381526040366020830137809b610516610370565b9b8c610520610370565b9c8d9561052b610370565b9d8e6105368261032f565b600b90525f988995866105488661032f565b52866105538761032f565b526001600160a01b036105658961032f565b5261056f8c61032f565b670de0b6b3a764000090526105838a61032f565b6064905261058f6102bb565b87815261059b8261032f565b526105a58161032f565b506105ae61030f565b602281527f412e306165353363623665336634326137392e466c6f77546f6b656e2e5661756020820152611b1d60f21b60408201526105ec8361032f565b526105f68261032f565b506105ff61030f565b603081527f412e303435613137363363393330303663612e4d6f636b53747261746567696560208201526f732e547261636572537472617465677960801b604082015261064b8461032f565b526106558361032f565b5061065f84610350565b600c905261066c85610350565b600190528661067a87610350565b527f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03166106ae89610350565b526212d6876106bd819d610350565b526106c789610350565b602a90526106d48a610350565b606590526106e06102bb565b8781526106ec82610350565b526106f690610350565b506106ff6102bb565b86815261070b82610350565b5261071590610350565b5061071e6102bb565b85815261072a82610350565b5261073490610350565b5061073e90610360565b600d905261074b90610360565b6001905261075890610360565b527f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03169061078d90610360565b52632d9f912461079d8196610360565b526107a790610360565b602b90526107b490610360565b606690526107c06102bb565b8181526107cc8b610360565b526107d68a610360565b506107df6102bb565b8181526107eb8a610360565b526107f589610360565b506107fe6102bb565b90815261080a88610360565b5261081487610360565b5061081e8561032f565b6729a2241af62c0000905261083285610350565b5261083c84610360565b5261084682610350565b6207a1209052565b9250929450925061085d6102bb565b925f9283855261086b6102bb565b958487526108776102bb565b958587526108836102bb565b9580875261088f6102bb565b9581875261089b6102bb565b958287526108a76102bb565b958387526108b36102bb565b958487526108bf6102bb565b958587526108cb6102bb565b9586529c9b9a9998979695949392919056fea26469706673582212201da31499d382804da1e8c81851caccf7d38977f5ea928a251455d3a923454c5964736f6c63430008140033"

/* --- Setup helpers --- */

// Deploys all required contracts for FlowYieldVaultsEVM
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

    // Deploy FlowYieldVaults dependencies
    err = Test.deployContract(
        name: "FlowYieldVaultsClosedBeta",
        path: "../../lib/FlowYieldVaults/cadence/contracts/FlowYieldVaultsClosedBeta.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "FlowYieldVaults",
        path: "../../lib/FlowYieldVaults/cadence/contracts/FlowYieldVaults.cdc",
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

    // Deploy FlowEVMBridgeUtils (required by FlowYieldVaultsEVM)
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
    // FlowYieldVaultsEVM only requires FlowEVMBridgeUtils and FlowEVMBridgeConfig which are already deployed.

    // Deploy FlowYieldVaultsEVM
    err = Test.deployContract(
        name: "FlowYieldVaultsEVM",
        path: "../contracts/FlowYieldVaultsEVM.cdc",
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

/* --- FlowYieldVaultsEVM specific transaction helpers --- */

access(all)
fun updateRequestsAddress(_ signer: Test.TestAccount, _ address: String): Test.TransactionResult {
    return _executeTransaction(
        "../transactions/update_flow_vaults_requests_address.cdc",
        [address],
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

access(all)
fun deployEVMContractWithArgs(_ signer: Test.TestAccount, _ bytecode: String, _ args: [AnyStruct]): String {
    let argsBytecode = EVM.encodeABI(args)
    let bytecodeWithArgs = String.encodeHex(bytecode.decodeHex().concat(argsBytecode))
    let result = _executeTransaction(
        "../transactions/deploy_evm_contract.cdc",
        [bytecodeWithArgs, UInt64(15_000_000)],
        signer
    )
    Test.expect(result, Test.beSucceeded())

    let txnEvents = Test.eventsOfType(Type<EVM.TransactionExecuted>())
    Test.assert(txnEvents.length > 0, message: "Expected an EVM.TransactionExecuted event for mock deployment")

    let deployEvent = txnEvents[txnEvents.length - 1] as? EVM.TransactionExecuted
        ?? panic("Latest event is not an EVM.TransactionExecuted deployment event")
    Test.assert(deployEvent.contractAddress.length > 0, message: "Deployment event missing contract address")

    return deployEvent.contractAddress
}

access(all)
fun deployERC20DecimalsOnlyMock(_ signer: Test.TestAccount, decimals: UInt8): String {
    return deployEVMContractWithArgs(signer, erc20DecimalsOnlyMockBytecode, [decimals])
}

access(all)
fun deployPendingRequestsByUserQueryMock(
    _ signer: Test.TestAccount,
    tokenBAddress: String,
    tokenCAddress: String
): String {
    let tokenB = EVM.addressFromString(tokenBAddress)
    let tokenC = EVM.addressFromString(tokenCAddress)
    return deployEVMContractWithArgs(signer, pendingRequestsByUserQueryMockBytecode, [tokenB, tokenC])
}

/* --- FlowYieldVaultsEVM specific script helpers --- */

access(all)
fun getYieldVaultIdsForEVMAddress(_ evmAddress: String): [UInt64]? {
    let res = _executeScript("../scripts/check_user_yieldvaults.cdc", [evmAddress])
    if res.status == Test.ResultStatus.succeeded {
        return res.returnValue as! [UInt64]?
    }
    return nil
}

access(all)
fun getRequestsAddress(): String? {
    let res = _executeScript("../scripts/get_contract_state.cdc", [])
    if res.status == Test.ResultStatus.succeeded {
        if let state = res.returnValue as? {String: AnyStruct} {
            let address = state["flowYieldVaultsRequestsAddress"] as! String?
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
        code: Test.readFile("../../lib/FlowYieldVaults/cadence/transactions/FlowYieldVaults/admin/grant_beta.cdc"),
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
    yieldVaultId: UInt64,
    timestamp: UInt256,
    message: String,
    vaultIdentifier: String,
    strategyIdentifier: String
): FlowYieldVaultsEVM.EVMRequest {
    return FlowYieldVaultsEVM.EVMRequest(
        id: id,
        user: user,
        requestType: requestType,
        status: status,
        tokenAddress: tokenAddress,
        amount: amount,
        yieldVaultId: yieldVaultId,
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
    yieldVaultId: UInt64,
    message: String
): FlowYieldVaultsEVM.ProcessResult {
    return FlowYieldVaultsEVM.ProcessResult(
        success: success,
        yieldVaultId: yieldVaultId,
        message: message
    )
}

/* --- Constants --- */

// Request type constants
access(all) let REQUEST_TYPE_CREATE: UInt8 = 0
access(all) let REQUEST_TYPE_DEPOSIT: UInt8 = 1
access(all) let REQUEST_TYPE_WITHDRAW: UInt8 = 2
access(all) let REQUEST_TYPE_CLOSE: UInt8 = 3

// Request status constants (must match FlowYieldVaultsEVM.RequestStatus enum order)
access(all) let REQUEST_STATUS_PENDING: UInt8 = 0
access(all) let REQUEST_STATUS_PROCESSING: UInt8 = 1
access(all) let REQUEST_STATUS_COMPLETED: UInt8 = 2
access(all) let REQUEST_STATUS_FAILED: UInt8 = 3
