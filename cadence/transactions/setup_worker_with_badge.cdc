import "FlowYieldVaultsEVM"
import "FlowYieldVaultsClosedBeta"
import "FlowYieldVaults"
import "EVM"
import "FungibleToken"

/// @title Setup Worker with Badge
/// @notice Creates and configures the FlowYieldVaultsEVM Worker resource
/// @dev Sets up all required capabilities: COA, YieldVaultManager, BetaBadge, and FeeProvider.
///      Also sets the FlowYieldVaultsRequests contract address.
///
/// @param flowYieldVaultsRequestsAddress The EVM address of the FlowYieldVaultsRequests contract
///
transaction(flowYieldVaultsRequestsAddress: String) {
    prepare(signer: auth(BorrowValue, SaveValue, LoadValue, Storage, Capabilities, CopyValue, IssueStorageCapabilityController) &Account) {
        var betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>? = nil

        let standardStoragePath = FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        if signer.storage.type(at: standardStoragePath) != nil {
            betaBadgeCap = signer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
                from: standardStoragePath
            )
        }

        if betaBadgeCap == nil {
            let userSpecificPath = /storage/FlowYieldVaultsUserBetaCap_0x3bda2f90274dbc9b
            if signer.storage.type(at: userSpecificPath) != nil {
                betaBadgeCap = signer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
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

        if signer.storage.type(at: FlowYieldVaults.YieldVaultManagerStoragePath) == nil {
            signer.storage.save(<-FlowYieldVaults.createYieldVaultManager(betaRef: betaRef), to: FlowYieldVaults.YieldVaultManagerStoragePath)
            let cap = signer.capabilities.storage.issue<&FlowYieldVaults.YieldVaultManager>(FlowYieldVaults.YieldVaultManagerStoragePath)
            signer.capabilities.publish(cap, at: FlowYieldVaults.YieldVaultManagerPublicPath)
        }

        let yieldVaultManagerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>(
            FlowYieldVaults.YieldVaultManagerStoragePath
        )

        let feeProviderCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(
            /storage/flowTokenVault
        )

        let admin = signer.storage.borrow<&FlowYieldVaultsEVM.Admin>(
            from: FlowYieldVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Admin")

        let worker <- admin.createWorker(
            coaCap: coaCap,
            yieldVaultManagerCap: yieldVaultManagerCap,
            betaBadgeCap: betaBadgeCap!,
            feeProviderCap: feeProviderCap
        )

        signer.storage.save(<-worker, to: FlowYieldVaultsEVM.WorkerStoragePath)

        let evmAddress = EVM.addressFromString(flowYieldVaultsRequestsAddress)
        admin.setFlowYieldVaultsRequestsAddress(evmAddress)
    }
}
