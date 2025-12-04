// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {Viat} from "src/Viat.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockYieldVault} from "test/mocks/MockYieldVault.sol";

contract GatewayTest is Test {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// forge-lint: disable-next-line(mixed-case-variable)
    Viat viaUSD;
    Gateway gateway;
    Treasury treasury;
    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address token;
    MockChainlinkOracle mockOracle;
    MockYieldVault mockVault;

    function setUp() public {
        owner = address(this);
        viaUSD = new Viat("viaUSD", "viaUSD", owner);
        treasury = new Treasury(address(viaUSD));
        viaUSD.updateTreasury(address(treasury));

        gateway = new Gateway(address(viaUSD), type(uint256).max);
        viaUSD.updateGateway(address(gateway));

        token = address(new MockERC20());
        mockVault = new MockYieldVault(address(token));
        mockOracle = new MockChainlinkOracle(0.999e8);
        treasury.addToWhitelist(token, address(mockVault), address(mockOracle), 1 hours);
    }

    function mintViaUSD(address user, uint256 viaUsdAmount) internal returns (uint256) {
        uint256 tokenAmount = gateway.previewMint(token, viaUsdAmount);
        deal(token, user, tokenAmount);

        vm.startPrank(user);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.mint(token, viaUsdAmount, tokenAmount, user);
        vm.stopPrank();
        return viaUSD.balanceOf(user);
    }

    function parseAmount(uint256 fromAmount, address fromToken, address toToken) internal view returns (uint256) {
        if (fromToken == address(0)) {
            return (fromAmount * 10 ** IERC20Metadata(toToken).decimals());
        }
        return ((fromAmount * 10 ** IERC20Metadata(toToken).decimals()) / (10 ** IERC20Metadata(fromToken).decimals()));
    }

    // --- deposit ---
    function testFuzz_deposit(int256 price, uint256 mintFee, uint256 tokenAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_BPS() - 1);
        tokenAmount = bound(tokenAmount, 0, type(uint128).max);
        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(mintFee);
        deal(token, bob, tokenAmount);

        uint256 expectedViaUsd = gateway.previewDeposit(token, tokenAmount);
        uint256 sharesBefore = mockVault.balanceOf(address(treasury));

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.deposit(token, tokenAmount, expectedViaUsd, bob);
        vm.stopPrank();

        assertEq(viaUSD.balanceOf(bob), expectedViaUsd, "Incorrect viaUSD minted");

        uint256 sharesAfter = mockVault.balanceOf(address(treasury));
        assertEq(sharesAfter, sharesBefore + mockVault.convertToShares(tokenAmount), "Incorrect shares in treasury");
    }

    function test_deposit_revertIfTokenIsUnsupported() public {
        uint256 amount = 1000;
        address token2 = address(new MockERC20());
        deal(token2, alice, amount);

        vm.startPrank(alice);
        IERC20(token2).forceApprove(address(gateway), amount);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.deposit(token2, amount, 1, alice);
        vm.stopPrank();
    }

    function test_deposit_revertIfMintableIsNotEnough() public {
        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, alice, amount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), amount);
        uint256 mintable = gateway.previewDeposit(token, amount);
        vm.expectRevert(abi.encodeWithSignature("MintableIsLessThanMinimum(uint256,uint256)", mintable, mintable + 1));
        gateway.deposit(token, amount, mintable + 1, bob);
        vm.stopPrank();
    }

    function test_deposit_revertIfExceededMaxMint() public {
        mockOracle.updatePrice(1e8);
        // update mint limit to 100 viaUSD
        gateway.updateMintLimit(100e18);

        uint256 amount = parseAmount(1000, address(0), token);
        deal(token, alice, amount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), amount);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxMint(uint256,uint256)", 1000e18, 100e18));
        gateway.deposit(token, amount, 1, address(this));
        vm.stopPrank();
    }

    function test_deposit_revertIfTokenHasFeeOnTransfer() public {
        MockERC20(token).setHasFeeOnTransfer(true);
        uint256 amt = 1_000_000; // 1 token with 6 decimals
        deal(address(token), address(this), amt);
        MockERC20(token).approve(address(gateway), amt);

        vm.expectRevert(abi.encodeWithSignature("FeeOnTransferToken(address)", address(token)));
        gateway.deposit(address(token), amt, 0, address(this));
    }

    // --- mint only owner ---
    function test_mint_onlyOwner() public {
        // add tokens in Treasury to build reserve. Token has 6 decimals.
        deal(address(token), address(treasury), 10000e6);

        uint256 amount = 1000e18; // 1000 viaUSD
        uint256 initialSupply = viaUSD.totalSupply();
        assertEq(viaUSD.balanceOf(bob), 0, "Incorrect viaUSD balance");
        gateway.mint(amount, bob);
        uint256 newSupply = viaUSD.totalSupply();
        assertEq(newSupply, initialSupply + amount, "owner should be able to mint viaUSD");
        assertEq(viaUSD.balanceOf(bob), amount, "Incorrect viaUSD balance");
    }

    function test_mint_onlyOwner_revertIfReceiverIsZeroAddress() public {
        vm.expectRevert(Gateway.AddressIsNull.selector);
        gateway.mint(100e18, address(0));
    }

    function test_mint_onlyOwner_revertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerIsNotOwner(address)", alice));
        gateway.mint(100e18, alice);
    }

    function test_mint_onlyOwner_revertIfNoExcessReserve() public {
        mockOracle.updatePrice(1e8);
        // mint 50 viaUSD
        vm.prank(address(gateway));
        viaUSD.mint(alice, 50e18);
        // add 40 tokens in Treasury to build reserve. Token has 6 decimals.
        deal(address(token), address(treasury), 40e6);

        vm.expectRevert(abi.encodeWithSignature("NoExcessReserve(uint256,uint256)", 40e18, 50e18));
        gateway.mint(1e18, bob);
    }

    function test_mint_onlyOwner_revertIfExceededExcessReserve() public {
        mockOracle.updatePrice(1e8);
        // add tokens in Treasury to build reserve. Token has 6 decimals.
        deal(address(token), address(treasury), 100e6);

        vm.expectRevert(abi.encodeWithSignature("ExceededExcessReserve(uint256,uint256)", 101e18, 100e18));
        gateway.mint(101e18, bob);
    }

    function test_mint_onlyOwner_revertIfExceededMaxMint() public {
        mockOracle.updatePrice(1e8);
        // add tokens in Treasury to build reserve. Token has 6 decimals.
        deal(address(token), address(treasury), 200e6);

        // update mint limit to 100 viaUSD
        gateway.updateMintLimit(100e18);

        vm.expectRevert(abi.encodeWithSignature("ExceededMaxMint(uint256,uint256)", 101e18, 100e18));
        gateway.mint(101e18, bob);
    }

    // --- mint ---
    function testFuzz_mint(int256 price, uint256 mintFee, uint256 viaUsdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_BPS() - 1);
        viaUsdAmount = bound(viaUsdAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(mintFee);

        uint256 tokenAmount = gateway.previewMint(token, viaUsdAmount);
        deal(token, bob, tokenAmount);

        uint256 viaUsdBalanceBefore = viaUSD.balanceOf(bob);
        uint256 sharesBefore = mockVault.balanceOf(address(treasury));

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.mint(token, viaUsdAmount, tokenAmount, bob);
        vm.stopPrank();

        // Verify viaUSD minted
        assertEq(viaUSD.balanceOf(bob), viaUsdBalanceBefore + viaUsdAmount, "Incorrect viaUSD minted");

        // Verify tokens deposited in vault
        uint256 sharesAfter = mockVault.balanceOf(address(treasury));
        assertEq(sharesAfter, sharesBefore + mockVault.convertToShares(tokenAmount), "Incorrect shares in treasury");
    }

    function test_mint_revertIfTokenIsUnsupported() public {
        uint256 viaUsdAmount = 1000e18;
        address token2 = address(new MockERC20());
        uint256 tokenAmount = gateway.previewMint(token, viaUsdAmount);
        deal(token2, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token2).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.mint(token2, viaUsdAmount, tokenAmount, alice);
        vm.stopPrank();
    }

    function test_mint_revertIfTokenAmountIsHigherThanMax() public {
        uint256 viaUsdAmount = 1000e18;
        uint256 tokenAmount = gateway.previewMint(token, viaUsdAmount);
        deal(token, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(
            abi.encodeWithSignature("TokenAmountIsHigherThanMax(uint256,uint256)", tokenAmount, tokenAmount - 1)
        );
        gateway.mint(token, viaUsdAmount, tokenAmount - 1, alice);
        vm.stopPrank();
    }

    function test_mint_revertIfExceededMaxMint() public {
        // Set mint limit to 100 viaUSD
        gateway.updateMintLimit(100e18);

        uint256 viaUsdAmount = 101e18; // Try to mint more than limit
        uint256 tokenAmount = gateway.previewMint(token, viaUsdAmount);
        deal(token, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxMint(uint256,uint256)", viaUsdAmount, 100e18));
        gateway.mint(token, viaUsdAmount, tokenAmount, alice);
        vm.stopPrank();
    }

    // --- redeem ---
    function testFuzz_redeem(int256 price, uint256 redeemFee, uint256 viaUsdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        redeemFee = bound(redeemFee, 0, gateway.MAX_BPS() - 1);
        viaUsdAmount = bound(viaUsdAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Mint viaUSD for testing
        mintViaUSD(alice, viaUsdAmount);

        uint256 expectedToken = gateway.previewRedeem(token, viaUsdAmount);
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);
        uint256 viaUsdBalanceBefore = viaUSD.balanceOf(alice);

        vm.prank(alice);
        gateway.redeem(token, viaUsdAmount, expectedToken, alice);

        assertEq(viaUSD.balanceOf(alice), viaUsdBalanceBefore - viaUsdAmount, "viaUSD balance should decrease");
        assertEq(IERC20(token).balanceOf(alice) - tokenBalanceBefore, expectedToken, "Incorrect tokens received");
    }

    function test_redeem_revertIfTokenIsUnsupported() public {
        uint256 amount = 1000;
        address token2 = makeAddr("token2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.redeem(token2, amount, 1, alice);
    }

    function test_redeem_revertIfRedeemableIsNotEnough() public {
        uint256 viaUsdAmount = mintViaUSD(bob, 100e18);
        uint256 redeemable = gateway.previewRedeem(token, viaUsdAmount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("RedeemableIsLessThanMinimum(uint256,uint256)", redeemable, redeemable + 1)
        );
        gateway.redeem(token, viaUsdAmount, redeemable + 1, bob);
    }

    function test_redeem_revertIfExceededMaxWithdraw() public {
        uint256 viaUsdAmount = 100e18;
        // mint viaUSD directly, it is not backed by collateral
        vm.prank(address(gateway));
        viaUSD.mint(bob, viaUsdAmount);

        uint256 tokenAmount = gateway.previewRedeem(token, viaUsdAmount);
        uint256 maxWithdraw = gateway.maxWithdraw(token);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxWithdraw(uint256,uint256)", tokenAmount, maxWithdraw));
        gateway.redeem(token, viaUsdAmount, tokenAmount, bob);
    }

    // --- withdraw ---
    function testFuzz_withdraw(int256 price, uint256 redeemFee, uint256 tokenAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        redeemFee = bound(redeemFee, 0, gateway.MAX_BPS() - 1);
        tokenAmount = bound(tokenAmount, 0, type(uint128).max);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Mint viaUSD for testing
        uint256 viaUsdAmount = gateway.previewWithdraw(token, tokenAmount);
        mintViaUSD(alice, viaUsdAmount);

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);
        uint256 viaUsdBalanceBefore = viaUSD.balanceOf(alice);

        vm.prank(alice);
        gateway.withdraw(token, tokenAmount, viaUsdAmount, alice);

        assertEq(viaUSD.balanceOf(alice), viaUsdBalanceBefore - viaUsdAmount, "viaUSD balance should decrease");
        assertEq(IERC20(token).balanceOf(alice) - tokenBalanceBefore, tokenAmount, "Incorrect tokens received");
    }

    function test_withdraw_revertIfTokenIsUnsupported() public {
        uint256 amount = 1000;
        address token2 = makeAddr("token2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.withdraw(token2, amount, 1, alice);
    }

    function test_withdraw_revertIfViatAmountIsHigherThanMax() public {
        uint256 tokenAmount = 1000e6;
        uint256 viaUsdAmount = gateway.previewWithdraw(token, tokenAmount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("ViatToBurnIsHigherThanMax(uint256,uint256)", viaUsdAmount, viaUsdAmount - 1)
        );
        gateway.withdraw(token, tokenAmount, viaUsdAmount - 1, bob);
    }

    function test_withdraw_revertIfExceededMaxWithdraw() public {
        uint256 tokenAmount = 1000e6;
        uint256 viaUsdAmount = gateway.previewWithdraw(token, tokenAmount);
        uint256 maxWithdraw = gateway.maxWithdraw(token);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxWithdraw(uint256,uint256)", tokenAmount, maxWithdraw));
        gateway.withdraw(token, tokenAmount, viaUsdAmount, bob);
    }

    // --- previewDeposit ---
    function testFuzz_previewDeposit(int256 price, uint256 mintFee, uint256 amount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_BPS() - 1);
        amount = bound(amount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(mintFee);

        // Calculate expected viaUSD amount
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);
        uint256 maxBps = gateway.MAX_BPS();
        uint256 amountAfterFee = amount.mulDiv((maxBps - gateway.mintFee()), maxBps);
        uint256 expectedViaUsd = latestPrice >= unitPrice
            ? parseAmount(amountAfterFee, token, address(viaUSD))
            : parseAmount(amountAfterFee.mulDiv(latestPrice, unitPrice), token, address(viaUSD));

        uint256 actualViaUsd = gateway.previewDeposit(token, amount);
        assertEq(actualViaUsd, expectedViaUsd, "Incorrect viaUSD amount");
    }

    function test_previewDeposit_revertForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewDeposit(token2, 100e18);
    }

    // --- previewMint ---
    function testFuzz_previewMint(int256 price, uint256 mintFee, uint256 viaUsdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_BPS() - 1);
        viaUsdAmount = bound(viaUsdAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(mintFee);

        // Calculate expected token amount
        uint256 oneToken = parseAmount(1, address(0), token);
        uint256 viaUsdForOneToken = gateway.previewDeposit(token, oneToken);
        uint256 expectedToken = viaUsdAmount.mulDiv(oneToken, viaUsdForOneToken, Math.Rounding.Ceil);

        uint256 actualToken = gateway.previewMint(token, viaUsdAmount);
        assertEq(actualToken, expectedToken, "Incorrect token amount");
    }

    function test_previewMint_revertForUnsupportedToken() public {
        address token2 = address(new MockERC20());
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewMint(token2, 100e18);
    }

    // --- previewRedeem ---
    function testFuzz_previewRedeem(int256 price, uint256 redeemFee, uint256 viaUsdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8); // Price within 0.2% of $1
        redeemFee = bound(redeemFee, 0, gateway.MAX_BPS() - 1);
        viaUsdAmount = bound(viaUsdAmount, 0, type(uint256).max / 1e18);
        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Calculate expected token amount
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);
        uint256 maxBps = gateway.MAX_BPS();
        uint256 viaUsdAfterFee = viaUsdAmount.mulDiv((maxBps - gateway.redeemFee()), maxBps);
        uint256 expectedToken = latestPrice <= unitPrice
            ? parseAmount(viaUsdAfterFee, address(viaUSD), token)
            : parseAmount(viaUsdAfterFee.mulDiv(unitPrice, latestPrice), address(viaUSD), token);

        uint256 actualToken = gateway.previewRedeem(token, viaUsdAmount);
        assertEq(actualToken, expectedToken, "Incorrect token amount");
    }

    function test_previewRedeem_revertForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewRedeem(token2, 100e18);
    }

    // --- previewWithdraw ---
    function testFuzz_previewWithdraw(int256 price, uint256 redeemFee, uint256 tokenAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        redeemFee = bound(redeemFee, 0, gateway.MAX_BPS() - 1);
        tokenAmount = bound(tokenAmount, 0, type(uint128).max);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Calculate expected viaUSD amount
        uint256 oneViaUsd = parseAmount(1, address(0), address(viaUSD));
        uint256 tokenForOneViaUsd = gateway.previewRedeem(token, oneViaUsd);
        uint256 expectedViaUsd = tokenAmount.mulDiv(oneViaUsd, tokenForOneViaUsd, Math.Rounding.Ceil);

        uint256 actualViaUsd = gateway.previewWithdraw(token, tokenAmount);
        assertEq(actualViaUsd, expectedViaUsd, "Incorrect viaUSD amount");
    }

    function test_previewWithdraw_revertForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewWithdraw(token2, 100e6);
    }

    // --- update mint limit ---
    function test_updateMintLimit() public {
        uint256 newMintLimit = 1000 ether; // amount in viaUSD decimal
        gateway.updateMintLimit(newMintLimit);
        assertEq(gateway.mintLimit(), newMintLimit, "Mint limit should be updated");
    }

    function test_updateMintLimit_revertIfNotOwner() public {
        uint256 newMintLimit = 1000 ether; // amount in viaUSD decimal
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

    function test_maxDeposit() public view {
        assertEq(gateway.maxDeposit(), type(uint256).max);
    }

    function test_maxMint() public {
        // With zero supply
        gateway.updateMintLimit(100e18);
        assertEq(gateway.maxMint(), 100e18);
        // Increase total supply via owner mint
        vm.prank(address(gateway));
        viaUSD.mint(address(this), 60e18);
        assertEq(gateway.maxMint(), 40e18);
        // Set limit below current supply → zero
        gateway.updateMintLimit(10e18);
        assertEq(gateway.maxMint(), 0);
    }

    function test_maxRedeem() public {
        // With zero balance
        assertEq(gateway.maxRedeem(alice), 0);
        // mint 50 viaUSD to alice
        vm.prank(address(gateway));
        viaUSD.mint(alice, 50e18);
        assertEq(gateway.maxRedeem(alice), 50e18);
    }

    function test_maxWithdraw() public {
        assertEq(gateway.maxWithdraw(token), 0);

        deal(address(token), address(treasury), 50e18);
        assertEq(gateway.maxWithdraw(token), 50e18);
    }

    function test_owner_and_treasury_views() public view {
        assertEq(gateway.owner(), owner);
        assertEq(gateway.treasury(), address(treasury));
    }
}
