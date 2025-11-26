import "FlowVaultsTransactionHandler"

/// @title Unpause Transaction Handler
/// @notice Unpauses the automated transaction handler
/// @dev After unpausing, manually schedule a new execution using
///      init_and_schedule.cdc to restart the chain.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowVaultsTransactionHandler.Admin>(
            from: FlowVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.unpause()
    }
}
