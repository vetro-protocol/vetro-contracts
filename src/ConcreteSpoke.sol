// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IPeggedToken} from "./interfaces/IPeggedToken.sol";
import {ISpoke} from "./interfaces/ISpoke.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/**
 * @title ConcreteSpoke - Concrete LPs' isolated reserve, holding ctDefiUSDT
 * @notice The entry point for whitelisted Concrete LPs: ctDefiUSDT in, VUSD or sVUSD out, and back. The shares stay
 * here and back only the VUSD minted through this spoke; the Gateway caps that supply and mints and burns it.
 *
 * PRICING
 * @dev 1:1 both ways: 1 VUSD is 1 USDT worth of ctDefiUSDT at Concrete's share price (`convertToAssets`), USDT counted
 * at par, for mints and redeems alike, and the reserve is valued the same way. No price feed is read.
 *
 * SANCTIONS
 * @dev The Gateway screens the payer and receiver this spoke reports for every mint and burn, as on its core paths.
 * On the staked legs the VUSD side is this spoke itself, and sVUSD screens the LP on its own transfer. This spoke
 * checks its whitelist.
 *
 * ROLES (AccessManager)
 * @dev Every `restricted` function is permissioned in the AccessManager:
 * - `setWhitelisted`: behind a delay, so neither an addition nor a removal lands without warning.
 * - `setShutdown`, `forceRedeem` and `forceUnstakeAndRedeem`: Concrete, no delay. Shutdown stops mints, redeems and
 *   force exits.
 * Redeems cannot be stopped through the AccessManager without a delay only if its configuration says so: a grant
 * delay on Concrete's role, a target admin delay on this spoke and an execution delay on the AccessManager admin.
 * Outside the AccessManager, an upgrade of this spoke (ProxyAdmin), the VUSD blacklist and the Treasury's sanctions
 * list can still stop a given exit.
 */
