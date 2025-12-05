import "FlowYieldVaultsTransactionHandler"

/// @title Pause Transaction Handler
/// @notice Pauses the automated transaction handler
/// @dev When paused, scheduled executions skip processing and do not reschedule.
///      Requires Admin resource.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsTransactionHandler.Admin>(
            from: FlowYieldVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.pause()
    }
}
