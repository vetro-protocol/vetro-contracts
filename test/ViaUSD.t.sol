// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Viat} from "src/Viat.sol";

/// forge-lint: disable-next-item(erc20-unchecked-transfer)
contract ViaUSDTest is Test {
    using SafeERC20 for IERC20;

    /// forge-lint: disable-next-line(mixed-case-variable)
    Viat viaUSD;

    address owner;
    address gateway = makeAddr("gateway");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        owner = address(this);

        viaUSD = new Viat("vaiUSD", "viaUSD", owner);

        viaUSD.updateTreasury(address(treasury));
        viaUSD.updateGateway(gateway);
    }

    // --- Update gateway address ---

    function test_updateGateway_revertIfTreasuryIsNotSet() public {
        /// forge-lint: disable-next-line(mixed-case-variable)
        Viat viaUSD2 = new Viat("vaiUSD", "viaUSD", owner);

        vm.expectRevert("TreasuryIsNull()");
        viaUSD2.updateGateway(carol);
    }

    function test_updateGateway_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        viaUSD.updateGateway(carol);
    }

    function test_updateGateway_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        viaUSD.updateGateway(address(0));
    }

    function test_updateGateway_success() public {
        address newGateway = carol;
        assertNotEq(viaUSD.gateway(), newGateway);
        viaUSD.updateGateway(newGateway);
        assertEq(viaUSD.gateway(), newGateway, "Gateway update failed");
    }

    // --- Update treasury address ---

    function test_updateTreasury_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        viaUSD.updateTreasury(carol);
    }

    function test_updateTreasury_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        viaUSD.updateTreasury(address(0));
    }

    function test_updateTreasury_success() public {
        address newTreasury = carol;
        assertNotEq(viaUSD.treasury(), newTreasury);
        viaUSD.updateTreasury(newTreasury);
        assertEq(viaUSD.treasury(), newTreasury, "Treasury update failed");
    }

    // --- Mint viaUSD ---

    function test_mint() public {
        uint256 viaUsdBefore = viaUSD.balanceOf(alice);
        assertEq(viaUsdBefore, 0, "Incorrect viaUSD balance before mint");

        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        viaUSD.mint(alice, mintAmount);
        uint256 viaUsdAfter = viaUSD.balanceOf(alice);
        assertEq(viaUsdAfter, mintAmount, "Incorrect viaUSD balance after mint");
    }

    function test_mint_revertIfNotGateway() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotGateway(address)", bob));
        viaUSD.mint(alice, 10000);
    }

    function test_mint_revertIfToBlacklisted() public {
        // Blacklist alice
        viaUSD.addToBlacklist(alice);

        // Try to mint to alice
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        viaUSD.mint(alice, 100e18);
    }

    // --- burnFrom ---

    function test_burnFrom_byAnotherUser() public {
        // Mint some viaUSD
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        viaUSD.mint(alice, mintAmount);
        assertEq(viaUSD.balanceOf(alice), mintAmount, "Mint failed");

        // Set approval for bob
        vm.prank(alice);
        viaUSD.approve(bob, mintAmount);
        assertEq(viaUSD.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.prank(bob);
        viaUSD.burnFrom(alice, mintAmount);
        assertEq(viaUSD.balanceOf(alice), 0, "viaUSD balance should be zero");
        assertEq(viaUSD.allowance(alice, bob), 0, "Allowance should be zero");
    }

    function test_burnFrom_byGateway() public {
        // Mint some viaUSD
        uint256 mintAmount = 100e18;
        vm.prank(address(gateway));
        viaUSD.mint(alice, mintAmount);
        assertEq(viaUSD.balanceOf(alice), mintAmount, "Mint failed");

        // Gateway calling burn
        vm.prank(gateway);
        viaUSD.burnFrom(alice, mintAmount);
        assertEq(viaUSD.balanceOf(alice), 0, "viaUSD balance should be zero");
    }

    function test_burnFrom_revertIfBlacklisted() public {
        // Mint viaUSD to alice
        uint256 mintAmount = 100e18;
        vm.prank(gateway);
        viaUSD.mint(alice, mintAmount);

        // Blacklist alice
        viaUSD.addToBlacklist(alice);

        // Set approval for bob
        vm.prank(alice);
        viaUSD.approve(bob, mintAmount);
        assertEq(viaUSD.allowance(alice, bob), mintAmount, "Approval failed");

        // Bob calling burnFrom for alice
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        vm.prank(bob);
        viaUSD.burnFrom(alice, mintAmount);
    }

    // --- addToBlacklist ---

    function test_addToBlacklist_success() public {
        assertFalse(viaUSD.isBlacklisted(alice));
        viaUSD.addToBlacklist(alice);
        assertTrue(viaUSD.isBlacklisted(alice));
    }

    function test_addToBlacklist_revertIfNotOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        viaUSD.addToBlacklist(alice);
    }

    function test_addToBlacklist_revertIfZeroAddress() public {
        vm.expectRevert("AddressIsNull()");
        viaUSD.addToBlacklist(address(0));
    }

    function test_addToBlacklist_revertIfAlreadyBlacklisted() public {
        viaUSD.addToBlacklist(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyBlacklisted(address)", alice));
        viaUSD.addToBlacklist(alice);
    }

    // --- removeFromBlacklist ---

    function test_removeFromBlacklist_success() public {
        viaUSD.addToBlacklist(alice);
        assertTrue(viaUSD.isBlacklisted(alice));
        viaUSD.removeFromBlacklist(alice);
        assertFalse(viaUSD.isBlacklisted(alice));
    }

    function test_removeFromBlacklist_revertIfNotOwner() public {
        viaUSD.addToBlacklist(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        viaUSD.removeFromBlacklist(alice);
    }

    function test_removeFromBlacklist_revertIfNotBlacklisted() public {
        vm.expectRevert(abi.encodeWithSignature("NotBlacklisted(address)", alice));
        viaUSD.removeFromBlacklist(alice);
    }

    // --- getBlacklistedAddresses ---

    function test_getBlacklistedAddresses() public {
        address[] memory blacklisted = viaUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 0);

        viaUSD.addToBlacklist(alice);
        viaUSD.addToBlacklist(bob);
        blacklisted = viaUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 2);
        assertTrue(blacklisted[0] == alice || blacklisted[1] == alice);
        assertTrue(blacklisted[0] == bob || blacklisted[1] == bob);

        viaUSD.removeFromBlacklist(alice);
        blacklisted = viaUSD.getBlacklistedAddresses();
        assertEq(blacklisted.length, 1);
        assertEq(blacklisted[0], bob);
    }

    // --- transfer ---

    function test_transfer() public {
        // Mint viaUSD to alice
        vm.prank(gateway);
        viaUSD.mint(alice, 100e18);

        // Transfer should work normally
        vm.prank(alice);
        viaUSD.transfer(bob, 50e18);
        assertEq(viaUSD.balanceOf(alice), 50e18);
        assertEq(viaUSD.balanceOf(bob), 50e18);
    }

    function test_transfer_revertIfFromBlacklisted() public {
        // Mint viaUSD to alice
        vm.prank(gateway);
        viaUSD.mint(alice, 100e18);

        // Blacklist alice
        viaUSD.addToBlacklist(alice);

        // Try to transfer from alice
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        viaUSD.transfer(bob, 50e18);
    }

    function test_transfer_revertIfToBlacklisted() public {
        // Mint viaUSD to alice
        vm.prank(gateway);
        viaUSD.mint(alice, 100e18);

        // Blacklist bob
        viaUSD.addToBlacklist(bob);

        // Try to transfer to bob
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", bob));
        viaUSD.transfer(bob, 50e18);
    }

    // --- transferFrom ---

    function test_transferFrom() public {
        // Mint viaUSD to alice
        vm.prank(gateway);
        viaUSD.mint(alice, 100e18);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        viaUSD.approve(bob, 100e18);
        assertEq(viaUSD.allowance(alice, bob), 100e18);

        // Bob transfers 40e18 from alice to carol
        vm.prank(bob);
        viaUSD.transferFrom(alice, carol, 40e18);

        // Check balances and allowance
        assertEq(viaUSD.balanceOf(alice), 60e18);
        assertEq(viaUSD.balanceOf(carol), 40e18);
        assertEq(viaUSD.allowance(alice, bob), 60e18);
    }

    function test_transferFrom_revertIfFromBlacklisted() public {
        // Mint viaUSD to alice
        vm.prank(gateway);
        viaUSD.mint(alice, 100e18);

        // Blacklist alice
        viaUSD.addToBlacklist(alice);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        viaUSD.approve(bob, 100e18);

        // Try to transferFrom alice
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", alice));
        viaUSD.transferFrom(alice, carol, 50e18);
    }

    function test_transferFrom_revertIfToBlacklisted() public {
        // Mint viaUSD to alice
        vm.prank(gateway);
        viaUSD.mint(alice, 100e18);

        // Blacklist carol
        viaUSD.addToBlacklist(carol);

        // Approve bob to spend alice's tokens
        vm.prank(alice);
        viaUSD.approve(bob, 100e18);

        // Try to transferFrom alice to carol
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Blacklisted(address)", carol));
        viaUSD.transferFrom(alice, carol, 50e18);
    }
}
