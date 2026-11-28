// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ConcreteSpoke} from "./ConcreteSpoke.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/**
 * @title ConcreteLPVault (CsVUSD) - whitelisted Concrete LPs' pooled position, 1 ctDefiUSDT per share
 * @notice ERC-4626 over ctDefiUSDT. A deposit stakes the ctDefiUSDT through the Concrete spoke (`mintAndStake`) and
 * the vault holds the sVUSD it receives. A redeem unstakes just enough sVUSD through the spoke (`unstakeAndRedeem`)
 * and pays ctDefiUSDT straight to the receiver.
 *
 * SHARE VALUE
 * @dev One share is one ctDefiUSDT: a deposit mints one share per ctDefiUSDT the sVUSD received redeems back to, and
 * a share redeems to one ctDefiUSDT. The sVUSD the vault holds drifts from what that needs each week (sVUSD's rate
 * against ctDefiUSDT's). Vetro squares it up:
 * - short (ctDefiUSDT earned more): Vetro stakes the missing sVUSD to the vault (`shortfallSVusd`)
 * - extra (sVUSD earned more): `harvestExtraAssets` unstakes the sVUSD above what the shares need and sends the VUSD
 *   to Vetro's treasury (`vetroTreasury`). The VUSD is not burned: it is core yield the shared drip paid the vault, and
 *   the treasury drips it again with the next week's core and spoke harvest. Concrete LPs get ctDefiUSDT's yield, core
 *   stakers keep theirs.
 * Weekly, with the drip sized so core stakers earn the core rate (core weekly yield x total sVUSD / core sVUSD), the
 * gap is about (ctDefiUSDT APR - core APR) x vault TVL / 52: a top-up when positive, an extra sent to the treasury when
 * negative. The treasury funds the first drip once (a float of about core weekly yield x vault sVUSD / core sVUSD);
 * from then on the extra it receives each week funds the next drip, and the float returns when the vault leaves sVUSD.
 * Until a shortfall is topped up, redemptions are pro rata: every share gets the same part of what the vault's sVUSD
 * redeems to, never more than one ctDefiUSDT. Deposits stay at one share per ctDefiUSDT, so a newcomer neither buys
 * into a pending top-up nor dilutes it. While the spoke is worth less than its supply (a ctDefiUSDT loss) deposits
 * are refused. So 1% of CsVUSD is 1% of the ctDefiUSDT owed, not always 1% of the sVUSD held.
 *
 * Donated sVUSD can't move the share price: it only adds to the extra. The vault never holds ctDefiUSDT between
 * calls; any sent to it directly is not counted.
 *
 * WHITELIST
 * @dev Only whitelisted wallets deposit, receive or hold shares, and shares move only between whitelisted wallets.
 * Exits need no whitelist: a wallet removed from the whitelist can still redeem what it holds.
 * `mint` is not supported (its max is 0): use `deposit`.
 *
 * SANCTIONS
 * @dev The spoke sees this vault as payer, so the vault screens the LP (caller, receiver, owner) against the
 * Treasury's list itself. The spoke screens the redeem receiver too.
 *
 * SETUP
 * @dev The vault must be on the spoke's whitelist; the spoke and this vault on sVUSD's instant withdraw whitelist
 * (the vault unstakes the extra itself).
 *
 * ROLES (AccessManager)
 * @dev `setWhitelisted` and `setVetroTreasury` (delayed) and `harvestExtraAssets` (Vetro or its keeper) are
 * `restricted`.
 */
contract ConcreteLPVault is ERC4626Upgradeable, AccessManagedUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*/////////////////////////////////////////////////////////////
                            CONSTANTS
    /////////////////////////////////////////////////////////////*/

    string public constant VERSION = "1.0.0";
    /// @dev sVUSD left above what the shares need when harvesting the extra, for per-redeem rounding up
    uint256 private constant EXTRA_MARGIN = 1e12;

    /*/////////////////////////////////////////////////////////////
                        ERC-7201 STORAGE
    /////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:vetro.storage.concreteLPVault
    struct ConcreteLPVaultStorage {
        ConcreteSpoke spoke;
        IERC4626 sVusd;
        uint256 ctUnit;
        EnumerableSet.AddressSet whitelist;
        address vetroTreasury;
    }

    bytes32 private constant CONCRETE_LP_VAULT_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("vetro.storage.concreteLPVault")) - 1)) & ~bytes32(uint256(0xff));

    /*/////////////////////////////////////////////////////////////
                            ERRORS
    /////////////////////////////////////////////////////////////*/

    error AddressIsZero();
    error AmountIsZero();
    error NotSupported();
    error NotWhitelisted(address account);
    error SpokeUndercollateralized(uint256 reserve, uint256 supply);

    /*/////////////////////////////////////////////////////////////
                            EVENTS
    /////////////////////////////////////////////////////////////*/

    event ExtraAssetsHarvested(address indexed vetroTreasury, uint256 sVusdIn, uint256 peggedTokenOut);
    event VetroTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event WhitelistUpdated(address indexed account, bool status);

    /*/////////////////////////////////////////////////////////////
                            FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param authority_ AccessManager permissioning the restricted functions
     * @param spoke_ ConcreteSpoke; its asset (ctDefiUSDT) is this vault's asset
     * @param name_ Share name
     * @param symbol_ Share symbol
     */
    function initialize(address authority_, address spoke_, string memory name_, string memory symbol_)
        external
        initializer
    {
        if (authority_ == address(0) || spoke_ == address(0)) revert AddressIsZero();
        ConcreteSpoke _spoke = ConcreteSpoke(spoke_);
        address _ct = _spoke.asset();
        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(_ct));
        __AccessManaged_init(authority_);

        ConcreteLPVaultStorage storage $ = _getStorage();
        $.spoke = _spoke;
        $.sVusd = IERC4626(_spoke.stakingVault());
        $.ctUnit = 10 ** decimals();
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL STATE-CHANGING FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricted (Vetro): unstake the sVUSD above what the shares need and send the VUSD to `vetroTreasury`, to
     * be dripped to sVUSD stakers again. The VUSD is not burned.
     * @dev Refused while the spoke is worth less than its supply: a share price dip makes the shares look cheaper in
     * sVUSD, and the "extra" is needed again once the price recovers. The receiver is fixed, so the role can be given
     * to a keeper.
     * @return _extra sVUSD unstaked
     * @return _vusdOut VUSD sent to `vetroTreasury`
     */
    function harvestExtraAssets() external restricted nonReentrant returns (uint256 _extra, uint256 _vusdOut) {
        ConcreteLPVaultStorage storage $ = _getStorage();
        address _vetroTreasury = $.vetroTreasury;
        if (_vetroTreasury == address(0)) revert AddressIsZero();
        _checkSpokeHealthy($);
        _extra = extraSVusd();
        if (_extra != 0) {
            _vusdOut = $.sVusd.redeem(_extra, _vetroTreasury, address(this));
            emit ExtraAssetsHarvested(_vetroTreasury, _extra, _vusdOut);
        }
    }

    /// @notice Restricted (delayed): set Vetro's treasury, which receives the extra as VUSD
    function setVetroTreasury(address vetroTreasury_) external restricted {
        if (vetroTreasury_ == address(0)) revert AddressIsZero();
        ConcreteLPVaultStorage storage $ = _getStorage();
        emit VetroTreasuryUpdated($.vetroTreasury, vetroTreasury_);
        $.vetroTreasury = vetroTreasury_;
    }

    /// @notice Restricted (delayed): add or remove a wallet allowed to deposit and hold shares
    function setWhitelisted(address account_, bool status_) external restricted {
        if (account_ == address(0)) revert AddressIsZero();
        ConcreteLPVaultStorage storage $ = _getStorage();
        if (status_) $.whitelist.add(account_);
        else $.whitelist.remove(account_);
        emit WhitelistUpdated(account_, status_);
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @notice Wallets allowed to deposit and hold shares
    function getWhitelist() external view returns (address[] memory) {
        return _getStorage().whitelist.values();
    }

    /// @notice Whether a wallet may deposit and hold shares
    function isWhitelisted(address account_) external view returns (bool) {
        return _getStorage().whitelist.contains(account_);
    }

    /// @notice sVUSD the vault is short of what the shares need. 0 when covered. What Vetro's top-up should stake here.
    function shortfallSVusd() external view returns (uint256) {
        uint256 _balance = _sVusdBalance();
        uint256 _needed = _sVusdNeeded();
        return _needed > _balance ? _needed - _balance : 0;
    }

    /// @notice The spoke this vault stakes and unstakes through
    function spoke() external view returns (address) {
        return address(_getStorage().spoke);
    }

    /// @notice sVUSD, which the vault holds
    function stakingVault() external view returns (address) {
        return address(_getStorage().sVusd);
    }

    /// @notice Vetro's treasury, which receives the extra as VUSD
    function vetroTreasury() external view returns (address) {
        return _getStorage().vetroTreasury;
    }

    /*/////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @notice ctDefiUSDT the vault's sVUSD redeems to through the spoke now
    function coverableCt() public view returns (uint256) {
        return _ctValue(_sVusdBalance());
    }

    /// @notice sVUSD above what the shares need, less a rounding margin. 0 when short.
    function extraSVusd() public view returns (uint256) {
        uint256 _balance = _sVusdBalance();
        uint256 _needed = _sVusdNeeded() + EXTRA_MARGIN;
        return _balance > _needed ? _balance - _needed : 0;
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev 0 for a non-whitelisted receiver, while the spoke is in a loss, or past the spoke's mint room
    function maxDeposit(address receiver_) public view override returns (uint256) {
        ConcreteLPVaultStorage storage $ = _getStorage();
        if (!$.whitelist.contains(receiver_) || !_spokeHealthy($)) return 0;
        ConcreteSpoke _spoke = $.spoke;
        uint256 _room = _spoke.maxMint();
        if (_room == 0) return 0;
        try _spoke.sharePrice() returns (uint256 _price) {
            return _price == 0 ? 0 : _room.mulDiv($.ctUnit, _price);
        } catch {
            return 0;
        }
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Not supported
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev The spoke cap only applies when it is below what all shares are worth; converting it otherwise would
    /// round the last holder's final share out
    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 _max = super.maxRedeem(owner_);
        uint256 _payable = _payableCt();
        if (_payable >= totalAssets()) return _max;
        return Math.min(_max, _convertToShares(_payable, Math.Rounding.Floor));
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Also capped by what the spoke can pay now (its supply, shutdown)
    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), _payableCt());
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev One share per ctDefiUSDT the staked sVUSD redeems back to: never more than deposited
    function previewDeposit(uint256 assets_) public view override returns (uint256) {
        ConcreteLPVaultStorage storage $ = _getStorage();
        return _ctValue($.spoke.previewMintAndStake(assets_));
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Not supported
    function previewMint(uint256) public pure override returns (uint256) {
        revert NotSupported();
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev ctDefiUSDT the shares are worth together: one per share, or what the sVUSD covers while short
    function totalAssets() public view override returns (uint256) {
        return Math.min(totalSupply(), coverableCt());
    }

    /*/////////////////////////////////////////////////////////////
                    INTERNAL STATE-CHANGING FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @dev LP's ctDefiUSDT in, staked through the spoke into sVUSD held here, shares out. `shares_` (from
    /// previewDeposit) is re-derived from the sVUSD actually received.
    function _deposit(address caller_, address receiver_, uint256 assets_, uint256) internal override nonReentrant {
        if (assets_ == 0) revert AmountIsZero();
        ConcreteLPVaultStorage storage $ = _getStorage();
        if (!$.whitelist.contains(caller_)) revert NotWhitelisted(caller_);
        _checkNotSanctioned($, caller_);
        if (receiver_ != caller_) _checkNotSanctioned($, receiver_);
        _checkSpokeHealthy($);

        IERC20(asset()).safeTransferFrom(caller_, address(this), assets_);
        ConcreteSpoke _spoke = $.spoke;
        IERC20(asset()).forceApprove(address(_spoke), assets_);
        uint256 _sVusdIn = _spoke.mintAndStake(assets_, 0, address(this));
        uint256 _shares = _ctValue(_sVusdIn);
        if (_shares == 0) revert AmountIsZero();
        _mint(receiver_, _shares);

        emit Deposit(caller_, receiver_, assets_, _shares);
    }

    /// @dev Shares move only to whitelisted wallets; burns are always allowed so exits never depend on the whitelist
    function _update(address from_, address to_, uint256 value_) internal override {
        if (to_ != address(0) && !_getStorage().whitelist.contains(to_)) revert NotWhitelisted(to_);
        super._update(from_, to_, value_);
    }

    /// @dev Shares burned, their sVUSD unstaked through the spoke, ctDefiUSDT paid to the receiver. `assets_` already
    /// reflects any shortfall.
    function _withdraw(address caller_, address receiver_, address owner_, uint256 assets_, uint256 shares_)
        internal
        override
        nonReentrant
    {
        if (assets_ == 0) revert AmountIsZero();
        ConcreteLPVaultStorage storage $ = _getStorage();
        _checkNotSanctioned($, caller_);
        if (owner_ != caller_) _checkNotSanctioned($, owner_);

        // sVUSD that buys `assets_` back; `assets_` is never more than the vault's sVUSD covers
        uint256 _sVusdOut = Math.min(_sVusdFor(assets_), _sVusdBalance());

        if (caller_ != owner_) _spendAllowance(owner_, caller_, shares_);
        _burn(owner_, shares_);

        ConcreteSpoke _spoke = $.spoke;
        IERC20(address($.sVusd)).forceApprove(address(_spoke), _sVusdOut);
        // The spoke screens the receiver and pays it directly; it rounds in the payer's favour, never below assets_
        _spoke.unstakeAndRedeem(_sVusdOut, assets_, receiver_);

        emit Withdraw(caller_, receiver_, owner_, assets_, shares_);
    }

    /*/////////////////////////////////////////////////////////////
                     INTERNAL VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Assets from shares at the pro rata rate (one ctDefiUSDT per share while covered)
    function _convertToAssets(uint256 shares_, Math.Rounding rounding_) internal view override returns (uint256) {
        uint256 _supply = totalSupply();
        uint256 _total = totalAssets();
        if (_supply == 0 || _total >= _supply) return shares_;
        return shares_.mulDiv(_total, _supply, rounding_);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Shares from assets at the pro rata rate (one per ctDefiUSDT while covered)
    function _convertToShares(uint256 assets_, Math.Rounding rounding_) internal view override returns (uint256) {
        uint256 _supply = totalSupply();
        uint256 _total = totalAssets();
        if (_supply == 0 || _total >= _supply) return assets_;
        return assets_.mulDiv(_supply, _total, rounding_);
    }

    /*/////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    function _checkNotSanctioned(ConcreteLPVaultStorage storage $, address account_) private view {
        ITreasury($.spoke.peggedToken().treasury()).checkNotSanctioned(account_);
    }

    function _checkSpokeHealthy(ConcreteLPVaultStorage storage $) private view {
        ConcreteSpoke _spoke = $.spoke;
        uint256 _reserve = _spoke.reserve();
        uint256 _supply = IGateway(_spoke.peggedToken().gateway()).spokeSupply(address(_spoke));
        if (_reserve < _supply) revert SpokeUndercollateralized(_reserve, _supply);
    }

    /// @dev ctDefiUSDT `sVusd_` redeems to through the spoke (both steps rounded down)
    function _ctValue(uint256 sVusd_) private view returns (uint256) {
        if (sVusd_ == 0) return 0;
        return _getStorage().spoke.previewUnstakeAndRedeem(sVusd_);
    }

    /**
     * @dev ctDefiUSDT the spoke can pay now against its supply (its burns never exceed it). 0 while the spoke is shut
     * down or its share price is unreadable.
     */
    function _payableCt() private view returns (uint256) {
        ConcreteLPVaultStorage storage $ = _getStorage();
        ConcreteSpoke _spoke = $.spoke;
        if (_spoke.shutdown()) return 0;
        uint256 _supply = IGateway(_spoke.peggedToken().gateway()).spokeSupply(address(_spoke));
        try _spoke.sharePrice() returns (uint256 _price) {
            return _price == 0 ? 0 : _supply.mulDiv($.ctUnit, _price);
        } catch {
            return 0;
        }
    }

    function _spokeHealthy(ConcreteLPVaultStorage storage $) private view returns (bool) {
        ConcreteSpoke _spoke = $.spoke;
        try _spoke.reserve() returns (uint256 _reserve) {
            return _reserve >= IGateway(_spoke.peggedToken().gateway()).spokeSupply(address(_spoke));
        } catch {
            return false;
        }
    }

    function _sVusdBalance() private view returns (uint256) {
        return IERC20(address(_getStorage().sVusd)).balanceOf(address(this));
    }

    /// @dev sVUSD that redeems through the spoke to at least `ct_` ctDefiUSDT (both steps rounded up)
    function _sVusdFor(uint256 ct_) private view returns (uint256) {
        if (ct_ == 0) return 0;
        ConcreteLPVaultStorage storage $ = _getStorage();
        uint256 _vusd = ct_.mulDiv($.spoke.sharePrice(), $.ctUnit, Math.Rounding.Ceil);
        return $.sVusd.previewWithdraw(_vusd);
    }

    /// @dev sVUSD that buys back one ctDefiUSDT per share
    function _sVusdNeeded() private view returns (uint256) {
        return _sVusdFor(totalSupply());
    }

    function _getStorage() private pure returns (ConcreteLPVaultStorage storage $) {
        bytes32 _location = CONCRETE_LP_VAULT_STORAGE_LOCATION;
        assembly {
            $.slot := _location
        }
    }
}
