// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract FlowYieldVaultsAdmin is Ownable2Step {
    /// @notice Configuration for supported tokens
    /// @param isSupported Whether the token can be used
    /// @param minimumBalance Minimum deposit amount required
    /// @param isNative True if this represents native $FLOW
    struct TokenConfig {
        bool isSupported;
        uint256 minimumBalance;
        bool isNative;
    }

    /// @notice Maximum number of pending requests allowed per user (0 = unlimited)
    uint256 public maxPendingRequestsPerUser;

    /// @notice Sentinel address representing native $FLOW token
    /// @dev Uses recognizable pattern (all F's) instead of address(0) for clarity
    address public constant NATIVE_FLOW =
        0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    /// @notice Default minimum deposit for initially supported tokens
    uint256 public constant DEFAULT_MINIMUM_BALANCE = 1 ether;

    /// @notice WFLOW (Wrapped FLOW) ERC20 token address
    /// @dev On Cadence side, WFLOW is automatically unwrapped to native FlowToken by FlowEVMBridge
    address public immutable WFLOW;

    /// @notice Whether allowlist enforcement is active
    bool public allowlistEnabled;

    /// @notice Addresses permitted to create requests when allowlist is enabled
    mapping(address => bool) public allowlisted;

    /// @notice Whether blocklist enforcement is active
    bool public blocklistEnabled;

    /// @notice Addresses blocked from creating requests
    mapping(address => bool) public blocklisted;

    /// @notice Address of the authorized COA that can process requests
    address public authorizedCOA;

    /// @notice Whether the contract is paused
    bool public paused;

    /// @notice Token configurations indexed by token address
    mapping(address => TokenConfig) public allowedTokens;

    /// @notice Token addresses surfaced in per-user balance views
    address[] public trackedTokens;

    /// @notice O(1) lookup for tracked-token membership
    mapping(address => bool) public isTrackedToken;

    /// @notice Caller is not in the allowlist
    error NotInAllowlist(address sender);

    /// @notice Caller is in the blocklist
    error Blocklisted(address sender);

    /// @notice Address array cannot be empty
    error EmptyAddressArray();

    /// @notice Cannot add zero address to allowlist
    error CannotAllowlistZeroAddress();

    /// @notice Cannot add zero address to blocklist
    error CannotBlocklistZeroAddress();

    /// @notice Caller is not the authorized COA
    error NotAuthorizedCOA(address sender);

    /// @notice Contract is paused
    error ContractPaused();

    /// @notice COA address cannot be zero
    error InvalidCOAAddress();

    /// @notice Minimum balance must be non-zero for supported tokens
    error InvalidMinimumBalance();

    /// @notice Emitted when allowlist status changes
    /// @param enabled New status
    /// @param changedBy Admin who changed the status
    event AllowlistEnabled(bool enabled, address indexed changedBy);

    /// @notice Emitted when addresses are added to allowlist
    /// @param addresses Addresses added
    /// @param addedBy Admin who added the addresses
    event AddressesAddedToAllowlist(address[] addresses, address indexed addedBy);

    /// @notice Emitted when addresses are removed from allowlist
    /// @param addresses Addresses removed
    /// @param removedBy Admin who removed the addresses
    event AddressesRemovedFromAllowlist(address[] addresses, address indexed removedBy);

    /// @notice Emitted when blocklist status changes
    /// @param enabled New status
    /// @param changedBy Admin who changed the status
    event BlocklistEnabled(bool enabled, address indexed changedBy);

    /// @notice Emitted when addresses are added to blocklist
    /// @param addresses Addresses added
    /// @param addedBy Admin who added the addresses
    event AddressesAddedToBlocklist(address[] addresses, address indexed addedBy);

    /// @notice Emitted when addresses are removed from blocklist
    /// @param addresses Addresses removed
    /// @param removedBy Admin who removed the addresses
    event AddressesRemovedFromBlocklist(address[] addresses, address indexed removedBy);

    /// @notice Emitted when authorized COA is changed
    /// @param oldCOA Previous COA address
    /// @param newCOA New COA address
    event AuthorizedCOAUpdated(address indexed oldCOA, address indexed newCOA);

    /// @notice Emitted when the contract is paused
    /// @param account Address that paused the contract
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    /// @param account Address that unpaused the contract
    event Unpaused(address account);

    /// @notice Emitted when token configuration changes
    /// @param token Token address
    /// @param isSupported Whether token is supported
    /// @param minimumBalance Minimum deposit amount
    /// @param isNative Whether token is native $FLOW
    /// @param configuredBy Admin who configured the token
    event TokenConfigured(
        address indexed token,
        bool isSupported,
        uint256 minimumBalance,
        bool isNative,
        address indexed configuredBy
    );

    /// @notice Emitted when max pending requests limit changes
    /// @param oldMax Previous limit
    /// @param newMax New limit
    /// @param updatedBy Admin who updated the limit
    event MaxPendingRequestsPerUserUpdated(uint256 oldMax, uint256 newMax, address indexed updatedBy);

    constructor(address coaAddress, address wflowAddress) Ownable(msg.sender) {
        if (coaAddress == address(0)) revert InvalidCOAAddress();

        WFLOW = wflowAddress;
        authorizedCOA = coaAddress;
        maxPendingRequestsPerUser = 10;

        _setTokenConfig(NATIVE_FLOW, true, DEFAULT_MINIMUM_BALANCE, true);

        // WFLOW is treated as ERC20 on EVM side, but unwraps to native FlowToken on Cadence
        if (wflowAddress != address(0)) {
            _setTokenConfig(WFLOW, true, DEFAULT_MINIMUM_BALANCE, false);
        }
    }

    function onlyAuthorizedCOA(address user) external {
        if (user != authorizedCOA) revert NotAuthorizedCOA(user);
    }

    function checkAddress(address user) external {
        if (allowlistEnabled && !allowlisted[user]) {
            revert NotInAllowlist(user);
        }

        if (blocklistEnabled && blocklisted[user]) {
            revert Blocklisted(user);
        }

        if (paused) revert ContractPaused();
    }

    /// @notice Enables or disables allowlist enforcement
    /// @param _enabled True to enable, false to disable
    function setAllowlistEnabled(bool _enabled) external onlyOwner {
        allowlistEnabled = _enabled;
        emit AllowlistEnabled(_enabled, msg.sender);
    }

    /// @notice Sets the maximum pending requests allowed per user
    /// @param _maxRequests New limit (0 = unlimited)
    function setMaxPendingRequestsPerUser(
        uint256 _maxRequests
    ) external onlyOwner {
        uint256 oldMax = maxPendingRequestsPerUser;
        maxPendingRequestsPerUser = _maxRequests;
        emit MaxPendingRequestsPerUserUpdated(oldMax, _maxRequests, msg.sender);
    }

    /// @notice Adds multiple addresses to the allowlist
    /// @param _addresses Addresses to add
    function batchAddToAllowlist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            if (_addresses[i] == address(0))
                revert CannotAllowlistZeroAddress();
            allowlisted[_addresses[i]] = true;
            unchecked {
                ++i;
            }
        }

        emit AddressesAddedToAllowlist(_addresses, msg.sender);
    }

    /// @notice Removes multiple addresses from the allowlist
    /// @param _addresses Addresses to remove
    function batchRemoveFromAllowlist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            allowlisted[_addresses[i]] = false;
            unchecked {
                ++i;
            }
        }

        emit AddressesRemovedFromAllowlist(_addresses, msg.sender);
    }

    /// @notice Enables or disables blocklist enforcement
    /// @param _enabled True to enable, false to disable
    function setBlocklistEnabled(bool _enabled) external onlyOwner {
        blocklistEnabled = _enabled;
        emit BlocklistEnabled(_enabled, msg.sender);
    }

    /// @notice Adds multiple addresses to the blocklist
    /// @param _addresses Addresses to add
    function batchAddToBlocklist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            if (_addresses[i] == address(0))
                revert CannotBlocklistZeroAddress();
            blocklisted[_addresses[i]] = true;
            unchecked {
                ++i;
            }
        }

        emit AddressesAddedToBlocklist(_addresses, msg.sender);
    }

    /// @notice Removes multiple addresses from the blocklist
    /// @param _addresses Addresses to remove
    function batchRemoveFromBlocklist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            blocklisted[_addresses[i]] = false;
            unchecked {
                ++i;
            }
        }

        emit AddressesRemovedFromBlocklist(_addresses, msg.sender);
    }

    /// @notice Updates the authorized COA address
    /// @param _coa New COA address
    function setAuthorizedCOA(address _coa) external onlyOwner {
        if (_coa == address(0)) revert InvalidCOAAddress();
        address oldCOA = authorizedCOA;
        authorizedCOA = _coa;
        emit AuthorizedCOAUpdated(oldCOA, _coa);
    }

    /// @notice Pauses the contract, preventing new request creation
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses the contract, allowing new request creation
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Configures token support and requirements
    /// @param tokenAddress Token to configure
    /// @param isSupported Whether the token is supported
    /// @param minimumBalance Minimum deposit amount (in wei)
    /// @param isNative Whether this represents native $FLOW
    function setTokenConfig(
        address tokenAddress,
        bool isSupported,
        uint256 minimumBalance,
        bool isNative
    ) external onlyOwner {
        _setTokenConfig(tokenAddress, isSupported, minimumBalance, isNative);

        emit TokenConfigured(
            tokenAddress,
            isSupported,
            minimumBalance,
            isNative,
            msg.sender
        );
    }

    function getTrackedTokens() external view returns (address[] memory) {
        return trackedTokens;
    }

    /**
     * @dev Computes the precision residual that cannot be represented in Cadence UFix64.
     *      Cadence preserves at most 8 decimal places, so amounts are rounded down to the
     *      nearest token quantum of 10^(decimals-8) smallest units when decimals exceed 8.
     */
    function expectedPrecisionResidual(
        address tokenAddress,
        uint256 amount
    ) external view returns (uint256) {
        if (isNativeFlow(tokenAddress)) {
            return amount % 1e10;
        }

        uint8 decimals = IERC20Metadata(tokenAddress).decimals();
        if (decimals <= 8) return 0;

        uint8 precisionLossDecimals = decimals - 8;
        if (precisionLossDecimals > 77) return amount;

        uint256 quantum = 10 ** precisionLossDecimals;
        return amount % quantum;
    }

    function isNativeFlow(address tokenAddress) public view returns (bool) {
        return allowedTokens[tokenAddress].isNative;
    }

    /// @dev Stores token configuration and records tokens for future balance queries.
    function _setTokenConfig(
        address tokenAddress,
        bool isSupported,
        uint256 minimumBalance,
        bool isNative
    ) internal {
        if (isSupported && minimumBalance == 0) revert InvalidMinimumBalance();

        allowedTokens[tokenAddress] = TokenConfig({
            isSupported: isSupported,
            minimumBalance: minimumBalance,
            isNative: isNative
        });

        if (isSupported && !isTrackedToken[tokenAddress]) {
            isTrackedToken[tokenAddress] = true;
            trackedTokens.push(tokenAddress);
        }
    }
}

