// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Tiny ERC20-like mock exposing only decimals().
contract ERC20DecimalsOnlyMock {
    uint8 internal immutable tokenDecimals;

    constructor(uint8 tokenDecimals_) {
        tokenDecimals = tokenDecimals_;
    }

    function decimals() external view returns (uint8) {
        return tokenDecimals;
    }
}

/// @notice Test-only EVM mock for Cadence query coverage.
/// @dev Returns a stable getPendingRequestsByUserUnpacked payload for one user.
contract PendingRequestsByUserQueryMock {
    address internal constant TARGET_USER = 0x0000000000000000000000000000000000000011;
    address internal constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    address internal immutable tokenB;
    address internal immutable tokenC;

    constructor(address tokenB_, address tokenC_) {
        tokenB = tokenB_;
        tokenC = tokenC_;
    }

    function getPendingRequestsByUserUnpacked(
        address user
    )
        external
        view
        returns (
            uint256[] memory ids,
            uint8[] memory requestTypes,
            uint8[] memory statuses,
            address[] memory tokenAddresses,
            uint256[] memory amounts,
            uint64[] memory yieldVaultIds,
            uint256[] memory timestamps,
            string[] memory messages,
            string[] memory vaultIdentifiers,
            string[] memory strategyIdentifiers,
            address[] memory balanceTokens,
            uint256[] memory pendingBalances,
            uint256[] memory claimableRefundsArray
        )
    {
        balanceTokens = new address[](3);
        pendingBalances = new uint256[](3);
        claimableRefundsArray = new uint256[](3);
        balanceTokens[0] = NATIVE_FLOW;
        balanceTokens[1] = tokenB;
        balanceTokens[2] = tokenC;

        if (user != TARGET_USER) {
            ids = new uint256[](0);
            requestTypes = new uint8[](0);
            statuses = new uint8[](0);
            tokenAddresses = new address[](0);
            amounts = new uint256[](0);
            yieldVaultIds = new uint64[](0);
            timestamps = new uint256[](0);
            messages = new string[](0);
            vaultIdentifiers = new string[](0);
            strategyIdentifiers = new string[](0);
            return (
                ids,
                requestTypes,
                statuses,
                tokenAddresses,
                amounts,
                yieldVaultIds,
                timestamps,
                messages,
                vaultIdentifiers,
                strategyIdentifiers,
                balanceTokens,
                pendingBalances,
                claimableRefundsArray
            );
        }

        ids = new uint256[](3);
        requestTypes = new uint8[](3);
        statuses = new uint8[](3);
        tokenAddresses = new address[](3);
        amounts = new uint256[](3);
        yieldVaultIds = new uint64[](3);
        timestamps = new uint256[](3);
        messages = new string[](3);
        vaultIdentifiers = new string[](3);
        strategyIdentifiers = new string[](3);

        ids[0] = 11;
        requestTypes[0] = 0;
        statuses[0] = 0;
        tokenAddresses[0] = NATIVE_FLOW;
        amounts[0] = 1 ether;
        timestamps[0] = 100;
        messages[0] = "";
        vaultIdentifiers[0] = "A.0ae53cb6e3f42a79.FlowToken.Vault";
        strategyIdentifiers[0] = "A.045a1763c93006ca.MockStrategies.TracerStrategy";

        ids[1] = 12;
        requestTypes[1] = 1;
        statuses[1] = 0;
        tokenAddresses[1] = tokenB;
        amounts[1] = 1_234_567;
        yieldVaultIds[1] = 42;
        timestamps[1] = 101;
        messages[1] = "";
        vaultIdentifiers[1] = "";
        strategyIdentifiers[1] = "";

        ids[2] = 13;
        requestTypes[2] = 1;
        statuses[2] = 0;
        tokenAddresses[2] = tokenC;
        amounts[2] = 765_432_100;
        yieldVaultIds[2] = 43;
        timestamps[2] = 102;
        messages[2] = "";
        vaultIdentifiers[2] = "";
        strategyIdentifiers[2] = "";

        pendingBalances[0] = 3 ether;
        pendingBalances[1] = 1_234_567;
        pendingBalances[2] = 765_432_100;
        claimableRefundsArray[1] = 500_000;
    }
}
