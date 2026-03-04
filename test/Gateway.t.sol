// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockYieldVault} from "test/mocks/MockYieldVault.sol";

contract GatewayTest is Test {
    using SafeERC20 for IERC20;
    using Math for uint256;

    PeggedToken VUSD;
    Gateway gateway;
    Treasury treasury;
    address owner;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address token;
    MockChainlinkOracle mockOracle;
    MockYieldVault mockVault;

    function setUp() public {
        owner = address(this);
        VUSD = new PeggedToken("VUSD", "VUSD", owner);
        treasury = new Treasury(address(VUSD), admin);
        VUSD.updateTreasury(address(treasury));

        // Deploy Gateway implementation
        Gateway implementation = new Gateway();

        // Deploy proxy and initialize
        bytes memory initData =
            abi.encodeWithSelector(Gateway.initialize.selector, address(VUSD), type(uint256).max, 7 days);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        gateway = Gateway(address(proxy));

        VUSD.updateGateway(address(gateway));

        token = address(new MockERC20());
        mockVault = new MockYieldVault(address(token));
        mockOracle = new MockChainlinkOracle(0.999e8);

        vm.startPrank(admin);
        treasury.addToWhitelist(token, address(mockVault), address(mockOracle), 1 hours);
        treasury.grantRole(treasury.UMM_ROLE(), owner);
        vm.stopPrank();
    }

    function mintPeggedToken(address user, uint256 VUSDAmount) internal returns (uint256) {
        uint256 tokenAmount = gateway.previewMint(token, VUSDAmount);
        deal(token, user, tokenAmount);

        vm.startPrank(user);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.mint(token, VUSDAmount, tokenAmount, user);
        vm.stopPrank();
        return VUSD.balanceOf(user);
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
        mintFee = bound(mintFee, 0, gateway.MAX_FEE_BPS());
        tokenAmount = bound(tokenAmount, 0, type(uint128).max);
        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(token, mintFee);
        deal(token, bob, tokenAmount);

        uint256 expectedPeggedToken = gateway.previewDeposit(token, tokenAmount);
        uint256 sharesBefore = mockVault.balanceOf(address(treasury));

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.deposit(token, tokenAmount, expectedPeggedToken, bob);
        vm.stopPrank();

        assertEq(VUSD.balanceOf(bob), expectedPeggedToken, "Incorrect PeggedToken minted");

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

    function test_deposit_revertIfMaxMintExceeded() public {
        mockOracle.updatePrice(1e8);
        // update mint limit to 100 PEGGED_TOKEN
        vm.prank(admin);
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

    // --- mint only UMM role ---
    function test_mintToAMO_onlyUMMRole() public {
        // add tokens in Treasury to build reserve. Token has 6 decimals.
        deal(address(token), address(treasury), 10000e6);

        // Set AMO mint limit
        vm.prank(admin);
        gateway.updateAmoMintLimit(2000e18);

        uint256 amount = 1000e18; // 1000 PeggedToken
        uint256 initialSupply = VUSD.totalSupply();
        assertEq(VUSD.balanceOf(bob), 0, "Incorrect PeggedToken balance");
        gateway.mintToAMO(amount, bob);
        uint256 newSupply = VUSD.totalSupply();
        assertEq(newSupply, initialSupply + amount, "UMM role should be able to mint PeggedToken");
        assertEq(VUSD.balanceOf(bob), amount, "Incorrect PeggedToken balance");
    }

    function test_mintToAMO_onlyUMMRole_revertIfReceiverIsZeroAddress() public {
        vm.expectRevert(Gateway.AddressIsZero.selector);
        gateway.mintToAMO(100e18, address(0));
    }

    function test_mintToAMO_onlyUMMRole_revertIfNotAuthorized() public {
        bytes32 _role = treasury.UMM_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, _role));
        gateway.mintToAMO(100e18, alice);
    }

    function test_mintToAMO_onlyUMMRole_revertIfAmoMintLimitExceeded() public {
        // Set AMO mint limit to 10 PeggedToken
        vm.prank(admin);
        gateway.updateAmoMintLimit(10e18);

        // Try to mint more than the limit
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxMint(uint256,uint256)", 11e18, 10e18));
        gateway.mintToAMO(11e18, bob);
    }

    function test_mintToAMO_onlyUMMRole_amoLimitIndependentOfUserLimit() public {
        mockOracle.updatePrice(1e8);
        // add tokens in Treasury to build reserve. Token has 6 decimals.
        deal(address(token), address(treasury), 200e6);

        // Set AMO mint limit high enough
        vm.prank(admin);
        gateway.updateAmoMintLimit(200e18);

        // update user mint limit to 100 PeggedToken (lower than AMO limit)
        vm.prank(admin);
        gateway.updateMintLimit(100e18);

        // AMO should still be able to mint up to its own limit (200e18), not constrained by user mintLimit
        gateway.mintToAMO(101e18, bob);
        assertEq(VUSD.balanceOf(bob), 101e18, "AMO mint should succeed regardless of user userMintLimit");
    }

    // --- burnFromAMO ---
    function test_burnFromAMO_onlyUMMRole_success() public {
        // Setup: mint AMO tokens
        vm.prank(admin);
        gateway.updateAmoMintLimit(500e18);
        gateway.mintToAMO(300e18, address(this));

        uint256 initialTotalSupply = VUSD.totalSupply();
        uint256 initialAmoSupply = gateway.amoSupply();
        assertEq(initialAmoSupply, 300e18, "Initial AMO supply should be 300");

        // Burn 100 tokens from owner
        uint256 burnAmount = 100e18;
        gateway.burnFromAMO(burnAmount);

        assertEq(VUSD.totalSupply(), initialTotalSupply - burnAmount, "Total supply should decrease");
        assertEq(gateway.amoSupply(), initialAmoSupply - burnAmount, "AMO supply should decrease");
    }

    function test_burnFromAMO_onlyUMMRole_burnAll() public {
        // Setup: mint AMO tokens
        vm.prank(admin);
        gateway.updateAmoMintLimit(500e18);
        gateway.mintToAMO(300e18, address(this));

        // Burn all AMO supply
        gateway.burnFromAMO(300e18);

        assertEq(gateway.amoSupply(), 0, "AMO supply should be zero after burning all");
    }

    function test_burnFromAMO_onlyUMMRole_revertIfNotAuthorized() public {
        bytes32 _role = treasury.UMM_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, _role));
        gateway.burnFromAMO(100e18);
    }

    function test_burnFromAMO_onlyUMMRole_revertIfExceedsAmoSupply() public {
        // Setup: mint some AMO tokens
        vm.prank(admin);
        gateway.updateAmoMintLimit(500e18);
        gateway.mintToAMO(100e18, address(this));

        // Approve more than we have minted
        uint256 burnAmount = 150e18;
        // Mint additional regular tokens so we have enough balance, but AMO supply is only 100
        vm.prank(address(gateway));
        VUSD.mint(address(this), 50e18);

        VUSD.approve(address(gateway), burnAmount);
        // Should revert because burn amount exceeds AMO supply, even though we have token balance
        vm.expectRevert(abi.encodeWithSignature("AmoBurnExceedsSupply(uint256,uint256)", burnAmount, 100e18));
        gateway.burnFromAMO(burnAmount);
    }

    function test_burnFromAMO_onlyUMMRole_revertIfZeroAmoSupply() public {
        // Mint some regular tokens (not AMO) to test contract
        vm.prank(address(gateway));
        VUSD.mint(address(this), 100e18);

        // Try to burn when AMO supply is zero
        uint256 burnAmount = 100e18;
        vm.expectRevert(abi.encodeWithSignature("AmoBurnExceedsSupply(uint256,uint256)", burnAmount, 0));
        gateway.burnFromAMO(burnAmount);
    }

    // --- mint ---
    function testFuzz_mint(int256 price, uint256 mintFee, uint256 VUSDAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_FEE_BPS());
        VUSDAmount = bound(VUSDAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(token, mintFee);

        uint256 tokenAmount = gateway.previewMint(token, VUSDAmount);
        deal(token, bob, tokenAmount);

        uint256 VUSDBalanceBefore = VUSD.balanceOf(bob);
        uint256 sharesBefore = mockVault.balanceOf(address(treasury));

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.mint(token, VUSDAmount, tokenAmount, bob);
        vm.stopPrank();

        // Verify PeggedToken minted
        assertEq(VUSD.balanceOf(bob), VUSDBalanceBefore + VUSDAmount, "Incorrect PeggedToken minted");

        // Verify tokens deposited in vault
        uint256 sharesAfter = mockVault.balanceOf(address(treasury));
        assertEq(sharesAfter, sharesBefore + mockVault.convertToShares(tokenAmount), "Incorrect shares in treasury");
    }

    function test_mint_revertIfTokenIsUnsupported() public {
        uint256 VUSDAmount = 1000e18;
        address token2 = address(new MockERC20());
        uint256 tokenAmount = gateway.previewMint(token, VUSDAmount);
        deal(token2, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token2).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.mint(token2, VUSDAmount, tokenAmount, alice);
        vm.stopPrank();
    }

    function test_mint_revertIfExcessiveInput() public {
        uint256 VUSDAmount = 1000e18;
        uint256 tokenAmount = gateway.previewMint(token, VUSDAmount);
        deal(token, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(
            abi.encodeWithSignature("TokenAmountIsHigherThanMax(uint256,uint256)", tokenAmount, tokenAmount - 1)
        );
        gateway.mint(token, VUSDAmount, tokenAmount - 1, alice);
        vm.stopPrank();
    }

    function test_mint_revertIfMaxMintExceeded() public {
        // Set mint limit to 100 PeggedToken
        vm.prank(admin);
        gateway.updateMintLimit(100e18);

        uint256 VUSDAmount = 101e18; // Try to mint more than limit
        uint256 tokenAmount = gateway.previewMint(token, VUSDAmount);
        deal(token, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxMint(uint256,uint256)", VUSDAmount, 100e18));
        gateway.mint(token, VUSDAmount, tokenAmount, alice);
        vm.stopPrank();
    }

    // --- redeem ---
    function testFuzz_redeem(int256 price, uint256 redeemFee, uint256 VUSDAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        redeemFee = bound(redeemFee, 0, gateway.MAX_FEE_BPS());
        VUSDAmount = bound(VUSDAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        gateway.setWithdrawalDelayEnabled(false); // Disable withdrawal delay for instant redeem
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(token, redeemFee);

        // Mint PeggedToken for testing
        mintPeggedToken(alice, VUSDAmount);

        uint256 expectedToken = gateway.previewRedeem(token, VUSDAmount);
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);
        uint256 VUSDBalanceBefore = VUSD.balanceOf(alice);

        vm.prank(alice);
        gateway.redeem(token, VUSDAmount, expectedToken, alice);

        assertEq(VUSD.balanceOf(alice), VUSDBalanceBefore - VUSDAmount, "PeggedToken balance should decrease");
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
        uint256 VUSDAmount = mintPeggedToken(bob, 100e18);
        uint256 redeemable = gateway.previewRedeem(token, VUSDAmount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("RedeemableIsLessThanMinimum(uint256,uint256)", redeemable, redeemable + 1)
        );
        gateway.redeem(token, VUSDAmount, redeemable + 1, bob);
    }

    function test_redeem_revertIfMaxWithdrawExceeded() public {
        uint256 VUSDAmount = 100e18;
        // mint VUSD directly, it is not backed by collateral
        vm.prank(address(gateway));
        VUSD.mint(bob, VUSDAmount);

        // Whitelist bob to bypass withdrawal delay
        gateway.addToInstantRedeemWhitelist(bob);

        uint256 tokenAmount = gateway.previewRedeem(token, VUSDAmount);
        uint256 maxWithdraw = gateway.maxWithdraw(token);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxWithdraw(uint256,uint256)", tokenAmount, maxWithdraw));
        gateway.redeem(token, VUSDAmount, tokenAmount, bob);
    }

    // --- withdraw ---
    function testFuzz_withdraw(int256 price, uint256 redeemFee, uint256 tokenAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        redeemFee = bound(redeemFee, 0, gateway.MAX_FEE_BPS());
        tokenAmount = bound(tokenAmount, 0, type(uint128).max);

        // Setup test conditions
        gateway.setWithdrawalDelayEnabled(false); // Disable withdrawal delay for instant withdraw
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(token, redeemFee);

        // Mint PeggedToken for testing
        uint256 VUSDAmount = gateway.previewWithdraw(token, tokenAmount);
        mintPeggedToken(alice, VUSDAmount);

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);
        uint256 VUSDBalanceBefore = VUSD.balanceOf(alice);

        vm.prank(alice);
        gateway.withdraw(token, tokenAmount, VUSDAmount, alice);

        assertEq(VUSD.balanceOf(alice), VUSDBalanceBefore - VUSDAmount, "PeggedToken balance should decrease");
        assertEq(IERC20(token).balanceOf(alice) - tokenBalanceBefore, tokenAmount, "Incorrect tokens received");
    }

    function test_withdraw_revertIfTokenIsUnsupported() public {
        uint256 amount = 1000;
        address token2 = makeAddr("token2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.withdraw(token2, amount, 1, alice);
    }

    function test_withdraw_revertIfPeggedExcessiveInput() public {
        uint256 tokenAmount = 1000e6;
        uint256 VUSDAmount = gateway.previewWithdraw(token, tokenAmount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("PeggedTokenToBurnIsHigherThanMax(uint256,uint256)", VUSDAmount, VUSDAmount - 1)
        );
        gateway.withdraw(token, tokenAmount, VUSDAmount - 1, bob);
    }

    function test_withdraw_revertIfMaxWithdrawExceeded() public {
        uint256 tokenAmount = 1000e6;
        uint256 VUSDAmount = gateway.previewWithdraw(token, tokenAmount);
        uint256 maxWithdraw = gateway.maxWithdraw(token);

        // Whitelist bob to bypass withdrawal delay
        gateway.addToInstantRedeemWhitelist(bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxWithdraw(uint256,uint256)", tokenAmount, maxWithdraw));
        gateway.withdraw(token, tokenAmount, VUSDAmount, bob);
    }

    // --- previewDeposit ---
    function testFuzz_previewDeposit(int256 price, uint256 mintFee, uint256 amount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_FEE_BPS());
        amount = bound(amount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(token, mintFee);

        // Calculate expected PeggedToken amount
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);
        uint256 maxBps = gateway.MAX_BPS();
        uint256 amountAfterFee = amount.mulDiv((maxBps - gateway.mintFee(token)), maxBps);
        uint256 expectedPeggedToken = latestPrice >= unitPrice
            ? parseAmount(amountAfterFee, token, address(VUSD))
            : parseAmount(amountAfterFee.mulDiv(latestPrice, unitPrice), token, address(VUSD));

        uint256 actualPeggedToken = gateway.previewDeposit(token, amount);
        assertEq(actualPeggedToken, expectedPeggedToken, "Incorrect PeggedToken amount");
    }

    function test_previewDeposit_revertForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewDeposit(token2, 100e18);
    }

    // --- previewMint ---
    function testFuzz_previewMint(int256 price, uint256 mintFee, uint256 VUSDAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_FEE_BPS());
        VUSDAmount = bound(VUSDAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(token, mintFee);

        // Calculate expected token amount
        uint256 oneToken = parseAmount(1, address(0), token);
        uint256 VUSDForOneToken = gateway.previewDeposit(token, oneToken);
        uint256 expectedToken = VUSDAmount.mulDiv(oneToken, VUSDForOneToken, Math.Rounding.Ceil);

        uint256 actualToken = gateway.previewMint(token, VUSDAmount);
        assertEq(actualToken, expectedToken, "Incorrect token amount");
    }

    function test_previewMint_revertForUnsupportedToken() public {
        address token2 = address(new MockERC20());
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewMint(token2, 100e18);
    }

    // --- previewRedeem ---
    function testFuzz_previewRedeem(int256 price, uint256 redeemFee, uint256 VUSDAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8); // Price within 0.2% of $1
        redeemFee = bound(redeemFee, 0, gateway.MAX_FEE_BPS());
        VUSDAmount = bound(VUSDAmount, 0, type(uint256).max / 1e18);
        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(token, redeemFee);

        // Calculate expected token amount
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);
        uint256 maxBps = gateway.MAX_BPS();
        uint256 VUSDAfterFee = VUSDAmount.mulDiv((maxBps - gateway.redeemFee(token)), maxBps);
        uint256 expectedToken = latestPrice <= unitPrice
            ? parseAmount(VUSDAfterFee, address(VUSD), token)
            : parseAmount(VUSDAfterFee.mulDiv(unitPrice, latestPrice), address(VUSD), token);

        uint256 actualToken = gateway.previewRedeem(token, VUSDAmount);
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
        redeemFee = bound(redeemFee, 0, gateway.MAX_FEE_BPS());
        tokenAmount = bound(tokenAmount, 0, type(uint128).max);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(token, redeemFee);

        // Calculate expected PeggedToken amount
        uint256 onePeggedToken = parseAmount(1, address(0), address(VUSD));
        uint256 tokenForOnePeggedToken = gateway.previewRedeem(token, onePeggedToken);
        uint256 expectedPeggedToken = tokenAmount.mulDiv(onePeggedToken, tokenForOnePeggedToken, Math.Rounding.Ceil);

        uint256 actualPeggedToken = gateway.previewWithdraw(token, tokenAmount);
        assertEq(actualPeggedToken, expectedPeggedToken, "Incorrect PeggedToken amount");
    }

    function test_previewWithdraw_revertForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewWithdraw(token2, 100e6);
    }

    // --- update mint limit ---
    function test_updateMintLimit() public {
        uint256 newMintLimit = 1000 ether; // amount in PeggedToken decimal
        vm.prank(admin);
        gateway.updateMintLimit(newMintLimit);
        assertEq(gateway.mintLimit(), newMintLimit, "Mint limit should be updated");
    }

    function test_updateMintLimit_revertIfNotDefaultAdminRole() public {
        uint256 newMintLimit = 1000 ether; // amount in PeggedToken decimal
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, 0x00));
        gateway.updateMintLimit(newMintLimit);
    }

    // --- update AMO mint limit ---
    function test_updateAmoMintLimit_success() public {
        uint256 newAmoMintLimit = 5000e18;
        vm.prank(admin);
        gateway.updateAmoMintLimit(newAmoMintLimit);
        assertEq(gateway.amoMintLimit(), newAmoMintLimit, "AMO mint limit should be updated");
    }

    function test_updateAmoMintLimit_revertIfNotDefaultAdminRole() public {
        uint256 newAmoMintLimit = 5000e18;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, 0x00));
        gateway.updateAmoMintLimit(newAmoMintLimit);
    }

    function test_updateAmoMintLimit_revertIfBelowCurrentAmoSupply() public {
        // Setup: mint some AMO tokens first
        deal(address(token), address(treasury), 1000e6);
        vm.prank(admin);
        gateway.updateAmoMintLimit(500e18);
        gateway.mintToAMO(300e18, bob);

        // Try to set limit below current AMO supply
        uint256 newAmoMintLimit = 200e18;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidAmoMintLimit(uint256,uint256)", newAmoMintLimit, 300e18));
        gateway.updateAmoMintLimit(newAmoMintLimit);
    }

    function test_updateAmoMintLimit_allowZeroWhenAmoSupplyIsZero() public {
        // Set limit to zero when AMO supply is zero should succeed
        vm.prank(admin);
        gateway.updateAmoMintLimit(0);
        assertEq(gateway.amoMintLimit(), 0, "AMO mint limit should be set to zero");
    }

    // --- updateMintFee (per-token) ---

    function test_updateMintFeePerToken_success() public {
        gateway.updateMintFee(token, 100);
        assertEq(gateway.mintFee(token), 100);
    }

    function test_updateMintFeePerToken_revertIfNotMaintainerRole() public {
        bytes32 _role = treasury.MAINTAINER_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, _role));
        gateway.updateMintFee(token, 100);
    }

    function test_updateMintFeePerToken_revertIfFeeExceedsMax() public {
        uint256 newFee = 501;
        vm.expectRevert(abi.encodeWithSignature("InvalidMintFee(uint256)", newFee));
        gateway.updateMintFee(token, newFee);
    }

    function test_updateMintFeePerToken_revertIfTokenNotWhitelisted() public {
        address fakeToken = makeAddr("fakeToken");
        vm.expectRevert(abi.encodeWithSignature("TokenNotWhitelisted(address)", fakeToken));
        gateway.updateMintFee(fakeToken, 100);
    }

    function test_updateMintFeePerToken_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Gateway.MintFeeUpdated(token, 0, 100);
        gateway.updateMintFee(token, 100);
    }

    function test_updateMintFeePerToken_defaultIsZero() public view {
        assertEq(gateway.mintFee(token), 0);
    }

    // --- updateRedeemFee (per-token) ---

    function test_updateRedeemFeePerToken_success() public {
        gateway.updateRedeemFee(token, 50);
        assertEq(gateway.redeemFee(token), 50);
    }

    function test_updateRedeemFeePerToken_revertIfNotMaintainerRole() public {
        bytes32 _role = treasury.MAINTAINER_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, _role));
        gateway.updateRedeemFee(token, 50);
    }

    function test_updateRedeemFeePerToken_revertIfFeeExceedsMax() public {
        uint256 newFee = 501;
        vm.expectRevert(abi.encodeWithSignature("InvalidRedeemFee(uint256)", newFee));
        gateway.updateRedeemFee(token, newFee);
    }

    function test_updateRedeemFeePerToken_revertIfTokenNotWhitelisted() public {
        address fakeToken = makeAddr("fakeToken");
        vm.expectRevert(abi.encodeWithSignature("TokenNotWhitelisted(address)", fakeToken));
        gateway.updateRedeemFee(fakeToken, 50);
    }

    function test_updateRedeemFeePerToken_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Gateway.RedeemFeeUpdated(token, 0, 50);
        gateway.updateRedeemFee(token, 50);
    }

    function test_updateRedeemFeePerToken_defaultIsZero() public view {
        assertEq(gateway.redeemFee(token), 0);
    }

    // --- per-token fee takes priority over global ---

    function test_deposit_usesPerTokenMintFeeOverGlobal() public {
        mockOracle.updatePrice(1e8);
        // Set per-token mint fee to 200 BPS (2%)
        gateway.updateMintFee(token, 200);

        uint256 depositAmount = 1000 * 10 ** MockERC20(token).decimals();
        deal(token, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), depositAmount);
        uint256 peggedTokenOut = gateway.previewDeposit(token, depositAmount);
        gateway.deposit(token, depositAmount, peggedTokenOut, alice);
        vm.stopPrank();

        // Per-token fee of 200 BPS (2%) should apply: 1000 * 0.98 = 980 VUSD
        assertEq(VUSD.balanceOf(alice), 980e18);
    }

    function test_redeem_usesPerTokenRedeemFeeOverGlobal() public {
        gateway.setWithdrawalDelayEnabled(false);
        mockOracle.updatePrice(1e8);
        // Set per-token redeem fee to 100 BPS (1%)
        gateway.updateRedeemFee(token, 100);

        mintPeggedToken(alice, 1000e18);

        uint256 redeemAmount = 1000e18;
        uint256 expectedTokenOut = gateway.previewRedeem(token, redeemAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), redeemAmount);
        gateway.redeem(token, redeemAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // Per-token fee of 100 BPS (1%): 1000 * 0.99 = 990 after fee
        uint256 afterFee = redeemAmount * (10_000 - 100) / 10_000;
        uint256 expected = afterFee / 10 ** (18 - MockERC20(token).decimals());
        assertEq(IERC20(token).balanceOf(alice), expected);
    }

    // --- updatePegBand ---

    function test_updatePegBand_success() public {
        // Treasury priceTolerance is 100 BPS (1%), so we can set up to 99
        vm.prank(admin);
        gateway.updatePegBand(token, 50); // 0.5%
        assertEq(gateway.pegBand(token), 50);
    }

    function test_updatePegBand_revertIfNotDefaultAdmin() public {
        bytes32 _role = gateway.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, _role));
        vm.prank(alice);
        gateway.updatePegBand(token, 50);
    }

    function test_updatePegBand_revertIfEqualToPriceTolerance() public {
        // Treasury priceTolerance = 100, setting to 100 should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidPegBand(uint256,uint256)", 100, 100));
        vm.prank(admin);
        gateway.updatePegBand(token, 100);
    }

    function test_updatePegBand_revertIfExceedsPriceTolerance() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPegBand(uint256,uint256)", 200, 100));
        vm.prank(admin);
        gateway.updatePegBand(token, 200);
    }

    function test_updatePegBand_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Gateway.PegBandUpdated(token, 0, 50);
        vm.prank(admin);
        gateway.updatePegBand(token, 50);
    }

    function test_updatePegBand_defaultIsZero() public view {
        assertEq(gateway.pegBand(token), 0);
    }

    // --- peg band affects deposit (mint) pricing ---

    function test_deposit_withinPegBand_mints1to1() public {
        // Set peg band to 50 BPS (0.5%)
        vm.prank(admin);
        gateway.updatePegBand(token, 50);

        // Price = 0.996 (0.4% below peg, within 0.5% peg band)
        mockOracle.updatePrice(0.996e8);

        uint256 depositAmount = 1000 * 10 ** MockERC20(token).decimals();
        deal(token, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), depositAmount);
        uint256 peggedTokenOut = gateway.previewDeposit(token, depositAmount);
        gateway.deposit(token, depositAmount, peggedTokenOut, alice);
        vm.stopPrank();

        // Should mint 1:1 (1000 VUSD) since price is within peg band
        assertEq(VUSD.balanceOf(alice), 1000e18);
    }

    function test_deposit_belowPegBand_mintsAtDiscount() public {
        // Set peg band to 50 BPS (0.5%)
        vm.prank(admin);
        gateway.updatePegBand(token, 50);

        // Price = 0.990 (1% below peg, outside 0.5% peg band)
        mockOracle.updatePrice(0.990e8);

        uint256 depositAmount = 1000 * 10 ** MockERC20(token).decimals();
        deal(token, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), depositAmount);
        uint256 peggedTokenOut = gateway.previewDeposit(token, depositAmount);
        gateway.deposit(token, depositAmount, peggedTokenOut, alice);
        vm.stopPrank();

        // Should mint discounted: 1000 * 0.990 = 990 VUSD
        assertEq(VUSD.balanceOf(alice), 990e18);
    }

    function test_deposit_zeroPegBand_mintsAtDiscount() public {
        // Default peg band = 0, any price below unitPrice triggers discount
        mockOracle.updatePrice(0.999e8);

        uint256 depositAmount = 1000 * 10 ** MockERC20(token).decimals();
        deal(token, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), depositAmount);
        uint256 peggedTokenOut = gateway.previewDeposit(token, depositAmount);
        gateway.deposit(token, depositAmount, peggedTokenOut, alice);
        vm.stopPrank();

        // With pegBand=0, price 0.999 < unitPrice 1.0, so discount applies
        // 1000 * 0.999 = 999 VUSD
        assertEq(VUSD.balanceOf(alice), 999e18);
    }

    // --- peg band affects redeem (withdraw) pricing ---

    function test_redeem_withinPegBand_redeems1to1() public {
        // Disable withdrawal delay for instant redeem
        gateway.setWithdrawalDelayEnabled(false);

        // First mint some VUSD at price=1.0
        mockOracle.updatePrice(1e8);
        mintPeggedToken(alice, 1000e18);

        // Set peg band to 50 BPS (0.5%) and per-token redeem fee to 30 BPS
        vm.prank(admin);
        gateway.updatePegBand(token, 50);
        gateway.updateRedeemFee(token, 30);

        // Price = 1.004 (0.4% above peg, within 0.5% peg band)
        mockOracle.updatePrice(1.004e8);

        uint256 redeemAmount = 100e18;
        uint256 expectedTokenOut = gateway.previewRedeem(token, redeemAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), redeemAmount);
        gateway.redeem(token, redeemAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // Within peg band → no price discount (1:1 on price), but 30 BPS per-token redeem fee applies
        // 100e18 * (10000-30)/10000 = 99.7e18, converted to 6 decimals = 99_700_000
        uint256 redeemFee = gateway.redeemFee(token);
        uint256 expectedAfterFee = redeemAmount * (10_000 - redeemFee) / 10_000;
        uint256 expectedTokens = expectedAfterFee / 10 ** (18 - MockERC20(token).decimals());
        assertEq(IERC20(token).balanceOf(alice), expectedTokens);
    }

    function test_redeem_abovePegBand_redeemsAtDiscount() public {
        // Disable withdrawal delay for instant redeem
        gateway.setWithdrawalDelayEnabled(false);

        // First mint some VUSD at price=1.0
        mockOracle.updatePrice(1e8);
        mintPeggedToken(alice, 1000e18);

        // Set peg band to 50 BPS (0.5%) and per-token redeem fee to 30 BPS
        vm.prank(admin);
        gateway.updatePegBand(token, 50);
        gateway.updateRedeemFee(token, 30);

        // Price = 1.008 (0.8% above peg, outside 0.5% peg band)
        mockOracle.updatePrice(1.008e8);

        uint256 redeemAmount = 1000e18;
        uint256 expectedTokenOut = gateway.previewRedeem(token, redeemAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), redeemAmount);
        gateway.redeem(token, redeemAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // Outside peg band → price discount applied, plus 30 BPS per-token redeem fee
        // 1000e18 * (10000-30)/10000 = 997e18 (after fee)
        // 997e18 * 1e8 / 1.008e8 (discount) → converted to 6 decimals
        uint256 redeemFee = gateway.redeemFee(token);
        uint256 afterFee = redeemAmount * (10_000 - redeemFee) / 10_000;
        uint256 discounted = afterFee * 1e8 / 1.008e8;
        uint256 expected = discounted / 10 ** (18 - MockERC20(token).decimals());
        assertApproxEqAbs(IERC20(token).balanceOf(alice), expected, 1);
    }

    function test_redeem_zeroPegBand_redeemsAtDiscount() public {
        // Disable withdrawal delay for instant redeem
        gateway.setWithdrawalDelayEnabled(false);

        // First mint some VUSD at price=1.0
        mockOracle.updatePrice(1e8);
        mintPeggedToken(alice, 1000e18);

        // Default peg band = 0, pegCeiling = unitPrice = 1.0
        // Set per-token redeem fee to 30 BPS
        gateway.updateRedeemFee(token, 30);

        // Price = 1.001 (above unitPrice, outside zero band)
        mockOracle.updatePrice(1.001e8);

        uint256 redeemAmount = 1000e18;
        uint256 expectedTokenOut = gateway.previewRedeem(token, redeemAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), redeemAmount);
        gateway.redeem(token, redeemAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // With pegBand=0, pegCeiling = 1.0, price 1.001 > 1.0 → discount path
        // afterFee = 1000e18 * (10000-30)/10000 = 997e18
        // discounted = 997e18 * 1e8 / 1.001e8
        uint256 redeemFee = gateway.redeemFee(token);
        uint256 afterFee = redeemAmount * (10_000 - redeemFee) / 10_000;
        uint256 discounted = afterFee * 1e8 / 1.001e8;
        uint256 expected = discounted / 10 ** (18 - MockERC20(token).decimals());
        assertApproxEqAbs(IERC20(token).balanceOf(alice), expected, 1);
    }

    function test_deposit_zeroPegBand_mints1to1_atExactPeg() public {
        // Default peg band = 0, pegFloor = unitPrice = 1.0
        // Price = exactly 1.0 → should mint 1:1
        mockOracle.updatePrice(1e8);

        uint256 depositAmount = 1000 * 10 ** MockERC20(token).decimals();
        deal(token, alice, depositAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), depositAmount);
        uint256 peggedTokenOut = gateway.previewDeposit(token, depositAmount);
        gateway.deposit(token, depositAmount, peggedTokenOut, alice);
        vm.stopPrank();

        // With pegBand=0, price == unitPrice (1.0 >= 1.0) → 1:1 path
        assertEq(VUSD.balanceOf(alice), 1000e18);
    }

    function test_redeem_zeroPegBand_redeems1to1_atExactPeg() public {
        // Disable withdrawal delay for instant redeem
        gateway.setWithdrawalDelayEnabled(false);

        // First mint some VUSD at price=1.0
        mockOracle.updatePrice(1e8);
        mintPeggedToken(alice, 1000e18);

        // Default peg band = 0, pegCeiling = unitPrice = 1.0
        // Set per-token redeem fee to 30 BPS
        gateway.updateRedeemFee(token, 30);

        // Price = exactly 1.0 → should redeem 1:1 (minus fee)
        uint256 redeemAmount = 100e18;
        uint256 expectedTokenOut = gateway.previewRedeem(token, redeemAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), redeemAmount);
        gateway.redeem(token, redeemAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // With pegBand=0, price == unitPrice (1.0 <= 1.0) → 1:1 path, only per-token redeem fee applies
        uint256 redeemFee = gateway.redeemFee(token);
        uint256 expectedAfterFee = redeemAmount * (10_000 - redeemFee) / 10_000;
        uint256 expectedTokens = expectedAfterFee / 10 ** (18 - MockERC20(token).decimals());
        assertEq(IERC20(token).balanceOf(alice), expectedTokens);
    }

    function test_maxDeposit() public view {
        assertEq(gateway.maxDeposit(), type(uint256).max);
    }

    function test_maxMint() public {
        // With zero supply
        vm.prank(admin);
        gateway.updateMintLimit(100e18);
        assertEq(gateway.maxMint(), 100e18);
        // Increase total supply via owner mint
        vm.prank(address(gateway));
        VUSD.mint(address(this), 60e18);
        assertEq(gateway.maxMint(), 40e18);
        // Set limit below current supply → zero
        vm.prank(admin);
        gateway.updateMintLimit(10e18);
        assertEq(gateway.maxMint(), 0);
    }

    function test_maxRedeem() public {
        // With zero balance
        assertEq(gateway.maxRedeem(alice), 0);
        // mint 50 PeggedToken to alice
        vm.prank(address(gateway));
        VUSD.mint(alice, 50e18);
        assertEq(gateway.maxRedeem(alice), 50e18);
    }

    function test_maxWithdraw() public {
        assertEq(gateway.maxWithdraw(token), 0);

        deal(address(token), address(treasury), 50e18);
        assertEq(gateway.maxWithdraw(token), 50e18);
    }

    function test_owner_and_treasury_views() public view {
        assertEq(gateway.owner(), admin);
        assertEq(gateway.treasury(), address(treasury));
    }

    // --- Withdrawal Delay & Request Redeem Tests ---

    function test_requestRedeem() public {
        uint256 VUSDAmount = 100e18;

        // Mint VUSD to alice
        mintPeggedToken(alice, VUSDAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);

        uint256 claimableAt = block.timestamp + 7 days;

        vm.expectEmit(true, false, false, true);
        emit Gateway.RedeemRequested(alice, VUSDAmount, claimableAt);

        gateway.requestRedeem(VUSDAmount);
        vm.stopPrank();

        // Verify request was created
        (uint256 locked, uint256 claimable) = gateway.getRedeemRequest(alice);
        assertEq(locked, VUSDAmount, "Incorrect locked amount");
        assertEq(claimable, claimableAt, "Incorrect claimable time");

        // Verify VUSD was transferred to gateway
        assertEq(VUSD.balanceOf(alice), 0, "Alice should have 0 VUSD");
        assertEq(VUSD.balanceOf(address(gateway)), VUSDAmount, "Gateway should have locked VUSD");
    }

    function test_requestRedeem_mergingRequests() public {
        uint256 firstAmount = 50e18;
        uint256 secondAmount = 30e18;

        // Mint VUSD to alice
        mintPeggedToken(alice, firstAmount + secondAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), firstAmount + secondAmount);

        // First request
        gateway.requestRedeem(firstAmount);
        uint256 firstClaimableAt = block.timestamp + 7 days;

        (uint256 locked1, uint256 claimable1) = gateway.getRedeemRequest(alice);
        assertEq(locked1, firstAmount, "First request amount incorrect");
        assertEq(claimable1, firstClaimableAt, "First claimable time incorrect");

        // Advance time by 3 days
        vm.warp(block.timestamp + 3 days);

        // Second request - should merge and reset timer
        gateway.requestRedeem(secondAmount);
        uint256 secondClaimableAt = block.timestamp + 7 days;

        (uint256 locked2, uint256 claimable2) = gateway.getRedeemRequest(alice);
        assertEq(locked2, firstAmount + secondAmount, "Merged amount incorrect");
        assertEq(claimable2, secondClaimableAt, "Timer should be reset");

        vm.stopPrank();
    }

    function test_requestRedeem_revertIfZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(Gateway.AmountIsZero.selector);
        gateway.requestRedeem(0);
    }

    function test_requestRedeem_revertIfWithdrawalDelayDisabled() public {
        // Disable withdrawal delay
        gateway.setWithdrawalDelayEnabled(false);

        uint256 VUSDAmount = 100e18;
        mintPeggedToken(alice, VUSDAmount);

        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);

        vm.expectRevert(Gateway.WithdrawalDelayFeatureNotEnabled.selector);
        gateway.requestRedeem(VUSDAmount);
        vm.stopPrank();
    }

    function test_cancelRedeemRequest() public {
        uint256 VUSDAmount = 100e18;

        // Setup: Create a redeem request
        mintPeggedToken(alice, VUSDAmount);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);
        gateway.requestRedeem(VUSDAmount);

        assertEq(VUSD.balanceOf(alice), 0, "Alice should have 0 VUSD after request");

        // Cancel the request
        vm.expectEmit(true, false, false, true);
        emit Gateway.RedeemRequestCancelled(alice, VUSDAmount);

        gateway.cancelRedeemRequest();
        vm.stopPrank();

        // Verify request was deleted
        (uint256 locked, uint256 claimable) = gateway.getRedeemRequest(alice);
        assertEq(locked, 0, "Locked amount should be 0");
        assertEq(claimable, 0, "Claimable time should be 0");

        // Verify VUSD was returned to alice
        assertEq(VUSD.balanceOf(alice), VUSDAmount, "Alice should have VUSD back");
        assertEq(VUSD.balanceOf(address(gateway)), 0, "Gateway should have 0 VUSD");
    }

    function test_cancelRedeemRequest_revertIfNoRequest() public {
        vm.prank(alice);
        vm.expectRevert(Gateway.NoActiveWithdrawalRequest.selector);
        gateway.cancelRedeemRequest();
    }

    function test_redeem_afterRequest_fullAmount() public {
        uint256 VUSDAmount = 100e18;

        // Setup: Create and wait for redeem request
        mintPeggedToken(alice, VUSDAmount);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);
        gateway.requestRedeem(VUSDAmount);

        // Fast forward past the delay
        vm.warp(block.timestamp + 7 days + 1);

        // Update oracle to prevent stale price error
        mockOracle.updatePrice(0.999e8);

        // Redeem the full locked amount
        uint256 expectedTokenOut = gateway.previewRedeem(token, VUSDAmount);
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);

        gateway.redeem(token, VUSDAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // Verify tokens received
        assertEq(
            IERC20(token).balanceOf(alice) - tokenBalanceBefore, expectedTokenOut, "Should receive correct token amount"
        );

        // Verify request was deleted
        (uint256 locked,) = gateway.getRedeemRequest(alice);
        assertEq(locked, 0, "Request should be deleted");

        // Verify VUSD was burned from gateway
        assertEq(VUSD.balanceOf(address(gateway)), 0, "Gateway should have 0 VUSD");
    }

    function test_redeem_afterRequest_partialAmount() public {
        uint256 VUSDAmount = 100e18;
        uint256 redeemAmount = 60e18;

        // Setup: Create and wait for redeem request
        mintPeggedToken(alice, VUSDAmount);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);
        gateway.requestRedeem(VUSDAmount);

        // Fast forward past the delay
        vm.warp(block.timestamp + 7 days + 1);

        // Update oracle to prevent stale price error
        mockOracle.updatePrice(0.999e8);

        // Redeem partial amount
        uint256 expectedTokenOut = gateway.previewRedeem(token, redeemAmount);
        gateway.redeem(token, redeemAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // Verify partial request remains
        (uint256 locked,) = gateway.getRedeemRequest(alice);
        assertEq(locked, VUSDAmount - redeemAmount, "Should have remaining locked amount");

        // Verify VUSD balance in gateway
        assertEq(VUSD.balanceOf(address(gateway)), VUSDAmount - redeemAmount, "Gateway should have remaining VUSD");
    }

    function test_redeem_afterRequest_excessAmount_whitelisted() public {
        uint256 amountLocked = 100e18;
        uint256 VUSDExtra = 50e18;
        uint256 totalRedeem = amountLocked + VUSDExtra;

        // Whitelist alice for instant redeem
        gateway.addToInstantRedeemWhitelist(alice);

        // Setup: Create request and also keep some VUSD in wallet
        mintPeggedToken(alice, totalRedeem);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), amountLocked);
        gateway.requestRedeem(amountLocked);

        // alice still has VUSDExtra in wallet
        assertEq(VUSD.balanceOf(alice), VUSDExtra, "Alice should have extra VUSD");

        // Fast forward past the delay
        vm.warp(block.timestamp + 7 days + 1);

        // Update oracle to prevent stale price error
        mockOracle.updatePrice(0.999e8);

        // Redeem more than locked amount (should use locked + wallet)
        uint256 expectedTokenOut = gateway.previewRedeem(token, totalRedeem);
        gateway.redeem(token, totalRedeem, expectedTokenOut, alice);
        vm.stopPrank();

        // Verify request was deleted
        (uint256 locked,) = gateway.getRedeemRequest(alice);
        assertEq(locked, 0, "Request should be deleted");

        // Verify all VUSD was burned
        assertEq(VUSD.balanceOf(alice), 0, "Alice should have 0 VUSD");
        assertEq(VUSD.balanceOf(address(gateway)), 0, "Gateway should have 0 VUSD");
    }

    function test_redeem_afterRequest_excessAmount_notWhitelisted_reverts() public {
        uint256 amountLocked = 100e18;
        uint256 VUSDExtra = 50e18;
        uint256 totalRedeem = amountLocked + VUSDExtra;

        // Setup: Create request and also keep some VUSD in wallet
        mintPeggedToken(alice, totalRedeem);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), amountLocked);
        gateway.requestRedeem(amountLocked);

        // Fast forward past the delay
        vm.warp(block.timestamp + 7 days + 1);

        // Update oracle to prevent stale price error
        mockOracle.updatePrice(0.999e8);

        // Try to redeem more than locked amount without being whitelisted
        uint256 expectedTokenOut = gateway.previewRedeem(token, totalRedeem);
        vm.expectRevert(abi.encodeWithSignature("CallerNotWhitelisted(address)", alice));
        gateway.redeem(token, totalRedeem, expectedTokenOut, alice);
        vm.stopPrank();
    }

    function test_withdraw_afterRequest_fullAmount() public {
        uint256 VUSDAmount = 100e18;

        // Setup: Create and wait for redeem request
        mintPeggedToken(alice, VUSDAmount);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);
        gateway.requestRedeem(VUSDAmount);

        // Fast forward past the delay
        vm.warp(block.timestamp + 7 days + 1);

        // Update oracle to prevent stale price error
        mockOracle.updatePrice(0.999e8);

        // Withdraw using exact token amount
        uint256 tokenAmount = gateway.previewRedeem(token, VUSDAmount);
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);

        gateway.withdraw(token, tokenAmount, VUSDAmount, alice);
        vm.stopPrank();

        // Verify tokens received
        assertEq(
            IERC20(token).balanceOf(alice) - tokenBalanceBefore, tokenAmount, "Should receive correct token amount"
        );

        // Verify request was deleted
        (uint256 locked,) = gateway.getRedeemRequest(alice);
        assertEq(locked, 0, "Request should be deleted");
    }

    function test_withdraw_afterRequest_partialAmount() public {
        uint256 VUSDAmount = 100e18;
        uint256 withdrawTokenAmount = gateway.previewRedeem(token, 40e18);

        // Setup: Create and wait for redeem request
        mintPeggedToken(alice, VUSDAmount);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);
        gateway.requestRedeem(VUSDAmount);

        // Fast forward past the delay
        vm.warp(block.timestamp + 7 days + 1);

        // Update oracle to prevent stale price error
        mockOracle.updatePrice(0.999e8);

        // Withdraw partial amount
        uint256 VUSDToBurn = gateway.previewWithdraw(token, withdrawTokenAmount);
        gateway.withdraw(token, withdrawTokenAmount, VUSDToBurn, alice);
        vm.stopPrank();

        // Verify partial request remains
        (uint256 locked,) = gateway.getRedeemRequest(alice);
        assertEq(locked, VUSDAmount - VUSDToBurn, "Should have remaining locked amount");
    }

    function test_redeem_instantWithWhitelist() public {
        uint256 VUSDAmount = 100e18;

        // Whitelist alice
        gateway.addToInstantRedeemWhitelist(alice);

        // Mint VUSD to alice
        mintPeggedToken(alice, VUSDAmount);

        vm.startPrank(alice);
        // Should be able to redeem instantly without requesting
        uint256 expectedTokenOut = gateway.previewRedeem(token, VUSDAmount);
        gateway.redeem(token, VUSDAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // Verify redeem was successful
        assertEq(VUSD.balanceOf(alice), 0, "Alice should have 0 VUSD");
    }

    function test_redeem_revertIfNotWhitelisted_delayEnabled() public {
        uint256 VUSDAmount = 100e18;

        // Mint VUSD to alice (not whitelisted)
        mintPeggedToken(alice, VUSDAmount);

        vm.prank(alice);
        // Should revert because alice is not whitelisted and has no claimable request
        vm.expectRevert(abi.encodeWithSignature("CallerNotWhitelisted(address)", alice));
        gateway.redeem(token, VUSDAmount, 0, alice);
    }

    function test_withdraw_revertIfNotWhitelisted_delayEnabled() public {
        uint256 tokenAmount = 100e6;
        uint256 VUSDAmount = gateway.previewWithdraw(token, tokenAmount);

        // Mint VUSD to alice (not whitelisted)
        mintPeggedToken(alice, VUSDAmount);

        vm.prank(alice);
        // Should revert because alice is not whitelisted and has no claimable request
        vm.expectRevert(abi.encodeWithSignature("CallerNotWhitelisted(address)", alice));
        gateway.withdraw(token, tokenAmount, VUSDAmount, alice);
    }

    function test_redeem_instantWhenDelayDisabled() public {
        uint256 VUSDAmount = 100e18;

        // Disable withdrawal delay
        gateway.setWithdrawalDelayEnabled(false);

        // Mint VUSD to alice
        mintPeggedToken(alice, VUSDAmount);

        vm.startPrank(alice);
        // Should be able to redeem instantly when delay is disabled
        uint256 expectedTokenOut = gateway.previewRedeem(token, VUSDAmount);
        gateway.redeem(token, VUSDAmount, expectedTokenOut, alice);
        vm.stopPrank();

        // Verify redeem was successful
        assertEq(VUSD.balanceOf(alice), 0, "Alice should have 0 VUSD");
    }

    function test_setWithdrawalDelayEnabled() public {
        // Initial state is enabled
        assertTrue(gateway.withdrawalDelayEnabled(), "Should be enabled initially");

        vm.expectEmit(false, false, false, true);
        emit Gateway.WithdrawalDelayEnabled(false);
        gateway.setWithdrawalDelayEnabled(false);

        assertFalse(gateway.withdrawalDelayEnabled(), "Should be disabled after setting false");

        vm.expectEmit(false, false, false, true);
        emit Gateway.WithdrawalDelayEnabled(true);
        gateway.setWithdrawalDelayEnabled(true);

        assertTrue(gateway.withdrawalDelayEnabled(), "Should be enabled after setting true");
    }

    function test_setWithdrawalDelayEnabled_idempotent() public {
        // Setting to same value should not change state
        assertTrue(gateway.withdrawalDelayEnabled(), "Should be enabled initially");
        gateway.setWithdrawalDelayEnabled(true);
        assertTrue(gateway.withdrawalDelayEnabled(), "Should still be enabled");
    }

    function test_setWithdrawalDelayEnabled_revertIfNotMaintainerRole() public {
        bytes32 _role = treasury.MAINTAINER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, _role));
        gateway.setWithdrawalDelayEnabled(false);
    }

    function test_updateWithdrawalDelay() public {
        uint256 newDelay = 14 days;

        vm.expectEmit(false, false, false, true);
        emit Gateway.WithdrawalDelayUpdated(7 days, newDelay);
        gateway.updateWithdrawalDelay(newDelay);

        assertEq(gateway.withdrawalDelay(), newDelay, "Delay should be updated");
    }

    function test_updateWithdrawalDelay_revertIfZero() public {
        vm.expectRevert(Gateway.InvalidWithdrawalDelay.selector);
        gateway.updateWithdrawalDelay(0);
    }

    function test_updateWithdrawalDelay_revertIfNotMaintainerRole() public {
        bytes32 _role = treasury.MAINTAINER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, _role));
        gateway.updateWithdrawalDelay(14 days);
    }

    function test_addToInstantRedeemWhitelist() public {
        assertFalse(gateway.isInstantRedeemWhitelisted(alice), "Alice should not be whitelisted");

        vm.expectEmit(true, false, false, false);
        emit Gateway.AddedToInstantRedeemWhitelist(alice);
        gateway.addToInstantRedeemWhitelist(alice);

        assertTrue(gateway.isInstantRedeemWhitelisted(alice), "Alice should be whitelisted");

        address[] memory whitelist = gateway.getInstantRedeemWhitelist();
        assertEq(whitelist.length, 1, "Whitelist should have 1 address");
        assertEq(whitelist[0], alice, "Alice should be in whitelist");
    }

    function test_addToInstantRedeemWhitelist_revertIfZeroAddress() public {
        vm.expectRevert(Gateway.AddressIsZero.selector);
        gateway.addToInstantRedeemWhitelist(address(0));
    }

    function test_addToInstantRedeemWhitelist_revertIfAlreadyWhitelisted() public {
        gateway.addToInstantRedeemWhitelist(alice);

        vm.expectRevert(abi.encodeWithSignature("AccountAlreadyWhitelisted(address)", alice));
        gateway.addToInstantRedeemWhitelist(alice);
    }

    function test_addToInstantRedeemWhitelist_revertIfNotMaintainerRole() public {
        bytes32 _role = treasury.MAINTAINER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, _role));
        gateway.addToInstantRedeemWhitelist(bob);
    }

    function test_removeFromInstantRedeemWhitelist() public {
        // First add alice
        gateway.addToInstantRedeemWhitelist(alice);
        assertTrue(gateway.isInstantRedeemWhitelisted(alice), "Alice should be whitelisted");

        // Remove alice
        vm.expectEmit(true, false, false, false);
        emit Gateway.RemovedFromInstantRedeemWhitelist(alice);
        gateway.removeFromInstantRedeemWhitelist(alice);

        assertFalse(gateway.isInstantRedeemWhitelisted(alice), "Alice should not be whitelisted");

        address[] memory whitelist = gateway.getInstantRedeemWhitelist();
        assertEq(whitelist.length, 0, "Whitelist should be empty");
    }

    function test_removeFromInstantRedeemWhitelist_revertIfNotInWhitelist() public {
        vm.expectRevert(abi.encodeWithSignature("AccountNotWhitelisted(address)", alice));
        gateway.removeFromInstantRedeemWhitelist(alice);
    }

    function test_removeFromInstantRedeemWhitelist_revertIfNotMaintainerRole() public {
        gateway.addToInstantRedeemWhitelist(alice);

        bytes32 _role = treasury.MAINTAINER_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, _role));
        gateway.removeFromInstantRedeemWhitelist(alice);
    }

    function test_getRedeemRequest() public {
        uint256 VUSDAmount = 100e18;

        // Initially no request
        (uint256 locked0, uint256 claimable0) = gateway.getRedeemRequest(alice);
        assertEq(locked0, 0, "Should have no locked amount");
        assertEq(claimable0, 0, "Should have no claimable time");

        // Create request
        mintPeggedToken(alice, VUSDAmount);
        vm.startPrank(alice);
        VUSD.approve(address(gateway), VUSDAmount);
        gateway.requestRedeem(VUSDAmount);
        vm.stopPrank();

        // Verify request
        (uint256 locked1, uint256 claimable1) = gateway.getRedeemRequest(alice);
        assertEq(locked1, VUSDAmount, "Should have locked amount");
        assertEq(claimable1, block.timestamp + 7 days, "Should have claimable time");
    }
}
