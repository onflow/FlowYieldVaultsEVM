import "FlowVaultsTransactionHandler"

/// @title Destroy FlowVaults Transaction Handler
/// @notice Removes the Handler resource from storage
transaction() {
    prepare(signer: auth(LoadValue, UnpublishCapability) &Account) {
        // Unpublish the public capability first
        signer.capabilities.unpublish(FlowVaultsTransactionHandler.HandlerPublicPath)

        // Load and destroy the handler resource
        if let handler <- signer.storage.load<@FlowVaultsTransactionHandler.Handler>(
            from: FlowVaultsTransactionHandler.HandlerStoragePath
        ) {
            destroy handler
        }
    }
}
