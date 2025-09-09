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

    function test_mint_revertIfNotGateway() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotGateway(address)", bob));
        vusd.mint(alice, 10000);
    }

    function test_mint_revertIfToBlacklisted() public {
        // Blacklist alice
        vusd.addToBlacklist(alice);

        // Try to mint to alice
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vusd.mint(alice, 100e18);
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

        // Gateway calling burn
        vm.prank(gateway);
        vusd.burnFrom(alice, mintAmount);
        assertEq(vusd.balanceOf(alice), 0, "VUSD balance should be zero");
    }

    function test_burnFrom_revertIfBlacklisted() public {
        // Mint VUSD to alice
        uint256 mintAmount = 100e18;
        vm.prank(gateway);
        vusd.mint(alice, mintAmount);

        // Blacklist alice
        vusd.addToBlacklist(alice);

        // Set approval for bob
        vm.prank(alice);
        vusd.approve(bob, mintAmount);
        assertEq(vusd.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vm.prank(bob);
        vusd.burnFrom(alice, mintAmount);
    }

    // --- addToBlacklist ---

    function test_addToBlacklist_success() public {
        assertFalse(vusd.isBlacklisted(alice));
        vusd.addToBlacklist(alice);
        assertTrue(vusd.isBlacklisted(alice));
    }

    function test_addToBlacklist_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vusd.addToBlacklist(alice);
    }

    function test_addToBlacklist_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        vusd.addToBlacklist(address(0));
    }

    function test_addToBlacklist_revertIfAlreadyBlacklisted() public {
        vusd.addToBlacklist(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyBlacklisted(address)", alice));
        vusd.addToBlacklist(alice);
    }

    // --- removeFromBlacklist ---

    function test_removeFromBlacklist_success() public {
        vusd.addToBlacklist(alice);
        assertTrue(vusd.isBlacklisted(alice));
        vusd.removeFromBlacklist(alice);
        assertFalse(vusd.isBlacklisted(alice));
    }

    function test_removeFromBlacklist_revertIfNotOwner() public {
        vusd.addToBlacklist(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vusd.removeFromBlacklist(alice);
    }

    function test_removeFromBlacklist_revertIfNotBlacklisted() public {
        vm.expectRevert(abi.encodeWithSignature("NotBlacklisted(address)", alice));
        vusd.removeFromBlacklist(alice);
    }

    // --- getBlacklistedAddresses ---

    function test_getBlacklistedAddresses() public {
        address[] memory blacklisted = vusd.getBlacklistedAddresses();
        assertEq(blacklisted.length, 0);

        vusd.addToBlacklist(alice);
        vusd.addToBlacklist(bob);
        blacklisted = vusd.getBlacklistedAddresses();
        assertEq(blacklisted.length, 2);
        assertTrue(blacklisted[0] == alice || blacklisted[1] == alice);
        assertTrue(blacklisted[0] == bob || blacklisted[1] == bob);

        vusd.removeFromBlacklist(alice);
        blacklisted = vusd.getBlacklistedAddresses();
        assertEq(blacklisted.length, 1);
        assertEq(blacklisted[0], bob);
    }

    // --- transfer ---

    function test_transfer() public {
        // Mint VUSD to alice
        vm.prank(gateway);
        vusd.mint(alice, 100e18);

        // Transfer should work normally
        vm.prank(alice);
        vusd.transfer(bob, 50e18);
        assertEq(vusd.balanceOf(alice), 50e18);
        assertEq(vusd.balanceOf(bob), 50e18);
    }

    function test_transfer_revertIfFromBlacklisted() public {
        // Mint VUSD to alice
        vm.prank(gateway);
        vusd.mint(alice, 100e18);

        // Blacklist alice
        vusd.addToBlacklist(alice);

        // Try to transfer from alice
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vusd.transfer(bob, 50e18);
    }

    function test_transfer_revertIfToBlacklisted() public {
        // Mint VUSD to alice
        vm.prank(gateway);
        vusd.mint(alice, 100e18);

        // Blacklist bob
        vusd.addToBlacklist(bob);

        // Try to transfer to bob
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", bob));
        vusd.transfer(bob, 50e18);
    }

    // --- transferFrom ---

    function test_transferFrom() public {
        // Mint VUSD to alice
        vm.prank(gateway);
        vusd.mint(alice, 100e18);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        vusd.approve(bob, 100e18);
        assertEq(vusd.allowance(alice, bob), 100e18);

        // Bob transfers 40e18 from alice to carol
        vm.prank(bob);
        vusd.transferFrom(alice, carol, 40e18);

        // Check balances and allowance
        assertEq(vusd.balanceOf(alice), 60e18);
        assertEq(vusd.balanceOf(carol), 40e18);
        assertEq(vusd.allowance(alice, bob), 60e18);
    }

    function test_transferFrom_revertIfFromBlacklisted() public {
        // Mint VUSD to alice
        vm.prank(gateway);
        vusd.mint(alice, 100e18);

        // Blacklist alice
        vusd.addToBlacklist(alice);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        vusd.approve(bob, 100e18);

        // Try to transferFrom alice
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vusd.transferFrom(alice, carol, 50e18);
    }

    function test_transferFrom_revertIfToBlacklisted() public {
        // Mint VUSD to alice
        vm.prank(gateway);
        vusd.mint(alice, 100e18);

        // Blacklist carol
        vusd.addToBlacklist(carol);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        vusd.approve(bob, 100e18);

        // Try to transferFrom alice to carol
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", carol));
        vusd.transferFrom(alice, carol, 50e18);
    }
}
