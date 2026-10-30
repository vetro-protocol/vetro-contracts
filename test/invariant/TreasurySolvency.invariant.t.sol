// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {deployTreasury} from "test/helpers/Deploy.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockYieldVaultRealistic} from "test/mocks/MockYieldVaultRealistic.sol";

/// @notice Drives random mint / redeem / AMO / yield / price-tick / harvest sequences against the full system.
/// @dev AMO-minted tokens are held by the handler. Besides burnFromAMO, `amoFloatRedeem` hands AMO float
///      to an actor who redeems it at the Gateway (the Morpho-borrower path), so redemptions can burn
///      AMO-origin supply. Combined with vault yield, that is what used to push totalSupply below amoSupply.
contract TreasurySolvencyHandler is Test {
    Gateway public gateway;
    Treasury public treasury;
    PeggedToken public vusd;
    MockERC20 public collateral;
    MockYieldVaultRealistic public vault;
    MockChainlinkOracle public oracle;

    address[] public actors;
    address public yieldSink = makeAddr("yieldSink");
    address internal currentActor;

    uint256 public ghost_minted;
    uint256 public ghost_redeemed;
    uint256 public ghost_amoMinted;
    uint256 public ghost_amoBurned;
    uint256 public ghost_yield;
    uint256 public ghost_amoFloatRedeemed;
    uint256 public ghost_harvested;
    uint256 public ghost_priceTicks;
    uint256 public ghost_donated;
    uint256 public ghost_capUpdates;
    uint256 public ghost_capRejections;
    uint256 public ghost_harvestCapRejections;
    // A deposit that passed the cap check with net deposits ending above the cap, or was refused while within it
    uint256 public ghost_capViolations;
    // Independent model of Treasury.netDeposited: up on deposits, down on what redemptions and harvest pay out
    uint256 public ghost_netDeposited;

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, actors.length - 1)];
        _;
    }

    constructor(
        Gateway gateway_,
        Treasury treasury_,
        PeggedToken vusd_,
        MockERC20 collateral_,
        MockYieldVaultRealistic vault_,
        MockChainlinkOracle oracle_,
        address[] memory actors_
    ) {
        gateway = gateway_;
        treasury = treasury_;
        vusd = vusd_;
        collateral = collateral_;
        vault = vault_;
        oracle = oracle_;
        actors = actors_;
    }

    function userMint(uint256 seed, uint256 amount) external useActor(seed) {
        amount = bound(amount, 1e12, 1_000_000e18);
        deal(address(collateral), currentActor, amount);
        bool _overCap = ghost_netDeposited + amount > treasury.depositCap(address(collateral));
        vm.startPrank(currentActor);
        collateral.approve(address(gateway), amount);
        try gateway.deposit(address(collateral), amount, 0, currentActor) {
            ghost_minted += amount;
            ghost_netDeposited += amount;
            if (_overCap) ghost_capViolations++;
        } catch (bytes memory reason) {
            _revertUnlessCapExceeded(reason);
            ghost_capRejections++;
            if (!_overCap) ghost_capViolations++;
        }
        vm.stopPrank();
    }

    // Moves the cap to between half and twice the current net deposits, so deposits both pass and hit it
    function setCap(uint256 cap) external {
        uint256 _net = ghost_netDeposited;
        cap = _net == 0 ? bound(cap, 1, 2_000_000e18) : bound(cap, _net / 2, _net * 2);
        treasury.updateDepositCap(address(collateral), cap);
        ghost_capUpdates++;
    }

    /// @dev Book value: idle balance plus the value of the vault shares
    function holdings() public view returns (uint256) {
        return collateral.balanceOf(address(treasury)) + vault.convertToAssets(vault.balanceOf(address(treasury)));
    }

    function userRedeem(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 _bal = vusd.balanceOf(currentActor);
        if (_bal == 0) return;
        amount = bound(amount, 1, _bal);
        vm.prank(currentActor);
        _reduceNetDeposited(gateway.redeem(address(collateral), amount, 0, currentActor));
        ghost_redeemed += amount;
    }

    function amoFloatRedeem(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 _held = vusd.balanceOf(address(this));
        if (_held == 0) return;
        amount = bound(amount, 1, _held);
        vusd.transfer(currentActor, amount);
        vm.prank(currentActor);
        _reduceNetDeposited(gateway.redeem(address(collateral), amount, 0, currentActor));
        ghost_amoFloatRedeemed += amount;
    }

    function amoMint(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);
        gateway.mintToAMO(amount, address(this)); // limit is set high once in setUp
        ghost_amoMinted += amount;
    }

    function amoBurn(uint256 amount) external {
        uint256 _supply = gateway.amoSupply();
        uint256 _held = vusd.balanceOf(address(this));
        uint256 _cap = _supply < _held ? _supply : _held;
        if (_cap == 0) return;
        amount = bound(amount, 1, _cap);
        gateway.burnFromAMO(amount);
        ghost_amoBurned += amount;
    }

    function vaultYield(uint256 amount) external {
        if (vault.totalShares() == 0) return;
        amount = bound(amount, 1, 100_000e18);
        deal(address(collateral), address(this), amount);
        collateral.approve(address(vault), amount);
        vault.simulateYield(amount);
        ghost_yield += amount;
    }

    // Collateral that arrives outside a deposit: holdings grow, net deposits do not
    function donateIdle(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);
        deal(address(collateral), address(treasury), collateral.balanceOf(address(treasury)) + amount);
        ghost_donated += amount;
    }

    // Caps what one vault withdrawal can deliver (0 is fully liquid), so redemptions and harvest take partial paths
    function vaultLiquidity(uint256 liquidCap, bool liquidityAware) external {
        vault.setLiquidCap(bound(liquidCap, 0, 1_000_000e18));
        vault.setLiquidityAwareMaxWithdraw(liquidityAware);
    }

    // Moves the oracle anywhere inside the Treasury's default 1% priceTolerance
    function priceTick(uint256 price) external {
        price = bound(price, 0.99e8, 1.01e8);
        oracle.updatePrice(int256(price));
        ghost_priceTicks++;
    }

    // Re-mints the harvested collateral through the Gateway, as YieldManager does. The re-deposit is held to the cap
    // like any deposit; when it is refused, the harvested collateral stays with the handler.
    function harvest() external {
        uint256 _harvested = treasury.harvest(address(collateral), address(this));
        if (_harvested == 0) return;
        ghost_harvested += _harvested;
        _reduceNetDeposited(_harvested);
        bool _overCap = ghost_netDeposited + _harvested > treasury.depositCap(address(collateral));
        collateral.approve(address(gateway), _harvested);
        try gateway.deposit(address(collateral), _harvested, 0, yieldSink) {
            ghost_netDeposited += _harvested;
            if (_overCap) ghost_capViolations++;
        } catch (bytes memory reason) {
            _revertUnlessCapExceeded(reason);
            ghost_harvestCapRejections++;
            if (!_overCap) ghost_capViolations++;
        }
    }

    function _reduceNetDeposited(uint256 amount) internal {
        ghost_netDeposited = ghost_netDeposited > amount ? ghost_netDeposited - amount : 0;
    }

    function _revertUnlessCapExceeded(bytes memory reason) internal pure {
        if (bytes4(reason) != Treasury.ExceededDepositCap.selector) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

contract TreasurySolvencyInvariantTest is Test {
    Gateway gateway;
    Treasury treasury;
    PeggedToken vusd;
    MockERC20 collateral;
    MockChainlinkOracle oracle;
    MockYieldVaultRealistic vault;
    TreasurySolvencyHandler handler;

    address owner = address(this);
    address[] actors;

    function setUp() public {
        collateral = new MockERC20();
        collateral.setDecimals(18); // match PeggedToken so par math is exact
        oracle = new MockChainlinkOracle(1e8);
        vault = new MockYieldVaultRealistic(address(collateral));

        vusd = new PeggedToken("viaUSD", "viaUSD", owner);
        treasury = deployTreasury(address(vusd), owner);
        vusd.updateTreasury(address(treasury));
        // The tests act as keeper and maintainer
        treasury.grantRole(treasury.KEEPER_ROLE(), address(this));
        treasury.grantRole(treasury.MAINTAINER_ROLE(), address(this));

        Gateway impl = new Gateway();
        bytes memory initData =
            abi.encodeWithSelector(Gateway.initialize.selector, address(vusd), type(uint256).max, 7 days);
        gateway = Gateway(address(new ERC1967Proxy(address(impl), initData)));
        vusd.updateGateway(address(gateway));

        gateway.setWithdrawalDelayEnabled(false); // instant redeem path in the handler
        gateway.updateAmoMintLimit(type(uint256).max); // owner (default admin) lifts the AMO cap once
        treasury.addToWhitelist(address(collateral), address(vault), address(oracle), 1 days);

        for (uint256 i; i < 4; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }

        handler = new TreasurySolvencyHandler(gateway, treasury, vusd, collateral, vault, oracle, actors);

        // Gateway role checks resolve against Treasury.hasRole; UMM covers mintToAMO/burnFromAMO/harvest.
        treasury.grantRole(treasury.UMM_ROLE(), address(handler));
        treasury.grantRole(treasury.MAINTAINER_ROLE(), address(handler)); // setCap

        targetContract(address(handler));
        excludeContract(address(gateway));
        excludeContract(address(treasury));
        excludeContract(address(vusd));
        excludeContract(address(vault));
        excludeContract(address(collateral));
        excludeContract(address(oracle));
    }

    /// @notice Backing at par never falls below the collateralized (non-AMO) supply.
    /// @dev Valued at par because a below-par tick legitimately marks reserve() down; the collateral
    ///      has 18 decimals, so its token count is its par value.
    function invariant_collateralization() public view {
        uint256 _backedSupply = vusd.totalSupply() - gateway.amoSupply();
        assertGe(handler.holdings(), _backedSupply, "par backing below backed supply");

        // At or above par reserve() takes the capped path, so it must still cover the backed supply
        (uint256 _price, uint256 _unitPrice) = treasury.getPrice(address(collateral));
        if (_price >= _unitPrice) assertGe(treasury.reserve(), _backedSupply, "reserve below backed supply");
    }

    /// @notice A deposit succeeds exactly when it leaves the modeled net deposits at or under the cap. Net deposits
    ///         only pass the cap through a lower cap, never through a deposit.
    function invariant_depositCap() public view {
        assertEq(handler.ghost_capViolations(), 0, "a deposit got past the cap, or was refused within it");
    }

    /// @notice The Treasury's counter matches an independent model of what came in and what was paid out.
    function invariant_netDepositedMatchesModel() public view {
        assertEq(
            treasury.netDeposited(address(collateral)), handler.ghost_netDeposited(), "netDeposited drifted from model"
        );
    }

    /// @notice AMO supply is always a subset of total supply (so maxMint's subtraction can't underflow).
    function invariant_amoSupplyWithinTotalSupply() public view {
        assertLe(gateway.amoSupply(), vusd.totalSupply(), "amoSupply exceeds totalSupply");
        gateway.maxMint(); // must not revert, or deposit()/mint() are bricked
    }

    function invariant_callSummary() public view {
        console.log("minted:   ", handler.ghost_minted());
        console.log("redeemed: ", handler.ghost_redeemed());
        console.log("amoMinted:", handler.ghost_amoMinted());
        console.log("amoBurned:", handler.ghost_amoBurned());
        console.log("yield:    ", handler.ghost_yield());
        console.log("amoFloatRedeemed:", handler.ghost_amoFloatRedeemed());
        console.log("harvested:", handler.ghost_harvested());
        console.log("priceTicks:", handler.ghost_priceTicks());
        console.log("capUpdates:", handler.ghost_capUpdates());
        console.log("capRejections:", handler.ghost_capRejections());
        console.log("harvestCapRejections:", handler.ghost_harvestCapRejections());
        console.log("donated:", handler.ghost_donated());
        console.log("netDeposited:", treasury.netDeposited(address(collateral)));
        console.log("reserve:  ", treasury.reserve());
        console.log("supply:   ", vusd.totalSupply());
        console.log("amoSupply:", gateway.amoSupply());
    }
}
