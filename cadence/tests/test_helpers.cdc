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
access(all) let pendingRequestsByUserQueryMockBytecode = "60c03461008157601f6108c838819003918201601f19168301916001600160401b0383118484101761008557808492604094855283398101031261008157610052602061004b83610099565b9201610099565b9060805260a05260405161081a90816100ae82396080518181816103f0015261066d015260a0518161042e0152f35b5f80fd5b634e487b7160e01b5f52604160045260245ffd5b51906001600160a01b03821682036100815756fe60806040526004361015610011575f80fd5b5f803560e01c636b67542814610025575f80fd5b346101875760209081600319360112610187576004356001600160a01b0381168103610183576100549061038c565b9b9c94969d939792989199909a604051809e6101a080835282016100779161018a565b9086818303910152610088916101bd565b8d810360408f0152610099916101bd565b8c810360608e01526100aa916101f3565b8b810360808d01526100bb9161018a565b908a820360a08c015280808d5193848152019c01925b828110610165575050505093610134610152946101256101619895610116610143966101088f8f9e9c8f60c081840391015261018a565b8d810360e08f01529061022f565b908b82036101008d015261022f565b908982036101208b015261022f565b908782036101408901526101f3565b9085820361016087015261018a565b9083820361018085015261018a565b0390f35b835167ffffffffffffffff168d529b81019b928101926001016100d1565b5080fd5b80fd5b9081518082526020808093019301915f5b8281106101a9575050505090565b83518552938101939281019260010161019b565b9081518082526020808093019301915f5b8281106101dc575050505090565b835160ff16855293810193928101926001016101ce565b9081518082526020808093019301915f5b828110610212575050505090565b83516001600160a01b031685529381019392810192600101610204565b9080825180825260208092019180808360051b8601019501935f9384915b84831061025e575050505050505090565b9091929394959684601f198084840301855289518051908185528a5b8281106102a657505080840183018a9052601f011690910181019781019695949360010192019061024d565b81810185015186820186015289940161027a565b604051906020820182811067ffffffffffffffff8211176102da57604052565b634e487b7160e01b5f52604160045260245ffd5b604051906060820182811067ffffffffffffffff8211176102da57604052565b604051906080820182811067ffffffffffffffff8211176102da57604052565b80511561033b5760200190565b634e487b7160e01b5f52603260045260245ffd5b80516001101561033b5760400190565b6103676102ee565b9060028252815f5b6040811061037b575050565b80606060208093850101520161036f565b9061039561030e565b90600382526060366020840137816103ab61030e565b60038152606036602083013780916103c161030e565b9060038252606036602084013790958691906001600160a01b036103e48361032e565b526103ee8261034f565b7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b0316905281516002101561033b576001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000811660608401521660101901610755575050506104686102ee565b60028152916040366020850137829461047f6102ee565b6002815290604036602084013781956104966102ee565b60028152604036602083013780966104ac6102ee565b6002815292604036602086013783976104c36102ee565b6002815295604036602089013786986104da6102ee565b600281529760403660208b013788996104f16102ee565b600281526040366020830137809a61050761035f565b9a8b61051161035f565b9b8c9561051c61035f565b9c6105268161032e565b600b90525f978894856105388561032e565b52856105438661032e565b526001600160a01b036105558861032e565b5261055f8b61032e565b670de0b6b3a764000090526105738961032e565b6064905261057f6102ba565b86815261058b8261032e565b526105959061032e565b5061059e6102ee565b602281527f412e306165353363623665336634326137392e466c6f77546f6b656e2e5661756020820152611b1d60f21b60408201526105dc8261032e565b526105e69061032e565b508d6105f06102ee565b603081527f412e303435613137363363393330303663612e4d6f636b53747261746567696560208201526f732e547261636572537472617465677960801b604082015261063c8261032e565b526106469061032e565b506106509061034f565b600c905261065d9061034f565b6001905261066a9061034f565b527f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03169061069f9061034f565b526212d6876106ae819561034f565b526106b89061034f565b602a90526106c59061034f565b606590526106d16102ba565b8181526106dd8a61034f565b526106e78961034f565b506106f06102ba565b8181526106fc8961034f565b526107068861034f565b5061070f6102ba565b90815261071b8761034f565b526107258661034f565b5061072f8461032e565b6729a2241af62c000090526107438461034f565b5261074d8261034f565b6207a1209052565b925092945092506107646102ba565b925f928385526107726102ba565b9584875261077e6102ba565b9585875261078a6102ba565b958087526107966102ba565b958187526107a26102ba565b958287526107ae6102ba565b958387526107ba6102ba565b958487526107c66102ba565b958587526107d26102ba565b9586529c9b9a9998979695949392919056fea2646970667358221220cfa80be468db850f056dd10c0c0cfcd65bac57fec1fbf9c969b09350055e9c6364736f6c63430008140033"

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
