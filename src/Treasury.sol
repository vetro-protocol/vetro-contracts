// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
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
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IGateway} from "./interfaces/IGateway.sol";

/// @title PeggedToken Treasury
contract Treasury is ReentrancyGuardTransient, AccessControlDefaultAdminRules {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsZero();
    error AddToListFailed();
    error AssetMismatch();
    error BalanceShouldBeZero();
    error CallerIsNotAuthorized(address caller);
    error DepositIsPaused(address);
    error InvalidOraclePrice();
    error InvalidPriceTolerance();
    error InvalidStalePeriod();
    error InvalidTokenDecimals(uint8);
    error PriceExceedTolerance(uint256 latestPrice, uint256 priceUpperBound, uint256 priceLowerBound);
    error RemoveFromListFailed();
    error ReservedToken();
    error StalePrice(address oracle);
    error UnsupportedToken(address);
    error PeggedTokenMismatch();
    error WithdrawIsPaused(address);

    string public NAME;
    string public constant VERSION = "1.0.0";
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UMM_ROLE = keccak256("UMM_ROLE");
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");

    uint256 public constant MAX_BPS = 10_000; // 10_000 = 100%
    uint256 public constant MAX_STALE_PERIOD = 72 hours;
    uint256 public priceTolerance = 100; // 1% based on BPS

    IPeggedToken public immutable PEGGED_TOKEN;

    address public swapper;

    struct TokenConfig {
        address vault;
        address oracle;
        uint256 stalePeriod;
        bool depositActive;
        bool withdrawActive;
        uint8 decimals;
    }

    mapping(address token => TokenConfig) public tokenConfig;

    EnumerableSet.AddressSet private _whitelistedTokens;

    event AddedToWhitelist(address indexed token, address indexed vault, address indexed oracle);
    event ExcessWithdrawn(address indexed token, uint256 amount);
    event RemovedFromWhitelist(address indexed token);
    event Migrated(address indexed newTreasury);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn);
    event Swept(address indexed token, uint256 amount, address indexed receiver);
    event ToggledDepositActive(address indexed token, bool newValue);
    event ToggledWithdrawActive(address indexed token, bool newValue);
    event UpdatedOracle(address indexed token, address indexed oracle, uint256 stalePeriod);
    event UpdatedPriceTolerance(uint256 previousPriceTolerance, uint256 newPriceTolerance);
    event UpdatedSwapper(address indexed previousSwapper, address indexed newSwapper);
    event WithdrawnAll(address[] tokens, address indexed receiver);

    constructor(address peggedToken_, address admin_)
        AccessControlDefaultAdminRules(
            3 days, // delay for admin transfers
            admin_ // initial admin
        )
    {
        if (peggedToken_ == address(0)) revert AddressIsZero();
        PEGGED_TOKEN = IPeggedToken(peggedToken_);
        NAME = string.concat(IERC20Metadata(peggedToken_).symbol(), "-Treasury");

        _grantRole(KEEPER_ROLE, msg.sender);
        _grantRole(MAINTAINER_ROLE, msg.sender);
    }

    modifier onlyGateway() {
        if (msg.sender != PEGGED_TOKEN.gateway()) revert CallerIsNotAuthorized(msg.sender);
        _;
    }

    /*/////////////////////////////////////////////////////////////
                            DEFAULT_ADMIN_ROLE
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
        if (stalePeriod_ == 0) revert InvalidStalePeriod();
        uint8 _decimals = IERC20Metadata(token_).decimals();
        if (_decimals > 18) revert InvalidTokenDecimals(_decimals);
        if (token_ != IERC4626(vault_).asset()) revert AssetMismatch();

        if (!_whitelistedTokens.add(token_)) revert AddToListFailed();
        tokenConfig[token_] = TokenConfig({
            vault: vault_,
            oracle: oracle_,
            stalePeriod: stalePeriod_,
            depositActive: true,
            withdrawActive: true,
            decimals: _decimals
        });
        IERC20(token_).forceApprove(vault_, type(uint256).max);

        emit AddedToWhitelist(token_, vault_, oracle_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Remove token from whitelist
     * @dev Removing token even if treasury has some balance of that token is intended behavior.
     * @param token_ token address to remove from whitelist.
     */
    function removeFromWhitelist(address token_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_whitelistedTokens.remove(token_)) revert RemoveFromListFailed();
        IERC4626 _vault = IERC4626(tokenConfig[token_].vault);
        if (_vault.balanceOf(address(this)) > 0) revert BalanceShouldBeZero();
        IERC20(token_).forceApprove(tokenConfig[token_].vault, 0);
        delete tokenConfig[token_];
        emit RemovedFromWhitelist(token_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Migrate assets to new treasury
     * @param newTreasury_ Address of new treasury of PeggedToken
     */
    function migrate(address newTreasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury_ == address(0)) revert AddressIsZero();
        if (address(PEGGED_TOKEN) != address(ITreasury(newTreasury_).PEGGED_TOKEN())) revert PeggedTokenMismatch();
        uint256 _len = _whitelistedTokens.length();
        for (uint256 i; i < _len; ++i) {
            address _token = _whitelistedTokens.at(i);
            IERC20(_token).safeTransfer(newTreasury_, IERC20(_token).balanceOf(address(this)));

            address _vault = tokenConfig[_token].vault;
            IERC20(_vault).safeTransfer(newTreasury_, IERC20(_vault).balanceOf(address(this)));
        }
        emit Migrated(newTreasury_);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Sweep any ERC20 token to owner address
     * @dev DEFAULT_ADMIN_ROLE can call this and vault shares are not allowed to sweep
     * @param fromToken_ Token address to sweep
     * @param receiver_ recipient of tokens being swept
     */
    function sweep(address fromToken_, address receiver_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (receiver_ == address(0)) revert AddressIsZero();
        if (_whitelistedTokens.contains(fromToken_)) revert ReservedToken();
        uint256 _len = _whitelistedTokens.length();
        for (uint256 i; i < _len; ++i) {
            if (tokenConfig[_whitelistedTokens.at(i)].vault == fromToken_) revert ReservedToken();
        }

        uint256 _amount = IERC20(fromToken_).balanceOf(address(this));
        IERC20(fromToken_).safeTransfer(receiver_, _amount);
        emit Swept(fromToken_, _amount, receiver_);
    }

    /*/////////////////////////////////////////////////////////////
                            MAINTAINER_ROLE
    /////////////////////////////////////////////////////////////*/

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
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (oracle_ == address(0)) revert AddressIsZero();
        if (newStalePeriod_ == 0 || newStalePeriod_ > MAX_STALE_PERIOD) revert InvalidStalePeriod();

        tokenConfig[token_].oracle = oracle_;
        tokenConfig[token_].stalePeriod = newStalePeriod_;

        emit UpdatedOracle(token_, oracle_, newStalePeriod_);
    }

    /// @notice MAINTAINER_ROLE: Update oracle price tolerance
    function updatePriceTolerance(uint256 newPriceTolerance_) external onlyRole(MAINTAINER_ROLE) {
        if (newPriceTolerance_ > MAX_BPS) revert InvalidPriceTolerance();
        emit UpdatedPriceTolerance(priceTolerance, newPriceTolerance_);
        priceTolerance = newPriceTolerance_;
    }

    /**
     * @notice MAINTAINER_ROLE: Update swapper address
     * @param swapper_ new swapper address
     */
    function updateSwapper(address swapper_) external onlyRole(MAINTAINER_ROLE) {
        if (swapper_ == address(0)) revert AddressIsZero();
        emit UpdatedSwapper(address(swapper), swapper_);
        swapper = swapper_;
    }

    /*/////////////////////////////////////////////////////////////
                            onlyGateway
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice onlyGateway: Deposit token to yield vault
     * @dev `depositActive` must be true to call deposit.
     * @param token_ token to deposit, must be one of the whitelisted tokens.
     * @param amount_  token amount
     */
    function deposit(address token_, uint256 amount_) external nonReentrant onlyGateway {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (!tokenConfig[token_].depositActive) revert DepositIsPaused(token_);

        IERC4626(tokenConfig[token_].vault).deposit(amount_, address(this));
    }

    /**
     * @notice onlyGateway: Withdraw given amount of token.
     * @dev `withdrawActive` must be true to call withdraw.
     * @param token_ token to withdraw, must be one of the whitelisted tokens.
     * @param amount_ token amount to withdraw
     * @param tokenReceiver_ address of token receiver
     */
    function withdraw(address token_, uint256 amount_, address tokenReceiver_) external nonReentrant onlyGateway {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);

        TokenConfig memory config = tokenConfig[token_];
        if (!config.withdrawActive) revert WithdrawIsPaused(token_);

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
                            KEEPER_ROLE
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice KEEPER_ROLE: Deposit token into the vault
     * @dev Keeper is allowed to deposit even if depositActive is false.
     * @param token_ token to deposit into the vault
     * @param amount_ token amount to deposit
     */
    function push(address token_, uint256 amount_) external onlyRole(KEEPER_ROLE) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (amount_ == type(uint256).max) {
            amount_ = IERC20(token_).balanceOf(address(this));
        }
        if (amount_ > 0) {
            IERC4626(tokenConfig[token_].vault).deposit(amount_, address(this));
        }
    }

    /**
     * @notice KEEPER_ROLE: Withdraw token from vault.
     * @dev Keeper is allowed to withdraw even if withdrawActive is false.
     * @dev Keeper can withdraw tokens at treasury address only.
     * @param token_ token to withdraw from vault
     * @param amount_ token amount to withdraw
     */
    function pull(address token_, uint256 amount_) external onlyRole(KEEPER_ROLE) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (amount_ > 0) {
            IERC4626(tokenConfig[token_].vault).withdraw(amount_, address(this), address(this));
        }
    }

    /// @notice KEEPER_ROLE: Set deposit activity for a whitelisted token
    /// @param token_ Token to set deposit activity for
    /// @param active_ The intended deposit active state
    function setDepositActive(address token_, bool active_) external onlyRole(KEEPER_ROLE) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        tokenConfig[token_].depositActive = active_;
        emit ToggledDepositActive(token_, active_);
    }

    /// @notice KEEPER_ROLE: Set withdraw activity for a whitelisted token
    /// @param token_ Token to set withdraw activity for
    /// @param active_ The intended withdraw active state
    function setWithdrawActive(address token_, bool active_) external onlyRole(KEEPER_ROLE) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        tokenConfig[token_].withdrawActive = active_;
        emit ToggledWithdrawActive(token_, active_);
    }

    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minAmountOut_)
        external
        onlyRole(KEEPER_ROLE)
        returns (uint256)
    {
        if (_whitelistedTokens.contains(tokenIn_)) revert ReservedToken();
        uint256 _len = _whitelistedTokens.length();
        for (uint256 i; i < _len; ++i) {
            if (tokenConfig[_whitelistedTokens.at(i)].vault == tokenIn_) revert ReservedToken();
        }
        IERC20(tokenIn_).forceApprove(swapper, amountIn_);
        emit Swapped(tokenIn_, tokenOut_, amountIn_);
        return ISwapper(swapper).swapExactInput(tokenIn_, tokenOut_, amountIn_, minAmountOut_, address(this));
    }

    /*/////////////////////////////////////////////////////////////
                            UMM_ROLE
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice UMM_ROLE: Withdraw excess tokens from reserve.
     * Note: As treasury reserve is in multiple tokens, there is no guarantee
     * that this function will withdraw all of the excess in given token.
     * @param token_ Token address to withdraw excess
     * @param receiver_ Address to receive the withdrawn tokens
     * @return Amount of tokens withdrawn
     */
    function harvest(address token_, address receiver_) external onlyRole(UMM_ROLE) nonReentrant returns (uint256) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (receiver_ == address(0)) revert AddressIsZero();
        uint256 _excess = _excessTokens(token_);
        if (_excess == 0) return 0;

        uint256 _paid;
        uint256 _balance = IERC20(token_).balanceOf(address(this));
        if (_balance > 0) {
            uint256 _toPay = Math.min(_balance, _excess);
            IERC20(token_).safeTransfer(receiver_, _toPay);
            _paid = _toPay;
            if (_paid == _excess) {
                emit ExcessWithdrawn(token_, _paid);
                return _paid;
            }
            _excess -= _paid;
        }

        IERC4626 _vault = IERC4626(tokenConfig[token_].vault);
        uint256 _assets = _vault.convertToAssets(_vault.balanceOf(address(this)));
        if (_assets > 0) {
            uint256 _toWithdraw = Math.min(_excess, _assets);
            _vault.withdraw(_toWithdraw, receiver_, address(this));
            _paid += _toWithdraw;
        }

        emit ExcessWithdrawn(token_, _paid);
        return _paid;
    }

    /*/////////////////////////////////////////////////////////////
                            getter
    /////////////////////////////////////////////////////////////*/

    function gateway() external view returns (address) {
        return PEGGED_TOKEN.gateway();
    }

    function getPrice(address token_) external view returns (uint256 _latestPrice, uint256 _unitPrice) {
        IAggregatorV3 _oracle = IAggregatorV3(tokenConfig[token_].oracle);
        if (address(_oracle) == address(0)) revert UnsupportedToken(token_);
        return _getPrice(_oracle, tokenConfig[token_].stalePeriod, priceTolerance);
    }

    /// @notice Returns whether given token is whitelisted
    function isWhitelistedToken(address token_) external view returns (bool) {
        return _whitelistedTokens.contains(token_);
    }

    /// @notice Returns total reserve value denominated in PeggedToken units
    function reserve() public view returns (uint256 _reserve) {
        uint256 _len = _whitelistedTokens.length();
        uint256 _priceToleranceBps = priceTolerance;

        for (uint256 i; i < _len;) {
            address _token = _whitelistedTokens.at(i);
            IERC4626 _vault = IERC4626(tokenConfig[_token].vault);
            uint256 _shares = _vault.balanceOf(address(this));
            uint256 _balance = IERC20(_token).balanceOf(address(this));
            if (_shares > 0) {
                _balance += _vault.convertToAssets(_shares);
            }

            if (_balance > 0) {
                (uint256 _price, uint256 _unitPrice) = _getPrice(
                    IAggregatorV3(tokenConfig[_token].oracle), tokenConfig[_token].stalePeriod, _priceToleranceBps
                );
                // Calculate reserve in token decimals relative to PeggedToken peg
                uint256 _reserveInTokenDecimals = _balance.mulDiv(_price, _unitPrice);
                // Normalize reserve to PeggedToken decimals (18) before adding to total reserve
                _reserve += (_reserveInTokenDecimals * (10 ** (18 - tokenConfig[_token].decimals)));
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Return list of whitelisted tokens
    function whitelistedTokens() external view returns (address[] memory) {
        return _whitelistedTokens.values();
    }

    /**
     * @notice Current withdrawable for given token.
     * If token is not supported by treasury it will return 0.
     * @param token_ token address
     */
    function withdrawable(address token_) external view returns (uint256) {
        IERC4626 _vault = IERC4626(tokenConfig[token_].vault);
        // Token is not supported
        if (address(_vault) == address(0)) return 0;

        uint256 _shares = _vault.balanceOf(address(this));
        return IERC20(token_).balanceOf(address(this)) + (_shares > 0 ? _vault.convertToAssets(_shares) : 0);
    }

    function _excessTokens(address token_) private view returns (uint256 excess) {
        // Excess = reserve - (supply - amoSupply)
        uint256 _totalSupply = PEGGED_TOKEN.totalSupply();
        // Get AMO supply from Gateway
        uint256 _amoSupply = IGateway(PEGGED_TOKEN.gateway()).amoSupply();

        // Invariant: amoSupply <= totalSupply always holds
        uint256 _backedSupply = _totalSupply - _amoSupply;
        uint256 _reserve = reserve();
        if (_reserve <= _backedSupply) return 0;

        uint256 _excess;
        unchecked {
            _excess = _reserve - _backedSupply;
        }

        // Convert excess (in PeggedToken decimals) to token amount
        TokenConfig storage _config = tokenConfig[token_];
        (uint256 _price, uint256 _unitPrice) =
            _getPrice(IAggregatorV3(_config.oracle), _config.stalePeriod, priceTolerance);
        uint256 _tokens = _excess.mulDiv(_unitPrice, _price) / (10 ** (18 - _config.decimals));

        return _tokens;
    }

    function _getPrice(IAggregatorV3 oracle_, uint256 stalePeriod_, uint256 priceToleranceBps_)
        private
        view
        returns (uint256 _latestPrice, uint256 _unitPrice)
    {
        (, int256 _price,, uint256 _updatedAt,) = oracle_.latestRoundData();
        if (block.timestamp - _updatedAt >= stalePeriod_) revert StalePrice(address(oracle_));
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
}
