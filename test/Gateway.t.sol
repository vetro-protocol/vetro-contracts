// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {VUSD} from "src/VUSD.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockMorphoVaultV2} from "test/mocks/MockMorphoVaultV2.sol";
import {console} from "forge-std/console.sol";

contract GatewayTest is Test {
    using SafeERC20 for IERC20;
    using Math for uint256;

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

        gateway = new Gateway(address(vusd), type(uint256).max, owner);
        vusd.updateGateway(address(gateway));

        token = address(new MockERC20());
        mockVault = new MockMorphoVaultV2(address(token));
        mockOracle = new MockChainlinkOracle(0.999e8);
        treasury.addToWhitelist(token, address(mockVault), address(mockOracle), 1 hours);
    }

    function mintVusd(address user, uint256 vusdAmount) internal returns (uint256) {
        uint256 tokenAmount = gateway.previewMint(token, vusdAmount);
        deal(token, user, tokenAmount);
        console.logAddress(token);

        vm.startPrank(user);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.mint(token, vusdAmount, tokenAmount, user);
        vm.stopPrank();
        return vusd.balanceOf(user);
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
        tokenAmount = bound(tokenAmount, 0, type(uint128).max); // MorphoVault has this limit
        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(mintFee);
        deal(token, bob, tokenAmount);

        uint256 expectedVusd = gateway.previewDeposit(token, tokenAmount);
        uint256 sharesBefore = mockVault.balanceOf(address(treasury));

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.deposit(token, tokenAmount, expectedVusd, bob);
        vm.stopPrank();

        assertEq(vusd.balanceOf(bob), expectedVusd, "Incorrect VUSD minted");

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
        // update mint limit to 100 VUSD
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
        uint256 amount = 1000e18; // 1000 VUSD
        uint256 initialSupply = vusd.totalSupply();
        assertEq(vusd.balanceOf(bob), 0, "Incorrect VUSD balance");
        // owner can mint max of reserve() - totalSupply. Increase yield by depositing token to treasury
        deal(token, address(treasury), amount);
        gateway.mint(amount, bob);
        uint256 newSupply = vusd.totalSupply();
        assertEq(newSupply, initialSupply + amount, "owner should be able to mint VUSD");
        assertEq(vusd.balanceOf(bob), amount, "Incorrect VUSD balance");
    }

    function test_mint_onlyOwner_revertIfReceiverIsZeroAddress() public {
        vm.expectRevert(Gateway.AddressIsNull.selector);
        gateway.mint(100e18, address(0));
    }

    function test_mint_revertItNotAuthorized() public {
        bytes32 role = gateway.UMM_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, role));
        gateway.mint(100e18, alice);
    }

    function test_mint_onlyOwner_revertItExceededMaxMint() public {
        mockOracle.updatePrice(1e8);
        // update mint limit to 100 VUSD
        gateway.updateMintLimit(100e18);

        vm.expectRevert(abi.encodeWithSignature("ExceededMaxMint(uint256,uint256)", 101e18, 0));
        gateway.mint(101e18, bob);
    }

    // --- mint ---
    function testFuzz_mint(int256 price, uint256 mintFee, uint256 vusdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_BPS() - 1);
        vusdAmount = bound(vusdAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(mintFee);

        uint256 tokenAmount = gateway.previewMint(token, vusdAmount);
        deal(token, bob, tokenAmount);

        uint256 vusdBalanceBefore = vusd.balanceOf(bob);
        uint256 sharesBefore = mockVault.balanceOf(address(treasury));

        vm.startPrank(bob);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        gateway.mint(token, vusdAmount, tokenAmount, bob);
        vm.stopPrank();

        // Verify VUSD minted
        assertEq(vusd.balanceOf(bob), vusdBalanceBefore + vusdAmount, "Incorrect VUSD minted");

        // Verify tokens deposited in vault
        uint256 sharesAfter = mockVault.balanceOf(address(treasury));
        assertEq(sharesAfter, sharesBefore + mockVault.convertToShares(tokenAmount), "Incorrect shares in treasury");
    }

    function test_mint_revertIfTokenIsUnsupported() public {
        uint256 vusdAmount = 1000e18;
        address token2 = address(new MockERC20());
        uint256 tokenAmount = gateway.previewMint(token, vusdAmount);
        deal(token2, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token2).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.mint(token2, vusdAmount, tokenAmount, alice);
        vm.stopPrank();
    }

    function test_mint_revertIfTokenAmountIsHigherThanMax() public {
        uint256 vusdAmount = 1000e18;
        uint256 tokenAmount = gateway.previewMint(token, vusdAmount);
        deal(token, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(
            abi.encodeWithSignature("TokenAmountIsHigherThanMax(uint256,uint256)", tokenAmount, tokenAmount - 1)
        );
        gateway.mint(token, vusdAmount, tokenAmount - 1, alice);
        vm.stopPrank();
    }

    function test_mint_revertIfExceededMaxMint() public {
        // Set mint limit to 100 VUSD
        gateway.updateMintLimit(100e18);

        uint256 vusdAmount = 101e18; // Try to mint more than limit
        uint256 tokenAmount = gateway.previewMint(token, vusdAmount);
        deal(token, alice, tokenAmount);

        vm.startPrank(alice);
        IERC20(token).forceApprove(address(gateway), tokenAmount);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxMint(uint256,uint256)", vusdAmount, 100e18));
        gateway.mint(token, vusdAmount, tokenAmount, alice);
        vm.stopPrank();
    }

    // --- redeem ---
    function testFuzz_redeem(int256 price, uint256 redeemFee, uint256 vusdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        redeemFee = bound(redeemFee, 0, gateway.MAX_BPS() - 1);
        vusdAmount = bound(vusdAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Mint VUSD for testing
        mintVusd(alice, vusdAmount);

        uint256 expectedToken = gateway.previewRedeem(token, vusdAmount);
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);
        uint256 vusdBalanceBefore = vusd.balanceOf(alice);

        vm.prank(alice);
        gateway.redeem(token, vusdAmount, expectedToken, alice);

        assertEq(vusd.balanceOf(alice), vusdBalanceBefore - vusdAmount, "VUSD balance should decrease");
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
        uint256 vusdAmount = mintVusd(bob, 100e18);
        uint256 redeemable = gateway.previewRedeem(token, vusdAmount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("RedeemableIsLessThanMinimum(uint256,uint256)", redeemable, redeemable + 1)
        );
        gateway.redeem(token, vusdAmount, redeemable + 1, bob);
    }

    function test_redeem_revertIfExceededMaxWithdraw() public {
        uint256 vusdAmount = 100e18;
        mintVusd(bob, vusdAmount);

        (address _vault,,,,,) = treasury.tokenConfig(token);

        deal(_vault, address(treasury), 0);
        deal(token, address(treasury), 0);

        uint256 tokenAmount = gateway.previewRedeem(token, vusdAmount);
        uint256 maxWithdraw = gateway.maxWithdraw(token);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxWithdraw(uint256,uint256)", tokenAmount, maxWithdraw));
        gateway.redeem(token, vusdAmount, tokenAmount, bob);
    }

    // --- withdraw ---
    function testFuzz_withdraw(int256 price, uint256 redeemFee, uint256 tokenAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        redeemFee = bound(redeemFee, 0, gateway.MAX_BPS() - 1);
        tokenAmount = bound(tokenAmount, 0, type(uint128).max); // MorphoVault has this limit

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Mint VUSD for testing
        uint256 vusdAmount = gateway.previewWithdraw(token, tokenAmount);
        mintVusd(alice, vusdAmount);

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(alice);
        uint256 vusdBalanceBefore = vusd.balanceOf(alice);

        vm.prank(alice);
        gateway.withdraw(token, tokenAmount, vusdAmount, alice);

        assertEq(vusd.balanceOf(alice), vusdBalanceBefore - vusdAmount, "VUSD balance should decrease");
        assertEq(IERC20(token).balanceOf(alice) - tokenBalanceBefore, tokenAmount, "Incorrect tokens received");
    }

    function test_withdraw_revertIfTokenIsUnsupported() public {
        uint256 amount = 1000;
        address token2 = makeAddr("token2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.withdraw(token2, amount, 1, alice);
    }

    function test_withdraw_revertIfVusdAmountIsHigherThanMax() public {
        uint256 tokenAmount = 1000e6;
        uint256 vusdAmount = gateway.previewWithdraw(token, tokenAmount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature("VusdToBurnIsHigherThanMax(uint256,uint256)", vusdAmount, vusdAmount - 1)
        );
        gateway.withdraw(token, tokenAmount, vusdAmount - 1, bob);
    }

    function test_withdraw_revertIfExceededMaxWithdraw() public {
        uint256 tokenAmount = 1000e6;
        uint256 vusdAmount = gateway.previewWithdraw(token, tokenAmount);
        uint256 maxWithdraw = gateway.maxWithdraw(token);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxWithdraw(uint256,uint256)", tokenAmount, maxWithdraw));
        gateway.withdraw(token, tokenAmount, vusdAmount, bob);
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

        // Calculate expected VUSD amount
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);
        uint256 maxBps = gateway.MAX_BPS();
        uint256 amountAfterFee = amount.mulDiv((maxBps - gateway.mintFee()), maxBps);
        uint256 expectedVusd = latestPrice >= unitPrice
            ? parseAmount(amountAfterFee, token, address(vusd))
            : parseAmount(amountAfterFee.mulDiv(latestPrice, unitPrice), token, address(vusd));

        uint256 actualVusd = gateway.previewDeposit(token, amount);
        assertEq(actualVusd, expectedVusd, "Incorrect VUSD amount");
    }

    function test_previewDeposit_revertForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewDeposit(token2, 100e18);
    }

    // --- previewMint ---
    function testFuzz_previewMint(int256 price, uint256 mintFee, uint256 vusdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8);
        mintFee = bound(mintFee, 0, gateway.MAX_BPS() - 1);
        vusdAmount = bound(vusdAmount, 0, type(uint256).max / 1e18);

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateMintFee(mintFee);

        // Calculate expected token amount
        uint256 oneToken = parseAmount(1, address(0), token);
        uint256 vusdForOneToken = gateway.previewDeposit(token, oneToken);
        uint256 expectedToken = vusdAmount.mulDiv(oneToken, vusdForOneToken, Math.Rounding.Ceil);

        uint256 actualToken = gateway.previewMint(token, vusdAmount);
        assertEq(actualToken, expectedToken, "Incorrect token amount");
    }

    function test_previewMint_revertForUnsupportedToken() public {
        address token2 = address(new MockERC20());
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewMint(token2, 100e18);
    }

    // --- previewRedeem ---
    function testFuzz_previewRedeem(int256 price, uint256 redeemFee, uint256 vusdAmount) public {
        // Bound inputs
        price = bound(price, 0.998e8, 1.002e8); // Price within 0.2% of $1
        redeemFee = bound(redeemFee, 0, gateway.MAX_BPS() - 1);
        vusdAmount = bound(vusdAmount, 0, type(uint256).max / 1e18);
        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Calculate expected token amount
        (uint256 latestPrice, uint256 unitPrice) = treasury.getPrice(token);
        uint256 maxBps = gateway.MAX_BPS();
        uint256 vusdAfterFee = vusdAmount.mulDiv((maxBps - gateway.redeemFee()), maxBps);
        uint256 expectedToken = latestPrice <= unitPrice
            ? parseAmount(vusdAfterFee, address(vusd), token)
            : parseAmount(vusdAfterFee.mulDiv(unitPrice, latestPrice), address(vusd), token);

        uint256 actualToken = gateway.previewRedeem(token, vusdAmount);
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
        tokenAmount = bound(tokenAmount, 0, type(uint128).max); // MorphoVault has this limit

        // Setup test conditions
        mockOracle.updatePrice(price);
        gateway.updateRedeemFee(redeemFee);

        // Calculate expected VUSD amount
        uint256 oneVusd = parseAmount(1, address(0), address(vusd));
        uint256 tokenForOneVusd = gateway.previewRedeem(token, oneVusd);
        uint256 expectedVusd = tokenAmount.mulDiv(oneVusd, tokenForOneVusd, Math.Rounding.Ceil);

        uint256 actualVusd = gateway.previewWithdraw(token, tokenAmount);
        assertEq(actualVusd, expectedVusd, "Incorrect VUSD amount");
    }

    function test_previewWithdraw_revertForUnsupportedToken() public {
        address token2 = makeAddr("token2");
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", token2));
        gateway.previewWithdraw(token2, 100e6);
    }

    // --- update mint limit ---
    function test_updateMintLimit() public {
        uint256 newMintLimit = 1000 ether; // amount in VUSD decimal
        gateway.updateMintLimit(newMintLimit);
        assertEq(gateway.mintLimit(), newMintLimit, "Mint limit should be updated");
    }

    function test_updateMintLimit_revertIfNotAdmin() public {
        uint256 newMintLimit = 1000 ether; // amount in VUSD decimal
        bytes32 role = gateway.DEFAULT_ADMIN_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, role));
        gateway.updateMintLimit(newMintLimit);
    }

    // --- update mint fee ---
    function test_updateMintFee() public {
        uint256 newFee = 500;
        gateway.updateMintFee(newFee);
        assertEq(gateway.mintFee(), newFee, "Mint fee should be updated");
    }

    function test_updateMintFee_revertIfNotKeeper() public {
        uint256 newFee = 500;
        bytes32 role = gateway.KEEPER_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, role));
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

    function test_updateRedeemFee_revertIfNotKeeper() public {
        uint256 newFee = 500;
        bytes32 role = gateway.KEEPER_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, role));
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
        // Increase total supply by user
        mintVusd(alice, 60e18);
        assertEq(gateway.maxMint(), 40e18);
        // Set limit below current supply → zero
        gateway.updateMintLimit(10e18);
        assertEq(gateway.maxMint(), 0);
    }

    function test_maxRedeem() public {
        // With zero balance
        assertEq(gateway.maxRedeem(alice), 0);
        // mint 50 VUSD to alice
        mintVusd(alice, 50e18);
        assertEq(gateway.maxRedeem(alice), 50e18);
    }

    function test_maxWithdraw() public {
        assertEq(gateway.maxWithdraw(token), 0);

        deal(address(token), address(treasury), 50e18);
        assertEq(gateway.maxWithdraw(token), 50e18);
    }

    function test_admin_and_treasury_views() public view {
        assertEq(gateway.getRoleMember(gateway.DEFAULT_ADMIN_ROLE(), 0), owner);
        assertEq(gateway.treasury(), address(treasury));
    }
}
