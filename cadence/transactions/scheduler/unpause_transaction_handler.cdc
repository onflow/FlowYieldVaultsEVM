import "FlowYieldVaultsTransactionHandler"

/// @title Unpause Transaction Handler
/// @notice Unpauses the automated transaction handler
/// @dev After unpausing, manually schedule a new execution using
///      init_and_schedule.cdc to restart the chain.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsTransactionHandler.Admin>(
            from: FlowYieldVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.unpause()
    }
}
