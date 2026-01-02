// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PeggedToken} from "src/PeggedToken.sol";

/// forge-lint: disable-next-item(erc20-unchecked-transfer)
contract PeggedTokenTest is Test {
    using SafeERC20 for IERC20;

    PeggedToken vcUSD;

    address owner;
    address gateway = makeAddr("gateway");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        owner = address(this);

        vcUSD = new PeggedToken("vcUSD", "vcUSD", owner);

        vcUSD.updateTreasury(address(treasury));
        vcUSD.updateGateway(gateway);
    }

    // --- Update gateway address ---

    function test_updateGateway_revertIfTreasuryIsNotSet() public {
        PeggedToken vcUSD2 = new PeggedToken("vcUSD", "vcUSD", owner);

        vm.expectRevert("TreasuryIsNull()");
        vcUSD2.updateGateway(carol);
    }

    function test_updateGateway_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vcUSD.updateGateway(carol);
    }

    function test_updateGateway_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        vcUSD.updateGateway(address(0));
    }

    function test_updateGateway_success() public {
        address newGateway = carol;
        assertNotEq(vcUSD.gateway(), newGateway);
        vcUSD.updateGateway(newGateway);
        assertEq(vcUSD.gateway(), newGateway, "Gateway update failed");
    }

    // --- Update treasury address ---

    function test_updateTreasury_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vcUSD.updateTreasury(carol);
    }

    function test_updateTreasury_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        vcUSD.updateTreasury(address(0));
    }

    function test_updateTreasury_success() public {
        address newTreasury = carol;
        assertNotEq(vcUSD.treasury(), newTreasury);
        vcUSD.updateTreasury(newTreasury);
        assertEq(vcUSD.treasury(), newTreasury, "Treasury update failed");
    }

    // --- Mint PeggedToken ---

    function test_mint() public {
        uint256 peggedTokenBefore = vcUSD.balanceOf(alice);
        assertEq(peggedTokenBefore, 0, "Incorrect PeggedToken balance before mint");

        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        vcUSD.mint(alice, mintAmount);
        uint256 peggedTokenAfter = vcUSD.balanceOf(alice);
        assertEq(peggedTokenAfter, mintAmount, "Incorrect PeggedToken balance after mint");
    }

    function test_mint_revertIfNotGateway() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotGateway(address)", bob));
        vcUSD.mint(alice, 10000);
    }

    function test_mint_revertIfToBlacklisted() public {
        // Blacklist alice
        vcUSD.addToBlacklist(alice);

        // Try to mint to alice
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vcUSD.mint(alice, 100e18);
    }

    // --- burnFrom ---

    function test_burnFrom_byAnotherUser() public {
        // Mint some PeggedToken
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        vcUSD.mint(alice, mintAmount);
        assertEq(vcUSD.balanceOf(alice), mintAmount, "Mint failed");

        // Set approval for bob
        vm.prank(alice);
        vcUSD.approve(bob, mintAmount);
        assertEq(vcUSD.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.prank(bob);
        vcUSD.burnFrom(alice, mintAmount);
        assertEq(vcUSD.balanceOf(alice), 0, "PeggedToken balance should be zero");
        assertEq(vcUSD.allowance(alice, bob), 0, "Allowance should be zero");
    }

    function test_burnFrom_byGateway() public {
        // Mint some PeggedToken
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        vcUSD.mint(alice, mintAmount);
        assertEq(vcUSD.balanceOf(alice), mintAmount, "Mint failed");

        // Gateway calling burn
        vm.prank(gateway);
        vcUSD.burnFrom(alice, mintAmount);
        assertEq(vcUSD.balanceOf(alice), 0, "PeggedToken balance should be zero");
    }

    function test_burnFrom_revertIfBlacklisted() public {
        // Mint PeggedToken to alice
        uint256 mintAmount = 100e18;
        vm.prank(gateway);
        vcUSD.mint(alice, mintAmount);

        // Blacklist alice
        vcUSD.addToBlacklist(alice);

        // Set approval for bob
        vm.prank(alice);
        vcUSD.approve(bob, mintAmount);
        assertEq(vcUSD.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vm.prank(bob);
        vcUSD.burnFrom(alice, mintAmount);
    }

    // --- addToBlacklist ---

    function test_addToBlacklist_success() public {
        assertFalse(vcUSD.isBlacklisted(alice));
        vcUSD.addToBlacklist(alice);
        assertTrue(vcUSD.isBlacklisted(alice));
    }

    function test_addToBlacklist_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vcUSD.addToBlacklist(alice);
    }

    function test_addToBlacklist_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        vcUSD.addToBlacklist(address(0));
    }

    function test_addToBlacklist_revertIfAlreadyBlacklisted() public {
        vcUSD.addToBlacklist(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyBlacklisted(address)", alice));
        vcUSD.addToBlacklist(alice);
    }

    // --- removeFromBlacklist ---

    function test_removeFromBlacklist_success() public {
        vcUSD.addToBlacklist(alice);
        assertTrue(vcUSD.isBlacklisted(alice));
        vcUSD.removeFromBlacklist(alice);
        assertFalse(vcUSD.isBlacklisted(alice));
    }

    function test_removeFromBlacklist_revertIfNotOwner() public {
        vcUSD.addToBlacklist(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vcUSD.removeFromBlacklist(alice);
    }

    function test_removeFromBlacklist_revertIfNotBlacklisted() public {
        vm.expectRevert(abi.encodeWithSignature("NotBlacklisted(address)", alice));
        vcUSD.removeFromBlacklist(alice);
    }

    // --- getBlacklistedAddresses ---

    function test_getBlacklistedAddresses() public {
        address[] memory blacklisted = vcUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 0);

        vcUSD.addToBlacklist(alice);
        vcUSD.addToBlacklist(bob);
        blacklisted = vcUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 2);
        assertTrue(blacklisted[0] == alice || blacklisted[1] == alice);
        assertTrue(blacklisted[0] == bob || blacklisted[1] == bob);

        vcUSD.removeFromBlacklist(alice);
        blacklisted = vcUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 1);
        assertEq(blacklisted[0], bob);
    }

    // --- transfer ---

    function test_transfer() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        vcUSD.mint(alice, 100e18);

        // Transfer should work normally
        vm.prank(alice);
        vcUSD.transfer(bob, 50e18);
        assertEq(vcUSD.balanceOf(alice), 50e18);
        assertEq(vcUSD.balanceOf(bob), 50e18);
    }

    function test_transfer_revertIfFromBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        vcUSD.mint(alice, 100e18);

        // Blacklist alice
        vcUSD.addToBlacklist(alice);

        // Try to transfer from alice
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vcUSD.transfer(bob, 50e18);
    }

    function test_transfer_revertIfToBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        vcUSD.mint(alice, 100e18);

        // Blacklist bob
        vcUSD.addToBlacklist(bob);

        // Try to transfer to bob
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", bob));
        vcUSD.transfer(bob, 50e18);
    }

    // --- transferFrom ---

    function test_transferFrom() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        vcUSD.mint(alice, 100e18);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        vcUSD.approve(bob, 100e18);
        assertEq(vcUSD.allowance(alice, bob), 100e18);

        // Bob transfers 40e18 from alice to carol
        vm.prank(bob);
        vcUSD.transferFrom(alice, carol, 40e18);

        // Check balances and allowance
        assertEq(vcUSD.balanceOf(alice), 60e18);
        assertEq(vcUSD.balanceOf(carol), 40e18);
        assertEq(vcUSD.allowance(alice, bob), 60e18);
    }

    function test_transferFrom_revertIfFromBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        vcUSD.mint(alice, 100e18);

        // Blacklist alice
        vcUSD.addToBlacklist(alice);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        vcUSD.approve(bob, 100e18);

        // Try to transferFrom alice
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vcUSD.transferFrom(alice, carol, 50e18);
    }

    function test_transferFrom_revertIfToBlacklisted() public {
        // Mint PeggedToken to alice
        vm.prank(gateway);
        vcUSD.mint(alice, 100e18);

        // Blacklist carol
        vcUSD.addToBlacklist(carol);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        vcUSD.approve(bob, 100e18);

        // Try to transferFrom alice to carol
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", carol));
        vcUSD.transferFrom(alice, carol, 50e18);
    }
}
