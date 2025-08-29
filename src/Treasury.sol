// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMorphoVaultV2} from "./interfaces/morpho/IMorphoVaultV2.sol";
import {IAggregatorV3} from "./interfaces/chainlink/IAggregatorV3.sol";
import {ISwapper} from "./interfaces/bloq/ISwapper.sol";
import {IVUSD} from "./interfaces/IVUSD.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @title VUSD Treasury
contract Treasury is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsZero();
    error AddToListFailed();
    error AssetMismatch();
    error BalanceShouldBeZero();
    error CallerIsNotAuthorized(address caller);
    error DepositIsPaused(address);
    error InvalidPriceTolerance();
    error InvalidStalePeriod();
    error PriceExceedTolerance(uint256 latestPrice, uint256 priceUpperBound, uint256 priceLowerBound);
    error RemoveFromListFailed();
    error ReservedToken();
    error StalePrice();
    error UnsupportedToken(address);
    error VUSDMismatch();
    error WithdrawIsPaused(address);

    string public constant NAME = "VUSD-Treasury";
    string public constant VERSION = "2.0.0";

    uint256 public constant MAX_BPS = 10_000; // 10_000 = 100%
    uint256 public priceTolerance = 100; // 1% based on BPS

    IVUSD public immutable vusd;

    address public swapper;

    struct TokenConfig {
        address vault;
        address oracle;
        uint256 stalePeriod;
        bool depositActive;
        bool withdrawActive;
    }

    mapping(address token => TokenConfig) public tokenConfig;

    EnumerableSet.AddressSet private _whitelistedTokens;
    EnumerableSet.AddressSet private _keepers;

    event AddedKeeper(address indexed keeper);
    event RemovedKeeper(address indexed keeper);
    event AddedToWhitelist(address indexed token, address vault, address oracle);
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

    constructor(address vusd_) {
        if (vusd_ == address(0)) revert AddressIsZero();
        vusd = IVUSD(vusd_);

        _keepers.add(msg.sender);
    }

    modifier onlyKeeper() {
        if (!_keepers.contains(msg.sender)) revert CallerIsNotAuthorized(msg.sender);
        _;
    }

    modifier onlyGateway() {
        if (msg.sender != vusd.gateway()) revert CallerIsNotAuthorized(msg.sender);
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
     * @notice onlyOwner: Add token as whitelisted token for VUSD
     * @param token_ token address to add in whitelist.
     * @param vault_ Morpho vaultV2 address correspond to _token
     * @param oracle_ Chainlink oracle address for token/USD feed
     * @param stalePeriod_ Custom stale period for oracle price
     */
    function addToWhitelist(address token_, address vault_, address oracle_, uint256 stalePeriod_) external onlyOwner {
        if (token_ == address(0) || vault_ == address(0) || oracle_ == address(0)) revert AddressIsZero();
        if (stalePeriod_ == 0) revert InvalidStalePeriod();
        if (token_ != IMorphoVaultV2(vault_).asset()) revert AssetMismatch();

        if (!_whitelistedTokens.add(token_)) revert AddToListFailed();
        tokenConfig[token_] = TokenConfig({
            vault: vault_,
            oracle: oracle_,
            stalePeriod: stalePeriod_,
            depositActive: true,
            withdrawActive: true
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
        IMorphoVaultV2 _vault = IMorphoVaultV2(tokenConfig[token_].vault);
        if (_vault.balanceOf(address(this)) > 0) revert BalanceShouldBeZero();
        IERC20(token_).forceApprove(tokenConfig[token_].vault, 0);
        delete tokenConfig[token_];
        emit RemovedFromWhitelist(token_);
    }

    /**
     * @notice onlyOwner: Add given address in keepers list.
     * @param keeperAddress_ keeper address to add.
     */
    function addKeeper(address keeperAddress_) external onlyOwner {
        if (keeperAddress_ == address(0)) revert AddressIsZero();
        if (!_keepers.add(keeperAddress_)) revert AddToListFailed();
        emit AddedKeeper(keeperAddress_);
    }

    /**
     * @notice onlyOwner: Remove given address from keepers list.
     * @param keeperAddress_ keeper address to remove.
     */
    function removeKeeper(address keeperAddress_) external onlyOwner {
        if (!_keepers.remove(keeperAddress_)) revert RemoveFromListFailed();
        emit RemovedKeeper(keeperAddress_);
    }

    /**
     * @notice onlyOwner: Migrate assets to new treasury
     * @param newTreasury_ Address of new treasury of VUSD
     */
    function migrate(address newTreasury_) external onlyOwner {
        if (newTreasury_ == address(0)) revert AddressIsZero();
        if (address(vusd) != address(ITreasury(newTreasury_).vusd())) revert VUSDMismatch();
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

    /**
     * @notice onlyOwner: Withdraw token from vault and sent tokens to receiver address.
     * @param tokens_ Array of token addresses, tokens should be supported tokens.
     * @param receiver_ recipient of tokens being withdrawn
     */
    function withdrawAll(address[] memory tokens_, address receiver_) external nonReentrant onlyOwner {
        if (receiver_ == address(0)) revert AddressIsZero();
        uint256 _len = tokens_.length;
        for (uint256 i; i < _len; ++i) {
            address _token = tokens_[i];
            if (!_whitelistedTokens.contains(_token)) revert UnsupportedToken(_token);
            IMorphoVaultV2 _vault = IMorphoVaultV2(tokenConfig[_token].vault);
            _vault.redeem(_vault.balanceOf(address(this)), receiver_, address(this));
        }
        emit WithdrawnAll(tokens_, receiver_);
    }

    /*/////////////////////////////////////////////////////////////
                            onlyGateway
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice onlyGateway: Deposit token to Morpho vault
     * @dev `depositActive` must be true to call deposit.
     * @param token_ token to deposit, must be one of the whitelisted tokens.
     * @param amount_  token amount
     */
    function deposit(address token_, uint256 amount_) external nonReentrant onlyGateway {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (!tokenConfig[token_].depositActive) revert DepositIsPaused(token_);

        IMorphoVaultV2(tokenConfig[token_].vault).deposit(amount_, address(this));
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
            IMorphoVaultV2(config.vault).withdraw(amount_, tokenReceiver_, address(this));
        }
    }
    /*/////////////////////////////////////////////////////////////
                            onlyKeeper
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice onlyKeeper: Deposit token into the vault
     * @dev Keeper is allowed to deposit even if depositActive is false.
     * @param token_ token to deposit into the vault
     * @param amount_ token amount to deposit
     */
    function push(address token_, uint256 amount_) external onlyKeeper {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (amount_ == type(uint256).max) {
            amount_ = IERC20(token_).balanceOf(address(this));
        }
        if (amount_ > 0) {
            IMorphoVaultV2(tokenConfig[token_].vault).deposit(amount_, address(this));
        }
    }

    /**
     * @notice onlyKeeper: Withdraw token from vault.
     * @dev Keeper is allowed to withdraw even if withdrawActive is false.
     * @dev Keeper can withdraw tokens at treasury address only.
     * @param token_ token to withdraw from vault
     * @param amount_ token amount to withdraw
     */
    function pull(address token_, uint256 amount_) external onlyKeeper {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        if (amount_ > 0) {
            IMorphoVaultV2(tokenConfig[token_].vault).withdraw(amount_, address(this), address(this));
        }
    }

    function toggleDepositActive(address token_) external onlyKeeper {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        bool _current = tokenConfig[token_].depositActive;
        emit ToggledDepositActive(!_current);
        tokenConfig[token_].depositActive = !_current;
    }

    function toggleWithdrawActive(address token_) external onlyKeeper {
        if (!_whitelistedTokens.contains(token_)) revert UnsupportedToken(token_);
        bool _current = tokenConfig[token_].withdrawActive;
        emit ToggledWithdrawActive(!_current);
        tokenConfig[token_].withdrawActive = !_current;
    }

    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minAmountOut_) external onlyKeeper {
        if (_whitelistedTokens.contains(tokenIn_)) revert ReservedToken();
        uint256 _len = _whitelistedTokens.length();
        for (uint256 i; i < _len; ++i) {
            if (tokenConfig[_whitelistedTokens.at(i)].vault == tokenIn_) revert ReservedToken();
        }
        IERC20(tokenIn_).forceApprove(swapper, amountIn_);
        ISwapper(swapper).swapExactInput(tokenIn_, tokenOut_, amountIn_, minAmountOut_, address(this));
        emit Swapped(tokenIn_, tokenOut_, amountIn_);
    }

    /*/////////////////////////////////////////////////////////////
                            getter
    /////////////////////////////////////////////////////////////*/
    function gateway() external view returns (address) {
        return vusd.gateway();
    }

    function getPrice(address token_) external view returns (uint256 _latestPrice, uint256 _unitPrice) {
        IAggregatorV3 _oracle = IAggregatorV3(tokenConfig[token_].oracle);
        uint8 _oracleDecimal = IAggregatorV3(_oracle).decimals();
        (, int256 _price,, uint256 _updatedAt,) = IAggregatorV3(_oracle).latestRoundData();
        if (block.timestamp - _updatedAt >= tokenConfig[token_].stalePeriod) revert StalePrice();
        _latestPrice = uint256(_price);

        /// Unit oracle price for given token_. i.e. 1 USD if token_ is USDC/USDT
        _unitPrice = 10 ** _oracleDecimal;
        uint256 _priceTolerance = (_unitPrice * priceTolerance) / MAX_BPS;
        uint256 _priceUpperBound = _unitPrice + _priceTolerance;
        uint256 _priceLowerBound = _unitPrice - _priceTolerance;

        if (_latestPrice > _priceUpperBound || _latestPrice < _priceLowerBound) {
            revert PriceExceedTolerance(_latestPrice, _priceUpperBound, _priceLowerBound);
        }
    }

    /// @notice Returns whether given account is keeper
    function isKeeper(address account_) external view returns (bool) {
        return _keepers.contains(account_);
    }

    /// @notice Returns whether given token is whitelisted
    function isWhitelistedToken(address token_) external view returns (bool) {
        return _whitelistedTokens.contains(token_);
    }

    /// @notice Return list of keepers
    function keepers() external view returns (address[] memory) {
        return _keepers.values();
    }

    /// @dev Owner is defined in VUSD token contract only
    function owner() public view returns (address) {
        return vusd.owner();
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
        IMorphoVaultV2 _vault = IMorphoVaultV2(tokenConfig[token_].vault);
        uint256 _tokenInVault;
        if (address(_vault) != address(0)) {
            _tokenInVault = _vault.convertToAssets(_vault.balanceOf(address(this)));
        }
        return IERC20(token_).balanceOf(address(this)) + _tokenInVault;
    }
}
