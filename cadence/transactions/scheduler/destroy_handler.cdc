import "FlowYieldVaultsTransactionHandler"

/// @title Destroy FlowYieldVaults Transaction Handler
/// @notice Removes the Handler resource from storage
transaction() {
    prepare(signer: auth(LoadValue, UnpublishCapability) &Account) {
        // Unpublish the public capability first
        signer.capabilities.unpublish(FlowYieldVaultsTransactionHandler.HandlerPublicPath)

        // Load and destroy the handler resource
        if let handler <- signer.storage.load<@FlowYieldVaultsTransactionHandler.Handler>(
            from: FlowYieldVaultsTransactionHandler.HandlerStoragePath
        ) {
            destroy handler
        }
    }
}
