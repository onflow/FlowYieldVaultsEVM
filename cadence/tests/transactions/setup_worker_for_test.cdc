import "FlowYieldVaultsEVM"
import "FlowYieldVaultsClosedBeta"
import "FlowYieldVaults"
import "EVM"
import "FungibleToken"

/// @title Setup Worker for Test
/// @notice Test-specific Worker setup that doesn't set FlowYieldVaultsRequests address
/// @dev Use this in tests where the address may already be configured.
///
transaction() {
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

        if betaBadgeCap == nil {
            let betaAdminHandle = signer.storage.borrow<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle>(
                from: FlowYieldVaultsClosedBeta.AdminHandleStoragePath
            ) ?? panic("Could not borrow AdminHandle - you need admin access or an existing beta badge")

            betaBadgeCap = betaAdminHandle.grantBeta(addr: signer.address)
            signer.storage.save(betaBadgeCap!, to: standardStoragePath)
        }

        let betaRef = betaBadgeCap!.borrow()
            ?? panic("Beta badge capability does not contain correct reference")

        let coaCap = signer.capabilities.storage.issue<auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount>(
            /storage/evm
        )

        let coaRef = coaCap.borrow()
            ?? panic("Could not borrow COA capability - ensure COA is set up first")

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
    }
}
