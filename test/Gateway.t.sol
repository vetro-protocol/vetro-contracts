// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {VUSD} from "src/VUSD.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockMorphoVaultV2} from "test/mocks/MockMorphoVaultV2.sol";

contract GatewayTest is Test {
    using SafeERC20 for IERC20;

    VUSD vusd;
    Gateway gateway;
    Treasury treasury;
    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address token;
    MockChainlinkOracle mockOracle;
    MockMorphoVaultV2 mockVault;

    function setUp() public {
        owner = address(this);
        vusd = new VUSD(owner);
        treasury = new Treasury(address(vusd));
        vusd.updateTreasury(address(treasury));

        gateway = new Gateway(address(vusd), type(uint256).max);
        vusd.updateGateway(address(gateway));

        token = address(new MockERC20());
        mockVault = new MockMorphoVaultV2(address(token));
        mockOracle = new MockChainlinkOracle(0.999e8);
        treasury.addToWhitelist(token, address(mockVault), address(mockOracle), 1 hours);
    }

    function mintVUSD(address user) internal returns (uint256) {
        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, user, amount);

        vm.startPrank(user);
        IERC20(token).forceApprove(address(gateway), amount);
        gateway.mint(token, amount, 1, user);
        vm.stopPrank();
        return vusd.balanceOf(user);
    }

    function parseAmount(uint256 fromAmount, address fromToken, address toToken) internal view returns (uint256) {
        if (fromToken == address(0)) {
            return (fromAmount * 10 ** IERC20Metadata(toToken).decimals());
        }
        return ((fromAmount * 10 ** IERC20Metadata(toToken).decimals()) / (10 ** IERC20Metadata(fromToken).decimals()));
    }

    // --- mint ---
    function test_mint() public {
        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, alice, amount);

        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);
        uint256 vusdAmount = parseAmount(amount, token, address(vusd));
        uint256 expectedVUSD = (latestPrice * vusdAmount) / unitPrice;

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), amount);
        gateway.mint(token, amount, expectedVUSD, address(this));
        vm.stopPrank();

        uint256 vusdBalance = vusd.balanceOf(address(this));
        assertEq(vusdBalance, expectedVUSD, "Incorrect VUSD minted");
    }

    function test_mint_withFee_whenPriceIsOneUSD() public {
        // set price to 1 for simple amount out calculation
        mockOracle.updatePrice(1e8);
        // set mint fee
        uint256 mintFee = 5;
        gateway.updateMintFee(mintFee);

        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, bob, amount);

        uint256 amountInVUSD = parseAmount(amount, token, address(vusd));
        uint256 expectedVUSD = amountInVUSD - ((amountInVUSD * mintFee) / gateway.MAX_BPS());
        uint256 sharesBefore = mockVault.balanceOf(address(treasury));

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), amount);
        gateway.mint(token, amount, expectedVUSD, address(this));
        vm.stopPrank();

        uint256 vusdBalance = vusd.balanceOf(address(this));
        assertEq(vusdBalance, expectedVUSD, "Incorrect VUSD minted");

        uint256 sharesAfter = mockVault.balanceOf(address(treasury));
        assertEq(sharesAfter, sharesBefore + mockVault.convertToShares(amount), "Incorrect token balance in treasury");
    }

    function test_mint_withFee_whenPriceIsBelowOneUSD() public {
        mockOracle.updatePrice(0.9998e8);
        // set mint fee
        uint256 mintFee = 5;
        gateway.updateMintFee(mintFee);

        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, bob, amount);

        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);

        uint256 amountInVUSD = parseAmount(amount, token, address(vusd));
        uint256 amountAfterFee = amountInVUSD - ((amountInVUSD * mintFee) / gateway.MAX_BPS());
        uint256 expectedVUSD = (amountAfterFee * latestPrice) / unitPrice;

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), amount);
        gateway.mint(token, amount, expectedVUSD, address(this));

        uint256 vusdBalance = vusd.balanceOf(address(this));
        assertEq(vusdBalance, expectedVUSD, "Incorrect VUSD minted");
        vm.stopPrank();
    }

    function test_mint_revertIfTokenIsUnsupported() public {
        uint256 amount = 1000;
        address token2 = makeAddr("token2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.mint(token2, amount, 1, alice);
    }

    function test_mint_revertIfMintableIsNotEnough() public {
        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, alice, amount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), amount);
        uint256 mintable = gateway.mintable(token, amount);
        vm.expectRevert(abi.encodeWithSignature("MintableIsLessThanMinimum(uint256,uint256)", mintable, mintable + 1));
        gateway.mint(token, amount, mintable + 1, bob);
        vm.stopPrank();
    }

    function test_mint_revertIfMintLimitReached() public {
        mockOracle.updatePrice(1e8);
        // update mint limit to 100 VUSD
        gateway.updateMintLimit(100e18);

        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, alice, amount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), amount);
        vm.expectRevert(abi.encodeWithSignature("MintLimitReached(uint256,uint256)", 100e18, 1000e18));
        gateway.mint(token, amount, 1, address(this));
        vm.stopPrank();
    }

    // --- mint only owner ---
    function test_mint_onlyOwner() public {
        uint256 amount = 1000e18; // 1000 VUSD
        uint256 initialSupply = vusd.totalSupply();
        assertEq(vusd.balanceOf(bob), 0, "Incorrect VUSD balance");
        gateway.mint(amount, bob);
        uint256 newSupply = vusd.totalSupply();
        assertEq(newSupply, initialSupply + amount, "owner should be able to mint VUSD");
        assertEq(vusd.balanceOf(bob), amount, "Incorrect VUSD balance");
    }

    function test_mint_onlyOwner_revertIfReceiverIsZeroAddress() public {
        vm.expectRevert(Gateway.AddressIsNull.selector);
        gateway.mint(100e18, address(0));
    }

    function test_mint_onlyOwner_revertItNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotOwner(address)", alice));
        gateway.mint(100e18, alice);
    }

    function test_mint_onlyOwner_revertItMintLimitReached() public {
        mockOracle.updatePrice(1e8);
        // update mint limit to 100 VUSD
        gateway.updateMintLimit(100e18);

        vm.expectRevert(abi.encodeWithSignature("MintLimitReached(uint256,uint256)", 100e18, 101e18));
        gateway.mint(101e18, bob);
    }

    // --- redeem ---
    function test_redeem_withDefaultRedeemFee_whenPriceIsAboveOneUSD() public {
        // set price to above 1
        mockOracle.updatePrice(1.01e8);
        uint256 vusdAmount = mintVUSD(alice);
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);

        uint256 vusdAfterFee = vusdAmount - ((vusdAmount * gateway.redeemFee()) / gateway.MAX_BPS());
        uint256 expectedRedeemable = parseAmount(((vusdAfterFee * unitPrice) / latestPrice), address(vusd), token);

        uint256 vusdBalanceBefore = vusd.balanceOf(alice);

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        gateway.redeem(token, vusdAmount, expectedRedeemable, alice);

        // assert that vusd balance decrease
        assertEq(vusd.balanceOf(alice), vusdBalanceBefore - vusdAmount, "VUSD balance should decrease");
        uint256 tokensReceived = IERC20(token).balanceOf(alice) - tokenBalanceBefore;
        assertEq(tokensReceived, expectedRedeemable, "token amount should be transferred to user");
    }

    function test_redeem_withRedeemFee_whenPriceIsOneUSD() public {
        // set price to 1 for simple amount out calculation
        mockOracle.updatePrice(1e8);
        // set redeem fee
        uint256 redeemFee = 50; // 0.5%
        gateway.updateRedeemFee(redeemFee);

        uint256 vusdAmount = mintVUSD(alice);
        uint256 vusdAmountAfterFee = vusdAmount - ((vusdAmount * redeemFee) / gateway.MAX_BPS());
        uint256 expectedRedeemable = parseAmount(vusdAmountAfterFee, address(vusd), token);

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);

        vm.prank(alice);
        gateway.redeem(token, vusdAmount, expectedRedeemable, alice);

        uint256 tokensReceived = IERC20(token).balanceOf(alice) - tokenBalanceBefore;
        assertEq(tokensReceived, expectedRedeemable, "Recipient should receive correct token amount");
    }

    function test_redeem_revertIfTokenIsUnsupported() public {
        uint256 amount = 1000;
        address token2 = makeAddr("token2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.redeem(token2, amount, 1, alice);
    }

    function test_redeem_revertIfRedeemableIsNotEnough() public {
        uint256 vusdAmount = mintVUSD(bob);
        uint256 redeemable = gateway.redeemable(token, vusdAmount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("RedeemableIsLessThanMinimum(uint256,uint256)", redeemable, redeemable + 1)
        );
        gateway.redeem(token, vusdAmount, redeemable + 1, bob);
    }

    // --- mintable ---
    function test_mintable_whenPriceIsAboveOneUSD() public {
        gateway.updateMintFee(0);
        mockOracle.updatePrice(1.0001e8);

        uint256 amount = parseAmount(100, address(0), token);
        uint256 expectedMintable = parseAmount(amount, token, address(vusd));

        uint256 actualMintable = gateway.mintable(token, amount);
        assertEq(actualMintable, expectedMintable, "Incorrect mintable");
    }

    function test_mintable_whenPriceIsBelowOneUSD() public {
        mockOracle.updatePrice(0.9998e8);
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);

        uint256 amount = parseAmount(100, address(0), token);
        uint256 amountAfterFee = amount - ((amount * gateway.mintFee()) / gateway.MAX_BPS());
        uint256 vusdAmount = parseAmount(amountAfterFee, token, address(vusd));
        uint256 expectedMintable = (vusdAmount * latestPrice) / unitPrice;

        uint256 actualMintable = gateway.mintable(token, amount);
        assertEq(actualMintable, expectedMintable, "Incorrect mintable");
    }

    function test_mintable_returnZeroForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        uint256 actualMintable = gateway.mintable(token2, 100e18);
        assertEq(actualMintable, 0, "Incorrect mintable");
    }

    function test_mintable_returnZeroIfMintLimitReached() public {
        mockOracle.updatePrice(1e8);
        gateway.updateMintLimit(50e18);
        uint256 amount = parseAmount(100, address(0), token);
        uint256 mintable = gateway.mintable(token, amount);
        assertEq(mintable, 0, "Incorrect mintable");
    }

    function test_redeemable_whenPriceIsAboveOneUSD() public {
        mockOracle.updatePrice(1.001e8);
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);

        uint256 vusdAmount = mintVUSD(bob);
        uint256 vusdAfterFee = vusdAmount - ((vusdAmount * gateway.redeemFee()) / gateway.MAX_BPS());
        uint256 expectedRedeemable = parseAmount(((vusdAfterFee * unitPrice) / latestPrice), address(vusd), token);

        uint256 actualRedeemable = gateway.redeemable(token, vusdAmount);
        assertEq(actualRedeemable, expectedRedeemable, "Incorrect redeemable");
    }

    function test_redeemable_whenPriceIsBelowOneUSD() public {
        gateway.updateRedeemFee(0);
        mockOracle.updatePrice(0.9998e8);

        uint256 vusdAmount = mintVUSD(bob);
        uint256 expectedRedeemable = parseAmount(vusdAmount, address(vusd), token);

        uint256 actualRedeemable = gateway.redeemable(token, vusdAmount);
        assertEq(actualRedeemable, expectedRedeemable, "Incorrect redeemable");
    }

    function test_redeemable_returnZeroForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        uint256 actualRedeemable = gateway.redeemable(token2, 100e18);
        assertEq(actualRedeemable, 0, "Incorrect redeemable");
    }

    // --- update mint limit ---
    function test_updateMintLimit() public {
        uint256 newMintLimit = 1000 ether; // amount in VUSD decimal
        gateway.updateMintLimit(newMintLimit);
        assertEq(gateway.mintLimit(), newMintLimit, "Mint limit should be updated");
    }

    function test_updateMintLimit_revertIfNotOwner() public {
        uint256 newMintLimit = 1000 ether; // amount in VUSD decimal
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotOwner(address)", bob));
        gateway.updateMintLimit(newMintLimit);
    }

    // --- update mint fee ---
    function test_updateMintFee() public {
        uint256 newFee = 500;
        gateway.updateMintFee(newFee);
        assertEq(gateway.mintFee(), newFee, "Mint fee should be updated");
    }

    function test_updateMintFee_revertIfNotOwner() public {
        uint256 newFee = 500;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotOwner(address)", bob));
        gateway.updateMintFee(newFee);
    }

    function test_updateMintFee_revertIfFeeIsHigherThanMax() public {
        uint256 newFee = 10001;
        vm.expectRevert(abi.encodeWithSignature("InvalidMintFee(uint256)", newFee));
        gateway.updateMintFee(newFee);
    }

    // --- update redeem fee ---
    function test_updateRedeemFee() public {
        uint256 newFee = 500;
        gateway.updateRedeemFee(newFee);
        assertEq(gateway.redeemFee(), newFee, "Redeem fee should be updated");
    }

    function test_updateRedeemFee_revertIfNotOwner() public {
        uint256 newFee = 500;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotOwner(address)", bob));
        gateway.updateRedeemFee(newFee);
    }

    function test_updateRedeemFee_revertIfFeeIsHigherThanMax() public {
        uint256 newFee = 10001;
        vm.expectRevert(abi.encodeWithSignature("InvalidRedeemFee(uint256)", newFee));
        gateway.updateRedeemFee(newFee);
    }
}
