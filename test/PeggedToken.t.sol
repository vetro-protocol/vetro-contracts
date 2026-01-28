// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PeggedToken} from "src/PeggedToken.sol";

/// forge-lint: disable-next-item(erc20-unchecked-transfer)
contract PeggedTokenTest is Test {
    using SafeERC20 for IERC20;

    PeggedToken VUSD;

    address owner;
    address gateway = makeAddr("gateway");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        owner = address(this);

        VUSD = new PeggedToken("VUSD", "VUSD", owner);

        VUSD.updateTreasury(address(treasury));
        VUSD.updateGateway(gateway);
    }

    // --- Update gateway address ---

    function test_updateGateway_revertIfTreasuryIsNotSet() public {
        PeggedToken VUSD2 = new PeggedToken("VUSD", "VUSD", owner);

        vm.expectRevert(PeggedToken.TreasuryCanNotBeZero.selector);
        VUSD2.updateGateway(carol);
    }

    function test_updateGateway_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        VUSD.updateGateway(carol);
    }

    function test_updateGateway_revertIfZeroAddress() public {
        vm.expectRevert(PeggedToken.AddressIsZero.selector);
        VUSD.updateGateway(address(0));
    }

    function test_updateGateway_success() public {
        address newGateway = carol;
        assertNotEq(VUSD.gateway(), newGateway);
        VUSD.updateGateway(newGateway);
        assertEq(VUSD.gateway(), newGateway, "Gateway update failed");
    }

    // --- Update treasury address ---

    function test_updateTreasury_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        VUSD.updateTreasury(carol);
    }

    function test_updateTreasury_revertIfZeroAddress() public {
        vm.expectRevert(PeggedToken.AddressIsZero.selector);
        VUSD.updateTreasury(address(0));
    }

    function test_updateTreasury_success() public {
        address newTreasury = carol;
        assertNotEq(VUSD.treasury(), newTreasury);
        VUSD.updateTreasury(newTreasury);
        assertEq(VUSD.treasury(), newTreasury, "Treasury update failed");
    }

    // --- Mint PeggedToken ---

    function test_mint() public {
        uint256 peggedTokenBefore = VUSD.balanceOf(alice);
        assertEq(peggedTokenBefore, 0, "Incorrect PeggedToken balance before mint");

        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        VUSD.mint(alice, mintAmount);
        uint256 peggedTokenAfter = VUSD.balanceOf(alice);
        assertEq(peggedTokenAfter, mintAmount, "Incorrect PeggedToken balance after mint");
    }

    function test_mint_revertIfNotGateway() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotGateway(address)", bob));
        VUSD.mint(alice, 10000);
    }

    function test_mint_revertIfToBlacklisted() public {
        // Blacklist alice
        VUSD.addToBlacklist(alice);

        // Try to mint to alice
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        VUSD.mint(alice, 100e18);
    }

    // --- burnFrom ---

    function test_burnFrom_byAnotherUser() public {
        // Mint some PeggedToken
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        VUSD.mint(alice, mintAmount);
        assertEq(VUSD.balanceOf(alice), mintAmount, "Mint failed");

        // Set approval for bob
        vm.prank(alice);
        VUSD.approve(bob, mintAmount);
        assertEq(VUSD.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.prank(bob);
        VUSD.burnFrom(alice, mintAmount);
        assertEq(VUSD.balanceOf(alice), 0, "PeggedToken balance should be zero");
        assertEq(VUSD.allowance(alice, bob), 0, "Allowance should be zero");
    }

    function test_burnFrom_byGateway() public {
        // Mint some PeggedToken
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        VUSD.mint(alice, mintAmount);
        assertEq(VUSD.balanceOf(alice), mintAmount, "Mint failed");

        // Gateway calling burn
        vm.prank(gateway);
        VUSD.burnFrom(alice, mintAmount);
        assertEq(VUSD.balanceOf(alice), 0, "PeggedToken balance should be zero");
    }

    function test_burnFrom_revertIfBlacklisted() public {
        // Mint PeggedToken to alice
        uint256 mintAmount = 100e18;
        vm.prank(gateway);
        VUSD.mint(alice, mintAmount);

        // Blacklist alice
        VUSD.addToBlacklist(alice);

        // Set approval for bob
        vm.prank(alice);
        VUSD.approve(bob, mintAmount);
        assertEq(VUSD.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vm.prank(bob);
        VUSD.burnFrom(alice, mintAmount);
    }

    // --- addToBlacklist ---

    function test_addToBlacklist_success() public {
        assertFalse(VUSD.isBlacklisted(alice));
        VUSD.addToBlacklist(alice);
        assertTrue(VUSD.isBlacklisted(alice));
    }

    function test_addToBlacklist_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        VUSD.addToBlacklist(alice);
    }

    function test_addToBlacklist_revertIfZeroAddress() public {
        vm.expectRevert(PeggedToken.AddressIsZero.selector);
        VUSD.addToBlacklist(address(0));
    }

    function test_addToBlacklist_revertIfAlreadyBlacklisted() public {
        VUSD.addToBlacklist(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyBlacklisted(address)", alice));
        VUSD.addToBlacklist(alice);
    }

    // --- removeFromBlacklist ---

    function test_removeFromBlacklist_success() public {
        VUSD.addToBlacklist(alice);
        assertTrue(VUSD.isBlacklisted(alice));
        VUSD.removeFromBlacklist(alice);
        assertFalse(VUSD.isBlacklisted(alice));
    }

    function test_removeFromBlacklist_revertIfNotOwner() public {
        VUSD.addToBlacklist(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        VUSD.removeFromBlacklist(alice);
    }

    function test_removeFromBlacklist_revertIfNotBlacklisted() public {
        vm.expectRevert(abi.encodeWithSignature("NotBlacklisted(address)", alice));
        VUSD.removeFromBlacklist(alice);
    }

    // --- getBlacklistedAddresses ---

    function test_getBlacklistedAddresses() public {
        address[] memory blacklisted = VUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 0);

        VUSD.addToBlacklist(alice);
        VUSD.addToBlacklist(bob);
        blacklisted = VUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 2);
        assertTrue(blacklisted[0] == alice || blacklisted[1] == alice);
        assertTrue(blacklisted[0] == bob || blacklisted[1] == bob);

        VUSD.removeFromBlacklist(alice);
        blacklisted = VUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 1);
        assertEq(blacklisted[0], bob);
    }

    // --- transfer ---

    function test_transfer() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        VUSD.mint(alice, 100e18);

        // Transfer should work normally
        vm.prank(alice);
        VUSD.transfer(bob, 50e18);
        assertEq(VUSD.balanceOf(alice), 50e18);
        assertEq(VUSD.balanceOf(bob), 50e18);
    }

    function test_transfer_revertIfFromBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        VUSD.mint(alice, 100e18);

        // Blacklist alice
        VUSD.addToBlacklist(alice);

        // Try to transfer from alice
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        VUSD.transfer(bob, 50e18);
    }

    function test_transfer_revertIfToBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        VUSD.mint(alice, 100e18);

        // Blacklist bob
        VUSD.addToBlacklist(bob);

        // Try to transfer to bob
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", bob));
        VUSD.transfer(bob, 50e18);
    }

    // --- transferFrom ---

    function test_transferFrom() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        VUSD.mint(alice, 100e18);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        VUSD.approve(bob, 100e18);
        assertEq(VUSD.allowance(alice, bob), 100e18);

        // Bob transfers 40e18 from alice to carol
        vm.prank(bob);
        VUSD.transferFrom(alice, carol, 40e18);

        // Check balances and allowance
        assertEq(VUSD.balanceOf(alice), 60e18);
        assertEq(VUSD.balanceOf(carol), 40e18);
        assertEq(VUSD.allowance(alice, bob), 60e18);
    }

    function test_transferFrom_revertIfFromBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        VUSD.mint(alice, 100e18);

        // Blacklist alice
        VUSD.addToBlacklist(alice);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        VUSD.approve(bob, 100e18);

        // Try to transferFrom alice
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        VUSD.transferFrom(alice, carol, 50e18);
    }

    function test_transferFrom_revertIfToBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        VUSD.mint(alice, 100e18);

        // Blacklist carol
        VUSD.addToBlacklist(carol);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        VUSD.approve(bob, 100e18);

        // Try to transferFrom alice to carol
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", carol));
        VUSD.transferFrom(alice, carol, 50e18);
    }
}
