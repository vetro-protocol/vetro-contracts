// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
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

/// @title PeggedToken Treasury
contract Treasury is ReentrancyGuardTransient, AccessControlEnumerable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsZero();
    error AddToListFailed();
    error AssetMismatch();
    error BalanceShouldBeZero();
    error CallerIsNotAuthorized(address caller);
    error DepositIsPaused(address);
    error InvalidPriceTolerance();
    error InvalidStalePeriod();
    error InvalidTokenDecimals(uint8);
    error PriceExceedTolerance(uint256 latestPrice, uint256 priceUpperBound, uint256 priceLowerBound);
    error RemoveFromListFailed();
    error ReservedToken();
    error StalePrice();
    error UnsupportedToken(address);
    error PeggedTokenMismatch();
    error WithdrawIsPaused(address);

    string public NAME;
    string public constant VERSION = "1.0.0";
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UMM_ROLE = keccak256("UMM_ROLE");

    uint256 public constant MAX_BPS = 10_000; // 10_000 = 100%
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

    event AddedToWhitelist(address indexed token, address vault, address oracle);
    event ExcessWithdrawn(address indexed token, uint256 amount);
    event RemovedFromWhitelist(address indexed token);
    event Migrated(address indexed newTreasury);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn);
    event Swept(address indexed token, uint256 amount, address indexed receiver);
    event ToggledDepositActive(bool newValue);
    event ToggledWithdrawActive(bool newValue);
    event UpdatedOracle(address indexed token, address indexed oracle, uint256 stalePeriod);
    event UpdatedPriceTolerance(uint256 previousPriceTolerance, uint256 newPriceTolerance);
    event UpdatedSwapper(address indexed previousSwapper, address indexed newSwapper);
    event WithdrawnAll(address[] tokens, address indexed receiver);

    constructor(address peggedToken_) {
        if (peggedToken_ == address(0)) revert AddressIsZero();
        PEGGED_TOKEN = IPeggedToken(peggedToken_);
        NAME = string.concat(IERC20Metadata(peggedToken_).symbol(), "-Treasury");

        _grantRole(DEFAULT_ADMIN_ROLE, owner());
        _grantRole(KEEPER_ROLE, msg.sender);
    }

    modifier onlyGateway() {
        if (msg.sender != PEGGED_TOKEN.gateway()) revert CallerIsNotAuthorized(msg.sender);
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert CallerIsNotAuthorized(msg.sender);
        _;
    }

    /*/////////////////////////////////////////////////////////////
                            onlyOwner
    /////////////////////////////////////////////////////////////*/
    /**
     * @notice onlyOwner: Add token as whitelisted token for PeggedToken
     * @param token_ token address to add in whitelist.
     * @param vault_ ERC4626 yield vault address correspond to _token
     * @param oracle_ Chainlink oracle address for token/USD feed
     * @param stalePeriod_ Custom stale period for oracle price
     */
    function addToWhitelist(address token_, address vault_, address oracle_, uint256 stalePeriod_) external onlyOwner {
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
     * @notice onlyOwner: Remove token from whitelist
     * @dev Removing token even if treasury has some balance of that token is intended behavior.
     * @param token_ token address to remove from whitelist.
     */
    function removeFromWhitelist(address token_) external onlyOwner {
        if (!_whitelistedTokens.remove(token_)) revert RemoveFromListFailed();
        IERC4626 _vault = IERC4626(tokenConfig[token_].vault);
        if (_vault.balanceOf(address(this)) > 0) revert BalanceShouldBeZero();
        IERC20(token_).forceApprove(tokenConfig[token_].vault, 0);
        delete tokenConfig[token_];
        emit RemovedFromWhitelist(token_);
    }

    /**
     * @notice onlyOwner: Migrate assets to new treasury
     * @param newTreasury_ Address of new treasury of PeggedToken
     */
    function migrate(address newTreasury_) external onlyOwner {
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
     * @notice onlyOwner: Sweep any ERC20 token to owner address
     * @dev OnlyOwner can call this and vault shares are not allowed to sweep
     * @param fromToken_ Token address to sweep
     * @param receiver_ recipient of tokens being swept
     */
    function sweep(address fromToken_, address receiver_) external onlyOwner {
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

    /// @notice onlyOwner: Update oracle and stale period
    function updateOracle(address token_, address oracle_, uint256 newStalePeriod_) external onlyOwner {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (oracle_ == address(0)) revert AddressIsZero();
        if (newStalePeriod_ == 0) revert InvalidStalePeriod();

        tokenConfig[token_].oracle = oracle_;
        tokenConfig[token_].stalePeriod = newStalePeriod_;

        emit UpdatedOracle(token_, oracle_, newStalePeriod_);
    }

    /// @notice onlyOwner: Update oracle price tolerance
    function updatePriceTolerance(uint256 newPriceTolerance_) external onlyOwner {
        if (newPriceTolerance_ > MAX_BPS) revert InvalidPriceTolerance();
        emit UpdatedPriceTolerance(priceTolerance, newPriceTolerance_);
        priceTolerance = newPriceTolerance_;
    }

    /**
     * @notice onlyOwner: Update swapper address
     * @param swapper_ new swapper address
     */
    function updateSwapper(address swapper_) external onlyOwner {
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

    function toggleDepositActive(address token_) external onlyRole(KEEPER_ROLE) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        bool _current = tokenConfig[token_].depositActive;
        emit ToggledDepositActive(!_current);
        tokenConfig[token_].depositActive = !_current;
    }

    function toggleWithdrawActive(address token_) external onlyRole(KEEPER_ROLE) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        bool _current = tokenConfig[token_].withdrawActive;
        emit ToggledWithdrawActive(!_current);
        tokenConfig[token_].withdrawActive = !_current;
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
     */
    function harvest(address token_) external onlyRole(UMM_ROLE) nonReentrant returns (uint256) {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);

        // Compute excess reserve in 18-decimal USD
        uint256 _supply = PEGGED_TOKEN.totalSupply();
        uint256 _reserve = reserve();
        if (_reserve <= _supply) return 0; // no excess
        uint256 _excessUSD = _reserve - _supply;

        // Get oracle price of token_
        (uint256 price, uint256 unitPrice) =
            _getPrice(IAggregatorV3(tokenConfig[token_].oracle), tokenConfig[token_].stalePeriod, priceTolerance);

        uint256 _excessInTokenDecimals = _excessUSD / (10 ** (18 - tokenConfig[token_].decimals));
        uint256 _excess = _excessInTokenDecimals.mulDiv(unitPrice, price);
        if (_excess == 0) return 0;

        uint256 _balance = IERC20(token_).balanceOf(address(this));
        // If we have enough balance to cover excess then send tokens and return
        if (_balance >= _excess) {
            IERC20(token_).safeTransfer(msg.sender, _excess);
            emit ExcessWithdrawn(token_, _excess);
            return _excess;
        }

        // Send what we have, then withdraw remainder from vault
        if (_balance > 0) {
            IERC20(token_).safeTransfer(msg.sender, _balance);
            _excess -= _balance;
        }

        IERC4626 _vault = IERC4626(tokenConfig[token_].vault);
        uint256 _assetsInVault = _vault.convertToAssets(_vault.balanceOf(address(this)));
        uint256 _toWithdraw = Math.min(_excess, _assetsInVault);
        if (_toWithdraw > 0) {
            _vault.withdraw(_toWithdraw, msg.sender, address(this));
        }
        uint256 _withdrawn = _toWithdraw + _balance;
        emit ExcessWithdrawn(token_, _withdrawn);
        return _withdrawn;
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

    /// @dev Owner is defined in PeggedToken token contract only
    function owner() public view returns (address) {
        return PEGGED_TOKEN.owner();
    }

    /// @notice Return total reserve value in USD
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
                // Calculate USD value in token decimals
                uint256 _valueInTokenDecimals = _balance.mulDiv(_price, _unitPrice);
                // Normalize value to 18 decimals before adding to total reserve
                _reserve += (_valueInTokenDecimals * (10 ** (18 - tokenConfig[_token].decimals)));
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

    function _getPrice(IAggregatorV3 oracle_, uint256 stalePeriod_, uint256 priceToleranceBps_)
        private
        view
        returns (uint256 _latestPrice, uint256 _unitPrice)
    {
        (, int256 _price,, uint256 _updatedAt,) = oracle_.latestRoundData();
        if (block.timestamp - _updatedAt >= stalePeriod_) revert StalePrice();
        _latestPrice = uint256(_price);

        // Unit oracle price for given token_. i.e. 1 USD if token_ is USDC/USDT
        _unitPrice = 10 ** oracle_.decimals();
        uint256 _priceToleranceValue = (_unitPrice * priceToleranceBps_) / MAX_BPS;
        uint256 _priceUpperBound = _unitPrice + _priceToleranceValue;
        uint256 _priceLowerBound = _unitPrice - _priceToleranceValue;

        if (_latestPrice > _priceUpperBound || _latestPrice < _priceLowerBound) {
            revert PriceExceedTolerance(_latestPrice, _priceUpperBound, _priceLowerBound);
        }
    }
}
