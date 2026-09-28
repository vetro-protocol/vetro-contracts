// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockYieldVaultRealistic} from "test/mocks/MockYieldVaultRealistic.sol";

/// @notice Drives random mint / redeem / AMO / yield / harvest sequences against the full system.
/// @dev AMO-minted tokens are held by the handler. Besides burnFromAMO, `amoFloatRedeem` hands AMO float
///      to an actor who redeems it at the Gateway (the Morpho-borrower path), so redemptions can burn
///      AMO-origin supply. Combined with vault yield, that is what used to push totalSupply below amoSupply.
contract TreasurySolvencyHandler is Test {
    Gateway public gateway;
    Treasury public treasury;
    PeggedToken public vusd;
    MockERC20 public collateral;
    MockYieldVaultRealistic public vault;

    address[] public actors;
    address internal currentActor;

    uint256 public ghost_minted;
    uint256 public ghost_redeemed;
    uint256 public ghost_amoMinted;
    uint256 public ghost_amoBurned;
    uint256 public ghost_yield;
    uint256 public ghost_amoFloatRedeemed;

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
        address[] memory actors_
    ) {
        gateway = gateway_;
        treasury = treasury_;
        vusd = vusd_;
        collateral = collateral_;
        vault = vault_;
        actors = actors_;
    }

    function userMint(uint256 seed, uint256 amount) external useActor(seed) {
        amount = bound(amount, 1e12, 1_000_000e18);
        deal(address(collateral), currentActor, amount);
        vm.startPrank(currentActor);
        collateral.approve(address(gateway), amount);
        gateway.deposit(address(collateral), amount, 0, currentActor);
        vm.stopPrank();
        ghost_minted += amount;
    }

    function userRedeem(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 _bal = vusd.balanceOf(currentActor);
        if (_bal == 0) return;
        amount = bound(amount, 1, _bal);
        vm.prank(currentActor);
        gateway.redeem(address(collateral), amount, 0, currentActor);
        ghost_redeemed += amount;
    }

    function amoFloatRedeem(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 _held = vusd.balanceOf(address(this));
        if (_held == 0) return;
        amount = bound(amount, 1, _held);
        vusd.transfer(currentActor, amount);
        vm.prank(currentActor);
        gateway.redeem(address(collateral), amount, 0, currentActor);
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

    function harvest() external {
        treasury.harvest(address(collateral), address(this));
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
        treasury = new Treasury(address(vusd), owner);
        vusd.updateTreasury(address(treasury));

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

        handler = new TreasurySolvencyHandler(gateway, treasury, vusd, collateral, vault, actors);

        // Gateway role checks resolve against Treasury.hasRole; UMM covers mintToAMO/burnFromAMO/harvest.
        treasury.grantRole(treasury.UMM_ROLE(), address(handler));

        targetContract(address(handler));
        excludeContract(address(gateway));
        excludeContract(address(treasury));
        excludeContract(address(vusd));
        excludeContract(address(vault));
        excludeContract(address(collateral));
        excludeContract(address(oracle));
    }

    /// @notice Backing never falls below the collateralized (non-AMO) supply.
    function invariant_collateralization() public view {
        uint256 _backedSupply = vusd.totalSupply() - gateway.amoSupply();
        assertGe(treasury.reserve(), _backedSupply, "reserve below backed supply");
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
        console.log("reserve:  ", treasury.reserve());
        console.log("supply:   ", vusd.totalSupply());
        console.log("amoSupply:", gateway.amoSupply());
    }
}
