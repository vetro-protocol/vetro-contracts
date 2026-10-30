// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAggregatorV3} from "./interfaces/chainlink/IAggregatorV3.sol";
import {ISwapper} from "./interfaces/bloq/ISwapper.sol";
import {IPeggedToken} from "./interfaces/IPeggedToken.sol";
import {IGateway} from "./interfaces/IGateway.sol";

/// @title PeggedToken Treasury
contract Treasury is ReentrancyGuardTransient, AccessControlDefaultAdminRulesUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*/////////////////////////////////////////////////////////////
                            CONSTANTS
    /////////////////////////////////////////////////////////////*/

    string public constant VERSION = "2.0.0";
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UMM_ROLE = keccak256("UMM_ROLE");
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");

    uint256 public constant MAX_BPS = 10_000; // 10_000 = 100%
    uint256 public constant MAX_STALE_PERIOD = 72 hours;
    uint256 public constant MAX_WHITELISTED_TOKENS = 10;

    /*/////////////////////////////////////////////////////////////
                        ERC-7201 STORAGE
    /////////////////////////////////////////////////////////////*/

    struct TokenConfig {
        address vault;
        address oracle;
        uint256 stalePeriod;
        bool depositActive;
        bool withdrawActive;
        uint8 decimals;
        uint256 depositCap;
        uint256 netDeposited;
        uint256 pegBand;
    }

    /// @custom:storage-location erc7201:vetro.storage.treasury
    struct TreasuryStorage {
        string name;
        uint256 priceTolerance;
        IPeggedToken peggedToken;
        address swapper;
        mapping(address token => TokenConfig) tokenConfig;
        EnumerableSet.AddressSet whitelistedTokens;
    }

    bytes32 private constant TREASURY_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("vetro.storage.treasury")) - 1)) & ~bytes32(uint256(0xff));

    /*/////////////////////////////////////////////////////////////
                            ERRORS
    /////////////////////////////////////////////////////////////*/

    error AddressIsZero();
    error AddToListFailed();
    error AssetMismatch();
    error BalanceShouldBeZero();
    error CallerIsNotAuthorized(address caller);
    error DepositIsPaused(address);
    error ExceededDepositCap(address token, uint256 newNetDeposited, uint256 depositCap);
    error InvalidOraclePrice();
    error InvalidPegBand(uint256 pegBand, uint256 priceTolerance);
    error InvalidPriceTolerance();
    error InvalidReceiver(address receiver);
    error InvalidStalePeriod();
    error InvalidTokenDecimals(uint8);
    error MaxWhitelistedTokensReached();
    error PriceExceedTolerance(uint256 latestPrice, uint256 priceUpperBound, uint256 priceLowerBound);
    error RemoveFromListFailed();
    error ReservedToken();
    error StalePrice(address oracle);
    error SwapperNotSet();
    error UnsupportedToken(address);
    error WithdrawIsPaused(address);
    error ZeroShares();

    /*/////////////////////////////////////////////////////////////
                            EVENTS
    /////////////////////////////////////////////////////////////*/

    event AddedToWhitelist(address indexed token, address indexed vault, address indexed oracle);
    event ExcessWithdrawn(address indexed token, uint256 amount);
    event RemovedFromWhitelist(address indexed token);
    event SetDepositActive(address indexed token, bool newValue);
    event SetWithdrawActive(address indexed token, bool newValue);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn);
    event Swept(address indexed token, uint256 amount, address indexed receiver);
    event UpdatedDepositCap(address indexed token, uint256 previousDepositCap, uint256 newDepositCap);
    event UpdatedOracle(address indexed token, address indexed oracle, uint256 stalePeriod);
    event UpdatedPegBand(address indexed token, uint256 previousPegBand, uint256 newPegBand);
    event UpdatedPriceTolerance(uint256 previousPriceTolerance, uint256 newPriceTolerance);
    event UpdatedSwapper(address indexed previousSwapper, address indexed newSwapper);

    /*/////////////////////////////////////////////////////////////
                            MODIFIERS
    /////////////////////////////////////////////////////////////*/

    modifier onlyGateway() {
        if (msg.sender != _getTreasuryStorage().peggedToken.gateway()) revert CallerIsNotAuthorized(msg.sender);
        _;
    }

    /*/////////////////////////////////////////////////////////////
                            FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Treasury contract
    /// @param peggedToken_ Address of the PeggedToken contract
    /// @param admin_ Initial DEFAULT_ADMIN_ROLE holder
    function initialize(address peggedToken_, address admin_) external initializer {
        if (peggedToken_ == address(0)) revert AddressIsZero();
        __AccessControlDefaultAdminRules_init(
            3 days, // delay for admin transfers
            admin_ // initial admin
        );

        TreasuryStorage storage $ = _getTreasuryStorage();
        $.peggedToken = IPeggedToken(peggedToken_);
        $.name = string.concat(IERC20Metadata(peggedToken_).symbol(), "-Treasury");
        $.priceTolerance = 100; // 1% based on BPS
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL STATE-CHANGING FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice DEFAULT_ADMIN_ROLE: Add token as whitelisted token for PeggedToken
     * @param token_ token address to add in whitelist.
     * @param vault_ ERC4626 yield vault address correspond to _token
     * @param oracle_ Chainlink oracle address for token/USD feed
     * @param stalePeriod_ Custom stale period for oracle price
     */
    function addToWhitelist(address token_, address vault_, address oracle_, uint256 stalePeriod_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token_ == address(0) || vault_ == address(0) || oracle_ == address(0)) revert AddressIsZero();
        if (stalePeriod_ == 0 || stalePeriod_ > MAX_STALE_PERIOD) revert InvalidStalePeriod();
        TreasuryStorage storage $ = _getTreasuryStorage();
        if ($.whitelistedTokens.length() >= MAX_WHITELISTED_TOKENS) revert MaxWhitelistedTokensReached();
        uint8 _decimals = IERC20Metadata(token_).decimals();
        if (_decimals > 18) revert InvalidTokenDecimals(_decimals);
        if (token_ != IERC4626(vault_).asset()) revert AssetMismatch();

        if (!$.whitelistedTokens.add(token_)) revert AddToListFailed();
        $.tokenConfig[token_] = TokenConfig({
            vault: vault_,
            oracle: oracle_,
            stalePeriod: stalePeriod_,
            depositActive: true,
            withdrawActive: true,
            decimals: _decimals,
            depositCap: type(uint256).max,
            netDeposited: 0,
            pegBand: 0
        });
        IERC20(token_).forceApprove(vault_, type(uint256).max);

        emit AddedToWhitelist(token_, vault_, oracle_);
    }

    /**
     * @notice onlyGateway: Deposit token to yield vault
     * @dev `depositActive` must be true to call deposit, and the token's net deposits may not exceed its deposit cap.
     * @param token_ token to deposit, must be one of the whitelisted tokens.
     * @param amount_  token amount
     */
    function deposit(address token_, uint256 amount_) external nonReentrant onlyGateway {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        TokenConfig storage _config = $.tokenConfig[token_];
        if (!_config.depositActive) revert DepositIsPaused(token_);
        uint256 _netDeposited = _config.netDeposited + amount_;
        if (_netDeposited > _config.depositCap) revert ExceededDepositCap(token_, _netDeposited, _config.depositCap);
        _config.netDeposited = _netDeposited;

        if (IERC4626(_config.vault).deposit(amount_, address(this)) == 0) revert ZeroShares();
    }

    /**
     * @notice UMM_ROLE: Withdraw excess tokens from reserve.
     * Note: As treasury reserve is in multiple tokens, there is no guarantee
     * that this function will withdraw all of the excess in given token.
     * @param token_ Token address to withdraw excess
     * @param receiver_ Address to receive the withdrawn tokens, not this Treasury or its vault
     * @return Amount of tokens withdrawn
     */
    function harvest(address token_, address receiver_) external onlyRole(UMM_ROLE) nonReentrant returns (uint256) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (receiver_ == address(0)) revert AddressIsZero();
        if (receiver_ == address(this) || receiver_ == $.tokenConfig[token_].vault) revert InvalidReceiver(receiver_);
        uint256 _excess = _excessTokens(token_);
        if (_excess == 0) return 0;

        uint256 _paid;
        uint256 _balance = IERC20(token_).balanceOf(address(this));
        if (_balance > 0) {
            uint256 _toPay = Math.min(_balance, _excess);
            IERC20(token_).safeTransfer(receiver_, _toPay);
            _paid = _toPay;
            _excess -= _paid;
        }

        if (_excess > 0) {
            IERC4626 _vault = IERC4626($.tokenConfig[token_].vault);
            uint256 _assets = _vault.maxWithdraw(address(this));
            if (_assets > 0) {
                uint256 _toWithdraw = Math.min(_excess, _assets);
                _vault.withdraw(_toWithdraw, receiver_, address(this));
                _paid += _toWithdraw;
            }
        }

        _reduceNetDeposited($.tokenConfig[token_], _paid);

        emit ExcessWithdrawn(token_, _paid);
        return _paid;
    }

    /**
     * @notice KEEPER_ROLE: Withdraw token from vault.
     * @dev Keeper is allowed to withdraw even if withdrawActive is false.
     * @dev Keeper can withdraw tokens at treasury address only.
     * @param token_ token to withdraw from vault
     * @param amount_ token amount to withdraw
     */
    function pull(address token_, uint256 amount_) external onlyRole(KEEPER_ROLE) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (amount_ > 0) {
            IERC4626($.tokenConfig[token_].vault).withdraw(amount_, address(this), address(this));
        }
    }

    /**
     * @notice KEEPER_ROLE: Deposit token into the vault
     * @dev Keeper is allowed to deposit even if depositActive is false.
     * @param token_ token to deposit into the vault
     * @param amount_ token amount to deposit
     */
    function push(address token_, uint256 amount_) external onlyRole(KEEPER_ROLE) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (amount_ == type(uint256).max) {
            amount_ = IERC20(token_).balanceOf(address(this));
        }
        if (amount_ > 0) {
            if (IERC4626($.tokenConfig[token_].vault).deposit(amount_, address(this)) == 0) revert ZeroShares();
        }
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Remove token from whitelist
     * @dev Removing token even if treasury has some balance of that token is intended behavior.
     * @param token_ token address to remove from whitelist.
     */
    function removeFromWhitelist(address token_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.remove(token_)) revert RemoveFromListFailed();
        IERC4626 _vault = IERC4626($.tokenConfig[token_].vault);
        if (_vault.balanceOf(address(this)) > 0) revert BalanceShouldBeZero();
        IERC20(token_).forceApprove($.tokenConfig[token_].vault, 0);
        delete $.tokenConfig[token_];
        emit RemovedFromWhitelist(token_);
    }

    /// @notice KEEPER_ROLE: Set deposit activity for a whitelisted token
    /// @param token_ Token to set deposit activity for
    /// @param active_ The intended deposit active state
    function setDepositActive(address token_, bool active_) external onlyRole(KEEPER_ROLE) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        $.tokenConfig[token_].depositActive = active_;
        emit SetDepositActive(token_, active_);
    }

    /// @notice KEEPER_ROLE: Set withdraw activity for a whitelisted token
    /// @param token_ Token to set withdraw activity for
    /// @param active_ The intended withdraw active state
    function setWithdrawActive(address token_, bool active_) external onlyRole(KEEPER_ROLE) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        $.tokenConfig[token_].withdrawActive = active_;
        emit SetWithdrawActive(token_, active_);
    }

    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minAmountOut_)
        external
        onlyRole(KEEPER_ROLE)
        returns (uint256)
    {
        TreasuryStorage storage $ = _getTreasuryStorage();
        address _swapper = $.swapper;
        if (_swapper == address(0)) revert SwapperNotSet();
        if ($.whitelistedTokens.contains(tokenIn_)) revert ReservedToken();
        uint256 _len = $.whitelistedTokens.length();
        for (uint256 i; i < _len; ++i) {
            if ($.tokenConfig[$.whitelistedTokens.at(i)].vault == tokenIn_) revert ReservedToken();
        }
        IERC20(tokenIn_).forceApprove(_swapper, amountIn_);
        emit Swapped(tokenIn_, tokenOut_, amountIn_);
        return ISwapper(_swapper).swapExactInput(tokenIn_, tokenOut_, amountIn_, minAmountOut_, address(this));
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Sweep any ERC20 token to owner address
     * @dev DEFAULT_ADMIN_ROLE can call this and vault shares are not allowed to sweep
     * @param fromToken_ Token address to sweep
     * @param receiver_ recipient of tokens being swept
     */
    function sweep(address fromToken_, address receiver_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (receiver_ == address(0)) revert AddressIsZero();
        TreasuryStorage storage $ = _getTreasuryStorage();
        if ($.whitelistedTokens.contains(fromToken_)) revert ReservedToken();
        uint256 _len = $.whitelistedTokens.length();
        for (uint256 i; i < _len; ++i) {
            if ($.tokenConfig[$.whitelistedTokens.at(i)].vault == fromToken_) revert ReservedToken();
        }

        uint256 _amount = IERC20(fromToken_).balanceOf(address(this));
        IERC20(fromToken_).safeTransfer(receiver_, _amount);
        emit Swept(fromToken_, _amount, receiver_);
    }

    /**
     * @notice MAINTAINER_ROLE: Update the most of a token that may be deposited net of what has left
     * @dev Gates intake, so a vault loss or a depeg the oracle misses does not open room. Net deposits go up on
     * {deposit} and down on {withdraw} and {harvest}, never below 0, and start at 0 when the token is whitelisted.
     * type(uint256).max means no cap.
     * @param token_ Token to update deposit cap for
     * @param newDepositCap_ New deposit cap in token units
     */
    function updateDepositCap(address token_, uint256 newDepositCap_) external onlyRole(MAINTAINER_ROLE) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        emit UpdatedDepositCap(token_, $.tokenConfig[token_].depositCap, newDepositCap_);
        $.tokenConfig[token_].depositCap = newDepositCap_;
    }

    /**
     * @notice MAINTAINER_ROLE: Update oracle and stale period
     * @param token_ Token to update oracle configuration for
     * @param oracle_ New Chainlink oracle address
     * @param newStalePeriod_ New stale period threshold in seconds
     */
    function updateOracle(address token_, address oracle_, uint256 newStalePeriod_)
        external
        onlyRole(MAINTAINER_ROLE)
    {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (oracle_ == address(0)) revert AddressIsZero();
        if (newStalePeriod_ == 0 || newStalePeriod_ > MAX_STALE_PERIOD) revert InvalidStalePeriod();

        $.tokenConfig[token_].oracle = oracle_;
        $.tokenConfig[token_].stalePeriod = newStalePeriod_;

        emit UpdatedOracle(token_, oracle_, newStalePeriod_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Update the band around par in which the Gateway mints and redeems at par
     * @dev Must be below priceTolerance. A band later left at or above it, by a lowered tolerance, counts as no band.
     * @param token_ Token to update peg band for
     * @param newPegBand_ New peg band in BPS
     */
    function updatePegBand(address token_, uint256 newPegBand_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        uint256 _priceTolerance = $.priceTolerance;
        if (newPegBand_ >= _priceTolerance) revert InvalidPegBand(newPegBand_, _priceTolerance);
        emit UpdatedPegBand(token_, $.tokenConfig[token_].pegBand, newPegBand_);
        $.tokenConfig[token_].pegBand = newPegBand_;
    }

    /// @notice MAINTAINER_ROLE: Update oracle price tolerance
    function updatePriceTolerance(uint256 newPriceTolerance_) external onlyRole(MAINTAINER_ROLE) {
        if (newPriceTolerance_ > MAX_BPS) revert InvalidPriceTolerance();
        TreasuryStorage storage $ = _getTreasuryStorage();
        emit UpdatedPriceTolerance($.priceTolerance, newPriceTolerance_);
        $.priceTolerance = newPriceTolerance_;
    }

    /**
     * @notice MAINTAINER_ROLE: Update swapper address
     * @param swapper_ new swapper address
     */
    function updateSwapper(address swapper_) external onlyRole(MAINTAINER_ROLE) {
        if (swapper_ == address(0)) revert AddressIsZero();
        TreasuryStorage storage $ = _getTreasuryStorage();
        emit UpdatedSwapper($.swapper, swapper_);
        $.swapper = swapper_;
    }

    /**
     * @notice onlyGateway: Withdraw given amount of token.
     * @dev `withdrawActive` must be true to call withdraw, and the receiver may not be this Treasury or its vault.
     * @param token_ token to withdraw, must be one of the whitelisted tokens.
     * @param amount_ token amount to withdraw
     * @param tokenReceiver_ address of token receiver
     */
    function withdraw(address token_, uint256 amount_, address tokenReceiver_) external nonReentrant onlyGateway {
        TreasuryStorage storage $ = _getTreasuryStorage();
        if (!$.whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);

        TokenConfig memory config = $.tokenConfig[token_];
        if (!config.withdrawActive) revert WithdrawIsPaused(token_);
        if (tokenReceiver_ == address(this) || tokenReceiver_ == config.vault) revert InvalidReceiver(tokenReceiver_);
        _reduceNetDeposited($.tokenConfig[token_], amount_);

        uint256 _tokenBalance = IERC20(token_).balanceOf(address(this));
        if (_tokenBalance >= amount_) {
            // Transfer directly if we have enough balance
            IERC20(token_).safeTransfer(tokenReceiver_, amount_);
        } else {
            // Handle partial balance + vault withdrawal
            if (_tokenBalance > 0) {
                IERC20(token_).safeTransfer(tokenReceiver_, _tokenBalance);
                amount_ -= _tokenBalance;
            }
            IERC4626(config.vault).withdraw(amount_, tokenReceiver_, address(this));
        }
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @notice Returns the most of a token that may be deposited net of what has left, 0 if it is not whitelisted
    function depositCap(address token_) external view returns (uint256) {
        return _getTreasuryStorage().tokenConfig[token_].depositCap;
    }

    function gateway() external view returns (address) {
        return _getTreasuryStorage().peggedToken.gateway();
    }

    function getPrice(address token_) external view returns (uint256 _latestPrice, uint256 _unitPrice) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        IAggregatorV3 _oracle = IAggregatorV3($.tokenConfig[token_].oracle);
        if (address(_oracle) == address(0)) revert UnsupportedToken(token_);
        return _getPrice(_oracle, $.tokenConfig[token_].stalePeriod, $.priceTolerance);
    }

    /**
     * @notice Returns the price the Gateway mints PeggedToken at for `token_`
     * @dev Par from the peg floor up, else the oracle price
     */
    function getMintPrice(address token_) external view returns (uint256 _mintPrice, uint256 _unitPrice) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        TokenConfig storage _config = $.tokenConfig[token_];
        if (_config.oracle == address(0)) revert UnsupportedToken(token_);
        return _getMintPrice(_config, $.priceTolerance);
    }

    /**
     * @notice Returns the price the Gateway redeems PeggedToken at for `token_`
     * @dev Par up to the peg ceiling, else the oracle price
     */
    function getRedeemPrice(address token_) external view returns (uint256 _redeemPrice, uint256 _unitPrice) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        TokenConfig storage _config = $.tokenConfig[token_];
        if (_config.oracle == address(0)) revert UnsupportedToken(token_);
        uint256 _priceTolerance = $.priceTolerance;
        (_redeemPrice, _unitPrice) = _getPrice(IAggregatorV3(_config.oracle), _config.stalePeriod, _priceTolerance);
        uint256 _pegCeiling = _unitPrice + (_unitPrice * _effectivePegBand(_config.pegBand, _priceTolerance) / MAX_BPS);
        if (_redeemPrice <= _pegCeiling) _redeemPrice = _unitPrice;
    }

    /// @notice Returns whether given token is whitelisted
    function isWhitelistedToken(address token_) external view returns (bool) {
        return _getTreasuryStorage().whitelistedTokens.contains(token_);
    }

    /**
     * @notice Token amount that can still be deposited: the room under the deposit cap, bounded by what the vault
     * accepts
     * @dev 0 when the token is not whitelisted or its deposits are paused.
     * @param token_ token address
     */
    function maxDeposit(address token_) external view returns (uint256) {
        TokenConfig storage _config = _getTreasuryStorage().tokenConfig[token_];
        if (!_config.depositActive) return 0;
        if (_config.depositCap <= _config.netDeposited) return 0;
        return Math.min(_config.depositCap - _config.netDeposited, IERC4626(_config.vault).maxDeposit(address(this)));
    }

    /// @notice Returns the name of the Treasury
    function NAME() external view returns (string memory) {
        return _getTreasuryStorage().name;
    }

    /// @notice Returns what has been deposited of a token net of what has left, as counted against its deposit cap
    function netDeposited(address token_) external view returns (uint256) {
        return _getTreasuryStorage().tokenConfig[token_].netDeposited;
    }

    /// @notice Returns the configured peg band of a token in BPS, 0 if it is not whitelisted
    function pegBand(address token_) external view returns (uint256) {
        return _getTreasuryStorage().tokenConfig[token_].pegBand;
    }

    /// @notice Returns the PeggedToken this Treasury backs
    function PEGGED_TOKEN() external view returns (IPeggedToken) {
        return _getTreasuryStorage().peggedToken;
    }

    /// @notice Returns the oracle price tolerance in BPS
    function priceTolerance() external view returns (uint256) {
        return _getTreasuryStorage().priceTolerance;
    }

    /// @notice Returns the swapper used by {swap}
    function swapper() external view returns (address) {
        return _getTreasuryStorage().swapper;
    }

    /// @notice Returns the configuration of given token, all zero if it is not whitelisted
    function tokenConfig(address token_)
        external
        view
        returns (
            address vault,
            address oracle,
            uint256 stalePeriod,
            bool depositActive,
            bool withdrawActive,
            uint8 decimals
        )
    {
        TokenConfig storage _config = _getTreasuryStorage().tokenConfig[token_];
        return (
            _config.vault,
            _config.oracle,
            _config.stalePeriod,
            _config.depositActive,
            _config.withdrawActive,
            _config.decimals
        );
    }

    /// @notice Return list of whitelisted tokens
    function whitelistedTokens() external view returns (address[] memory) {
        return _getTreasuryStorage().whitelistedTokens.values();
    }

    /**
     * @notice Current withdrawable for given token.
     * If token is not supported by treasury it will return 0.
     * @dev Idle balance plus the vault's `maxWithdraw` for the Treasury. The yield vaults report book value there, not
     * liquidity: a withdrawal reverts if idle plus what the vault can free at once falls short.
     * @param token_ token address
     */
    function withdrawable(address token_) external view returns (uint256) {
        IERC4626 _vault = IERC4626(_getTreasuryStorage().tokenConfig[token_].vault);
        // Token is not supported
        if (address(_vault) == address(0)) return 0;

        return IERC20(token_).balanceOf(address(this)) + _vault.maxWithdraw(address(this));
    }

    /*/////////////////////////////////////////////////////////////
                    PUBLIC VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @notice Returns total reserve value denominated in PeggedToken units
    /// @dev Each token is valued at its oracle price capped at par
    function reserve() public view returns (uint256 _reserve) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        uint256 _len = $.whitelistedTokens.length();
        uint256 _priceToleranceBps = $.priceTolerance;

        for (uint256 i; i < _len; ++i) {
            address _token = $.whitelistedTokens.at(i);
            IERC4626 _vault = IERC4626($.tokenConfig[_token].vault);
            uint256 _shares = _vault.balanceOf(address(this));
            uint256 _balance = IERC20(_token).balanceOf(address(this));
            if (_shares > 0) {
                _balance += _vault.convertToAssets(_shares);
            }

            if (_balance > 0) {
                (uint256 _price, uint256 _unitPrice) = _getPrice(
                    IAggregatorV3($.tokenConfig[_token].oracle), $.tokenConfig[_token].stalePeriod, _priceToleranceBps
                );
                // Gateway never mints above par, so an above-par price would surface as phantom harvestable excess
                if (_price > _unitPrice) _price = _unitPrice;
                // Calculate reserve in token decimals relative to PeggedToken peg
                uint256 _reserveInTokenDecimals = _balance.mulDiv(_price, _unitPrice);
                // Normalize reserve to PeggedToken decimals (18) before adding to total reserve
                _reserve += (_reserveInTokenDecimals * (10 ** (18 - $.tokenConfig[_token].decimals)));
            }
        }
    }

    /*/////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    function _excessTokens(address token_) private view returns (uint256 excess) {
        TreasuryStorage storage $ = _getTreasuryStorage();
        IPeggedToken _peggedToken = $.peggedToken;
        // Excess = reserve - (supply - amoSupply)
        uint256 _totalSupply = _peggedToken.totalSupply();
        // Get AMO supply from Gateway
        uint256 _amoSupply = IGateway(_peggedToken.gateway()).amoSupply();

        // Invariant: amoSupply <= totalSupply always holds
        uint256 _backedSupply = _totalSupply - _amoSupply;
        uint256 _reserve = reserve();
        if (_reserve <= _backedSupply) return 0;

        uint256 _excess;
        unchecked {
            _excess = _reserve - _backedSupply;
        }

        // Convert excess (in PeggedToken decimals) to token amount, at the price the Gateway re-mints it at
        TokenConfig storage _config = $.tokenConfig[token_];
        (uint256 _price, uint256 _unitPrice) = _getMintPrice(_config, $.priceTolerance);
        uint256 _tokens = _excess.mulDiv(_unitPrice, _price) / (10 ** (18 - _config.decimals));

        return _tokens;
    }

    /// @dev A band at or above priceTolerance would par-price the entire accepted band, so it counts as no band
    function _effectivePegBand(uint256 pegBand_, uint256 priceToleranceBps_) private pure returns (uint256) {
        return pegBand_ < priceToleranceBps_ ? pegBand_ : 0;
    }

    function _getMintPrice(TokenConfig storage config_, uint256 priceToleranceBps_)
        private
        view
        returns (uint256 _mintPrice, uint256 _unitPrice)
    {
        (_mintPrice, _unitPrice) = _getPrice(IAggregatorV3(config_.oracle), config_.stalePeriod, priceToleranceBps_);
        uint256 _pegFloor = _unitPrice - (_unitPrice * _effectivePegBand(config_.pegBand, priceToleranceBps_) / MAX_BPS);
        if (_mintPrice >= _pegFloor) _mintPrice = _unitPrice;
    }

    function _getPrice(IAggregatorV3 oracle_, uint256 stalePeriod_, uint256 priceToleranceBps_)
        private
        view
        returns (uint256 _latestPrice, uint256 _unitPrice)
    {
        (, int256 _price,, uint256 _updatedAt,) = oracle_.latestRoundData();
        // A future-dated round is treated as stale rather than underflowing into a panic
        if (_updatedAt > block.timestamp || block.timestamp - _updatedAt >= stalePeriod_) {
            revert StalePrice(address(oracle_));
        }
        if (_price <= 0) revert InvalidOraclePrice();
        _latestPrice = uint256(_price);

        // Unit oracle price for given token relative to PeggedToken peg.
        _unitPrice = 10 ** oracle_.decimals();
        uint256 _priceToleranceValue = (_unitPrice * priceToleranceBps_) / MAX_BPS;
        uint256 _priceUpperBound = _unitPrice + _priceToleranceValue;
        uint256 _priceLowerBound = _unitPrice - _priceToleranceValue;

        if (_latestPrice > _priceUpperBound || _latestPrice < _priceLowerBound) {
            revert PriceExceedTolerance(_latestPrice, _priceUpperBound, _priceLowerBound);
        }
    }

    /// @notice Get the storage pointer for ERC-7201 namespaced storage
    /// @return $ The storage pointer
    function _getTreasuryStorage() private pure returns (TreasuryStorage storage $) {
        bytes32 _location = TREASURY_STORAGE_LOCATION;
        assembly {
            $.slot := _location
        }
    }

    /// @dev Never below 0: redemptions can exceed deposits, e.g. of migrated collateral or of another token's deposit
    function _reduceNetDeposited(TokenConfig storage config_, uint256 amount_) private {
        uint256 _netDeposited = config_.netDeposited;
        config_.netDeposited = _netDeposited > amount_ ? _netDeposited - amount_ : 0;
    }
}
