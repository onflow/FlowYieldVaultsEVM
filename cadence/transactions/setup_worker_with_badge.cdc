import "FlowVaultsEVM"
import "FlowVaultsClosedBeta"
import "FlowVaults"
import "EVM"
import "FungibleToken"

/// @title Setup Worker with Badge
/// @notice Creates and configures the FlowVaultsEVM Worker resource
/// @dev Sets up all required capabilities: COA, TideManager, BetaBadge, and FeeProvider.
///      Also sets the FlowVaultsRequests contract address.
///
/// @param flowVaultsRequestsAddress The EVM address of the FlowVaultsRequests contract
///
transaction(flowVaultsRequestsAddress: String) {
    prepare(signer: auth(BorrowValue, SaveValue, LoadValue, Storage, Capabilities, CopyValue, IssueStorageCapabilityController) &Account) {
        var betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>? = nil

        let standardStoragePath = FlowVaultsClosedBeta.UserBetaCapStoragePath
        if signer.storage.type(at: standardStoragePath) != nil {
            betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
                from: standardStoragePath
            )
        }

        if betaBadgeCap == nil {
            let userSpecificPath = /storage/FlowVaultsUserBetaCap_0x3bda2f90274dbc9b
            if signer.storage.type(at: userSpecificPath) != nil {
                betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
                    from: userSpecificPath
                )
            }
        }

        let betaRef = betaBadgeCap!.borrow()
            ?? panic("Beta badge capability does not contain correct reference")

        let coaCap = signer.capabilities.storage.issue<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>(
            /storage/evm
        )

        let coaRef = coaCap.borrow()
            ?? panic("Could not borrow COA capability from /storage/evm")

        if signer.storage.type(at: FlowVaults.TideManagerStoragePath) == nil {
            signer.storage.save(<-FlowVaults.createTideManager(betaRef: betaRef), to: FlowVaults.TideManagerStoragePath)
            let cap = signer.capabilities.storage.issue<&FlowVaults.TideManager>(FlowVaults.TideManagerStoragePath)
            signer.capabilities.publish(cap, at: FlowVaults.TideManagerPublicPath)
        }

        let tideManagerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>(
            FlowVaults.TideManagerStoragePath
        )

        let feeProviderCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(
            /storage/flowTokenVault
        )

        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin")

        let worker <- admin.createWorker(
            coaCap: coaCap,
            tideManagerCap: tideManagerCap,
            betaBadgeCap: betaBadgeCap!,
            feeProviderCap: feeProviderCap
        )

        signer.storage.save(<-worker, to: FlowVaultsEVM.WorkerStoragePath)

        let evmAddress = EVM.addressFromString(flowVaultsRequestsAddress)
        admin.setFlowVaultsRequestsAddress(evmAddress)
    }
}
