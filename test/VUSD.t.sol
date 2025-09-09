// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VUSD} from "src/VUSD.sol";

contract VUSDTest is Test {
    using SafeERC20 for IERC20;

    VUSD vusd;

    address owner;
    address gateway = makeAddr("gateway");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        owner = address(this);

        vusd = new VUSD(owner);

        vusd.updateTreasury(address(treasury));
        vusd.updateGateway(gateway);
    }

    // --- Update gateway address ---

    function test_updateGateway_revertIfTreasuryIsNotSet() public {
        VUSD vusd2 = new VUSD(owner);

        vm.expectRevert("TreasuryIsNull()");
        vusd2.updateGateway(carol);
    }

    function test_updateGateway_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vusd.updateGateway(carol);
    }

    function test_updateGateway_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        vusd.updateGateway(address(0));
    }

    function test_updateGateway_success() public {
        address newGateway = carol;
        assertNotEq(vusd.gateway(), newGateway);
        vusd.updateGateway(newGateway);
        assertEq(vusd.gateway(), newGateway, "Gateway update failed");
    }

    // --- Update treasury address ---

    function test_updateTreasury_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vusd.updateTreasury(carol);
    }

    function test_updateTreasury_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        vusd.updateTreasury(address(0));
    }

    function test_updateTreasury_success() public {
        address newTreasury = carol;
        assertNotEq(vusd.treasury(), newTreasury);
        vusd.updateTreasury(newTreasury);
        assertEq(vusd.treasury(), newTreasury, "Treasury update failed");
    }

    // --- Mint VUSD ---

    function test_mint() public {
        uint256 vusdBefore = vusd.balanceOf(alice);
        assertEq(vusdBefore, 0, "Incorrect VUSD balance before mint");

        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        vusd.mint(alice, mintAmount);
        uint256 vusdAfter = vusd.balanceOf(alice);
        assertEq(vusdAfter, mintAmount, "Incorrect VUSD balance after mint");
    }

    // --- burnFrom ---

    function test_burnFrom_byAnotherUser() public {
        // Mint some VUSD
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        vusd.mint(alice, mintAmount);
        assertEq(vusd.balanceOf(alice), mintAmount, "Mint failed");

        // Set approval for bob
        vm.prank(alice);
        vusd.approve(bob, mintAmount);
        assertEq(vusd.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.prank(bob);
        vusd.burnFrom(alice, mintAmount);
        assertEq(vusd.balanceOf(alice), 0, "VUSD balance should be zero");
        assertEq(vusd.allowance(alice, bob), 0, "Allowance should be zero");
    }

    function test_burnFrom_byGateway() public {
        // Mint some VUSD
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        vusd.mint(alice, mintAmount);
        assertEq(vusd.balanceOf(alice), mintAmount, "Mint failed");

        // Set approval for gateway
        vm.prank(alice);
        vusd.approve(gateway, mintAmount);
        assertEq(vusd.allowance(alice, gateway), mintAmount, "Approval failed");

        // Gateway calling burn
        vm.prank(gateway);
        vusd.burnFrom(alice, mintAmount);
        assertEq(vusd.balanceOf(alice), 0, "VUSD balance should be zero");
        // allowance will not be used for gateway
        assertEq(vusd.allowance(alice, gateway), mintAmount, "Allowance should be same as before");
    }

    function test_mint_revertIfNotGateway() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotGateway(address)", bob));
        vusd.mint(alice, 10000);
    }
}