contract ConcreteSpoke is ISpoke, AccessManagedUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*/////////////////////////////////////////////////////////////
                            CONSTANTS
    /////////////////////////////////////////////////////////////*/

    string public constant VERSION = "1.0.0";
    uint8 private constant PEGGED_TOKEN_DECIMALS = 18;

    /*/////////////////////////////////////////////////////////////
                        ERC-7201 STORAGE
    /////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:vetro.storage.concreteSpoke
    struct ConcreteSpokeStorage {
        IPeggedToken peggedToken;
        IERC4626 asset;
        IERC4626 stakingVault;
        address underlying;
        uint8 assetDecimals;
        uint8 underlyingDecimals;
        bool shutdown;
        EnumerableSet.AddressSet whitelist;
    }

    bytes32 private constant CONCRETE_SPOKE_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("vetro.storage.concreteSpoke")) - 1)) & ~bytes32(uint256(0xff));

    /*/////////////////////////////////////////////////////////////
                            ERRORS
    /////////////////////////////////////////////////////////////*/

    error AddressIsZero();
    error AmountIsZero();
    error FeeOnTransferToken(address token);
    error InvalidStakingVault(address stakingVault);
    error InvalidTokenDecimals(address token, uint8 decimals);
    error MintableIsLessThanMinimum(uint256 peggedTokenOut, uint256 minPeggedTokenOut);
    error NotWhitelisted(address account);
    error RedeemableIsLessThanMinimum(uint256 amountOut, uint256 minAmountOut);
    error SpokeIsShutdown();
    error StakedIsLessThanMinimum(uint256 sharesOut, uint256 minSharesOut);

    /*/////////////////////////////////////////////////////////////
                            EVENTS
    /////////////////////////////////////////////////////////////*/

    event ForceRedeemed(address indexed caller, address indexed account, uint256 peggedTokenIn, uint256 amountOut);
    event ForceUnstakedAndRedeemed(
        address indexed caller, address indexed account, uint256 sharesIn, uint256 amountOut
    );
    event Minted(address indexed caller, address indexed receiver, uint256 amountIn, uint256 peggedTokenOut);
    event Redeemed(address indexed account, address indexed receiver, uint256 peggedTokenIn, uint256 amountOut);
    event ShutdownUpdated(bool shutdown);
    event WhitelistUpdated(address indexed account, bool status);

    /*/////////////////////////////////////////////////////////////
                            FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the spoke. The whitelist starts empty.
     * @param authority_ AccessManager permissioning the restricted functions
     * @param peggedToken_ VUSD
     * @param asset_ ctDefiUSDT, the ERC4626 share this spoke holds
     * @param stakingVault_ sVUSD, for the staked entry and exit
     */
    function initialize(address authority_, address peggedToken_, address asset_, address stakingVault_)
        external
        initializer
    {
        if (
            authority_ == address(0) || peggedToken_ == address(0) || asset_ == address(0)
                || stakingVault_ == address(0)
        ) revert AddressIsZero();
        __AccessManaged_init(authority_);
        if (IERC4626(stakingVault_).asset() != peggedToken_) revert InvalidStakingVault(stakingVault_);

        ConcreteSpokeStorage storage $ = _getStorage();
        $.peggedToken = IPeggedToken(peggedToken_);
        $.asset = IERC4626(asset_);
        $.stakingVault = IERC4626(stakingVault_);
        address _underlying = IERC4626(asset_).asset();
        $.underlying = _underlying;
        $.assetDecimals = _checkDecimals(asset_, false);
        $.underlyingDecimals = _checkDecimals(_underlying, false);
        _checkDecimals(peggedToken_, true);
    }

    /*/////////////////////////////////////////////////////////////
                        LP ENTRY AND EXIT
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit ctDefiUSDT and receive VUSD (whitelisted caller and receiver)
     * @param amountIn_ ctDefiUSDT to deposit
     * @param minPeggedTokenOut_ Minimum VUSD to receive
     * @param receiver_ Receiver of the VUSD
     * @return _peggedTokenOut VUSD minted
     */
    function mint(uint256 amountIn_, uint256 minPeggedTokenOut_, address receiver_)
        external
        nonReentrant
        returns (uint256 _peggedTokenOut)
    {
        _peggedTokenOut = _mint(_getStorage(), amountIn_, receiver_, receiver_);
        if (_peggedTokenOut < minPeggedTokenOut_) {
            revert MintableIsLessThanMinimum(_peggedTokenOut, minPeggedTokenOut_);
        }
    }

    /**
     * @notice Deposit ctDefiUSDT and receive sVUSD (whitelisted caller and receiver)
     * @param amountIn_ ctDefiUSDT to deposit
     * @param minSharesOut_ Minimum sVUSD to receive
     * @param receiver_ Receiver of the sVUSD
     * @return _sharesOut sVUSD minted
     */
    function mintAndStake(uint256 amountIn_, uint256 minSharesOut_, address receiver_)
        external
        nonReentrant
        returns (uint256 _sharesOut)
    {
        ConcreteSpokeStorage storage $ = _getStorage();
        uint256 _peggedTokenOut = _mint($, amountIn_, receiver_, address(this));
        IERC4626 _stakingVault = $.stakingVault;
        IERC20(address($.peggedToken)).forceApprove(address(_stakingVault), _peggedTokenOut);
        _sharesOut = _stakingVault.deposit(_peggedTokenOut, receiver_);
        if (_sharesOut < minSharesOut_) revert StakedIsLessThanMinimum(_sharesOut, minSharesOut_);
    }

    /**
     * @notice Return VUSD and receive ctDefiUSDT (whitelisted caller)
     * @param peggedTokenIn_ VUSD to burn from the caller
     * @param minAmountOut_ Minimum ctDefiUSDT to receive
     * @param receiver_ Receiver of the ctDefiUSDT
     * @return _amountOut ctDefiUSDT paid
     */
    function redeem(uint256 peggedTokenIn_, uint256 minAmountOut_, address receiver_)
        external
        nonReentrant
        returns (uint256 _amountOut)
    {
        ConcreteSpokeStorage storage $ = _getStorage();
        _checkWhitelisted($, msg.sender);
        _amountOut = _redeem($, msg.sender, peggedTokenIn_, minAmountOut_, receiver_);
    }

    /**
     * @notice Return sVUSD and receive ctDefiUSDT (whitelisted caller); unstakes instantly
     * @dev Pulls the sVUSD first, so it needs an allowance
     * @param sharesIn_ sVUSD to unstake
     * @param minAmountOut_ Minimum ctDefiUSDT to receive
     * @param receiver_ Receiver of the ctDefiUSDT
     * @return _amountOut ctDefiUSDT paid
     */
    function unstakeAndRedeem(uint256 sharesIn_, uint256 minAmountOut_, address receiver_)
        external
        nonReentrant
        returns (uint256 _amountOut)
    {
        ConcreteSpokeStorage storage $ = _getStorage();
        _checkWhitelisted($, msg.sender);
        _amountOut = _redeem($, address(this), _unstake($, msg.sender, sharesIn_), minAmountOut_, receiver_);
    }

    /*/////////////////////////////////////////////////////////////
                            RESTRICTED
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricted (Concrete): redeem a whitelisted LP's VUSD, paid to the LP's own wallet
     * @dev Burns without an allowance; stopped by shutdown like any redeem
     * @param account_ LP to exit
     * @param peggedTokenIn_ VUSD to burn from the LP
     * @param minAmountOut_ Minimum ctDefiUSDT to pay
     * @return _amountOut ctDefiUSDT paid to the LP
     */
    function forceRedeem(address account_, uint256 peggedTokenIn_, uint256 minAmountOut_)
        external
        restricted
        nonReentrant
        returns (uint256 _amountOut)
    {
        ConcreteSpokeStorage storage $ = _getStorage();
        _checkWhitelisted($, account_);
        _amountOut = _redeem($, account_, peggedTokenIn_, minAmountOut_, account_);
        emit ForceRedeemed(msg.sender, account_, peggedTokenIn_, _amountOut);
    }

    /**
     * @notice Restricted (Concrete): unstake a whitelisted LP's sVUSD and redeem it, paid to the LP's own wallet
     * @dev Needs the LP's sVUSD allowance to this spoke (kept under the LP agreement); stopped by shutdown like any
     * redeem
     * @param account_ LP to exit
     * @param sharesIn_ sVUSD to unstake from the LP
     * @param minAmountOut_ Minimum ctDefiUSDT to pay
     * @return _amountOut ctDefiUSDT paid to the LP
     */
    function forceUnstakeAndRedeem(address account_, uint256 sharesIn_, uint256 minAmountOut_)
        external
        restricted
        nonReentrant
        returns (uint256 _amountOut)
    {
        ConcreteSpokeStorage storage $ = _getStorage();
        _checkWhitelisted($, account_);
        _amountOut = _redeem($, address(this), _unstake($, account_, sharesIn_), minAmountOut_, account_);
        emit ForceUnstakedAndRedeemed(msg.sender, account_, sharesIn_, _amountOut);
    }

    /// @notice Restricted (Concrete): shut the spoke down, or reopen it. Shutdown stops mints, redeems and force
    /// exits.
    function setShutdown(bool shutdown_) external restricted {
        _getStorage().shutdown = shutdown_;
        emit ShutdownUpdated(shutdown_);
    }

    /// @notice Restricted (delayed): add or remove a wallet allowed to mint and redeem
    function setWhitelisted(address account_, bool status_) external restricted {
        if (account_ == address(0)) revert AddressIsZero();
        ConcreteSpokeStorage storage $ = _getStorage();
        if (status_) $.whitelist.add(account_);
        else $.whitelist.remove(account_);
        emit WhitelistUpdated(account_, status_);
    }

    /*/////////////////////////////////////////////////////////////
                            VIEWS
    /////////////////////////////////////////////////////////////*/

    /// @notice ctDefiUSDT, the share this spoke holds
    function asset() external view returns (address) {
        return address(_getStorage().asset);
    }

    /// @notice Wallets allowed to mint and redeem
    function getWhitelist() external view returns (address[] memory) {
        return _getStorage().whitelist.values();
    }

    /// @notice Whether a wallet may mint and redeem
    function isWhitelisted(address account_) external view returns (bool) {
        return _getStorage().whitelist.contains(account_);
    }

    /**
     * @notice VUSD the spoke can still mint: the room under its Gateway mint limit, or 0 while the spoke is shut down,
     * the share price is unreadable or the spoke is undercollateralized
     */
    function maxMint() external view returns (uint256) {
        ConcreteSpokeStorage storage $ = _getStorage();
        if ($.shutdown) return 0;
        IGateway _gateway = IGateway($.peggedToken.gateway());
        uint256 _limit = _gateway.spokeMintLimit(address(this));
        uint256 _supply = _gateway.spokeSupply(address(this));
        if (_limit <= _supply) return 0;
        // A mint adds at least as much reserve as supply, so the Gateway refuses it while the reserve is below supply
        try this.sharePrice() returns (uint256 _price) {
            if (_price == 0 || _reserveAt($, _price) < _supply) return 0;
        } catch {
            return 0;
        }
        return _limit - _supply;
    }

    /**
     * @notice VUSD `owner_` can redeem now: their balance, capped by the spoke's supply and by what its shares are
     * worth, or 0 while the spoke is shut down, the owner is not whitelisted or is sanctioned, the share price is
     * unreadable, or the amount is worth less than one share unit (dust reverts)
     */
    function maxRedeem(address owner_) external view returns (uint256) {
        ConcreteSpokeStorage storage $ = _getStorage();
        if ($.shutdown || !$.whitelist.contains(owner_)) return 0;
        if (ITreasury($.peggedToken.treasury()).isSanctioned(owner_)) return 0;
        uint256 _max = Math.min(
            IERC20(address($.peggedToken)).balanceOf(owner_),
            IGateway($.peggedToken.gateway()).spokeSupply(address(this))
        );
        try this.sharePrice() returns (uint256 _price) {
            _max = Math.min(_max, _reserveAt($, _price));
            return _toShares($, _max, _price) == 0 ? 0 : _max;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc ISpoke
    function peggedToken() external view returns (IPeggedToken) {
        return _getStorage().peggedToken;
    }

    /// @notice sVUSD received for `amountIn_` ctDefiUSDT; ignores limits, the shutdown and the whitelist
    function previewMintAndStake(uint256 amountIn_) external view returns (uint256) {
        return _getStorage().stakingVault.previewDeposit(previewMint(amountIn_));
    }

    /// @notice ctDefiUSDT paid for `sharesIn_` sVUSD; ignores the shutdown, the whitelist, the spoke's supply cap and
    /// the staking vault's cooldown
    function previewUnstakeAndRedeem(uint256 sharesIn_) external view returns (uint256) {
        return previewRedeem(_getStorage().stakingVault.previewRedeem(sharesIn_));
    }

    /// @inheritdoc ISpoke
    /// @dev Shares held at the share price. What this is above the spoke's supply is its yield.
    function reserve() external view returns (uint256) {
        return _reserveAt(_getStorage(), sharePrice());
    }

    /// @notice Whether the spoke is shut down (Concrete)
    function shutdown() external view returns (bool) {
        return _getStorage().shutdown;
    }

    /// @notice sVUSD, used by the staked entry and exit
    function stakingVault() external view returns (address) {
        return address(_getStorage().stakingVault);
    }

    /// @notice VUSD minted for `amountIn_` ctDefiUSDT at the current share price; ignores limits, the shutdown and
    /// the whitelist
    function previewMint(uint256 amountIn_) public view returns (uint256) {
        return _toPeggedToken(_getStorage(), amountIn_, sharePrice());
    }

    /// @notice ctDefiUSDT paid for `peggedTokenIn_` VUSD at the current share price; ignores the shutdown, the
    /// whitelist and the spoke's supply cap
    function previewRedeem(uint256 peggedTokenIn_) public view returns (uint256) {
        return _toShares(_getStorage(), peggedTokenIn_, sharePrice());
    }

    /// @notice VUSD per whole share (18 decimals), USDT counted at par. Reverts while Concrete's accounting is paused
    /// or stale.
    function sharePrice() public view returns (uint256) {
        ConcreteSpokeStorage storage $ = _getStorage();
        uint256 _assets = $.asset.convertToAssets(10 ** $.assetDecimals);
        return _assets * 10 ** (PEGGED_TOKEN_DECIMALS - $.underlyingDecimals);
    }

    /*/////////////////////////////////////////////////////////////
                            PRIVATE
    /////////////////////////////////////////////////////////////*/

    /// @dev The share price math is in 18 decimals: the pegged token must have exactly 18, the others at most 18
    function _checkDecimals(address token_, bool exact_) private view returns (uint8 _decimals) {
        _decimals = IERC20Metadata(token_).decimals();
        if (exact_ ? _decimals != PEGGED_TOKEN_DECIMALS : _decimals > PEGGED_TOKEN_DECIMALS) {
            revert InvalidTokenDecimals(token_, _decimals);
        }
    }

    function _checkWhitelisted(ConcreteSpokeStorage storage $, address account_) private view {
        if (!$.whitelist.contains(account_)) revert NotWhitelisted(account_);
    }

    /// @dev Takes `amountIn_` shares from the caller and mints their VUSD worth to `mintTo_`. Both the caller and the
    /// final receiver must be whitelisted.
    function _mint(ConcreteSpokeStorage storage $, uint256 amountIn_, address receiver_, address mintTo_)
        private
        returns (uint256 _peggedTokenOut)
    {
        if (amountIn_ == 0) revert AmountIsZero();
        if ($.shutdown) revert SpokeIsShutdown();
        _checkWhitelisted($, msg.sender);
        _checkWhitelisted($, receiver_);

        _peggedTokenOut = previewMint(amountIn_);
        IERC20 _asset = IERC20(address($.asset));
        uint256 _balanceBefore = _asset.balanceOf(address(this));
        _asset.safeTransferFrom(msg.sender, address(this), amountIn_);
        if (_asset.balanceOf(address(this)) - _balanceBefore != amountIn_) revert FeeOnTransferToken(address(_asset));
        IGateway($.peggedToken.gateway()).mintFromSpoke(msg.sender, mintTo_, _peggedTokenOut);
        emit Minted(msg.sender, receiver_, amountIn_, _peggedTokenOut);
    }

    /// @dev Burns `peggedTokenIn_` from `from_` and pays its ctDefiUSDT worth to `receiver_`. `minAmountOut_` is
    /// checked on the amount sent; a ctDefiUSDT transfer hook that skims it is outside this check.
    function _redeem(
        ConcreteSpokeStorage storage $,
        address from_,
        uint256 peggedTokenIn_,
        uint256 minAmountOut_,
        address receiver_
    ) private returns (uint256 _amountOut) {
        if (peggedTokenIn_ == 0) revert AmountIsZero();
        if ($.shutdown) revert SpokeIsShutdown();
        _amountOut = previewRedeem(peggedTokenIn_);
        // Dust below one share unit would burn VUSD and pay nothing
        if (_amountOut == 0) revert AmountIsZero();
        if (_amountOut < minAmountOut_) revert RedeemableIsLessThanMinimum(_amountOut, minAmountOut_);
        // Pay before burning, so a ctDefiUSDT transfer hook sees the reserve understated, never overstated
        IERC20(address($.asset)).safeTransfer(receiver_, _amountOut);
        IGateway($.peggedToken.gateway()).burnFromSpoke(from_, receiver_, peggedTokenIn_);
        emit Redeemed(from_, receiver_, peggedTokenIn_, _amountOut);
    }

    function _reserveAt(ConcreteSpokeStorage storage $, uint256 sharePrice_) private view returns (uint256) {
        return _toPeggedToken($, IERC20(address($.asset)).balanceOf(address(this)), sharePrice_);
    }

    function _toPeggedToken(ConcreteSpokeStorage storage $, uint256 shares_, uint256 sharePrice_)
        private
        view
        returns (uint256)
    {
        return shares_.mulDiv(sharePrice_, 10 ** $.assetDecimals);
    }

    function _toShares(ConcreteSpokeStorage storage $, uint256 peggedToken_, uint256 sharePrice_)
        private
        view
        returns (uint256)
    {
        return peggedToken_.mulDiv(10 ** $.assetDecimals, sharePrice_);
    }

    /// @dev Pulls `sharesIn_` sVUSD from `from_` (allowance) and redeems them as their owner, so only this spoke needs
    /// the staking vault's instant withdraw whitelist
    function _unstake(ConcreteSpokeStorage storage $, address from_, uint256 sharesIn_) private returns (uint256) {
        if (sharesIn_ == 0) revert AmountIsZero();
        IERC4626 _stakingVault = $.stakingVault;
        IERC20(address(_stakingVault)).safeTransferFrom(from_, address(this), sharesIn_);
        return _stakingVault.redeem(sharesIn_, address(this), address(this));
    }

    function _getStorage() private pure returns (ConcreteSpokeStorage storage $) {
        bytes32 _location = CONCRETE_SPOKE_STORAGE_LOCATION;
        assembly {
            $.slot := _location
        }
    }
}
