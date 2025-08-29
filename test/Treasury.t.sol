// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "src/Treasury.sol";
import {VUSD} from "src/VUSD.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockMorphoVaultV2} from "test/mocks/MockMorphoVaultV2.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";

contract TreasuryTest is Test {
    Treasury treasury;
    VUSD vusd;
    MockERC20 token;
    MockMorphoVaultV2 mockVault;
    MockChainlinkOracle mockOracle;
    address owner;
    address keeper = makeAddr("keeper");
    address gateway = makeAddr("gateway");
    address alice = makeAddr("alice");

    uint256 constant TOKEN_UNIT = 1e6; // 6 decimals
    uint256 constant VAULT_UNIT = 1e18; // 18 decimals

    function setUp() public {
        owner = address(this);
        vusd = new VUSD(owner);
        treasury = new Treasury(address(vusd));
        vusd.updateTreasury(address(treasury));
        vusd.updateGateway(gateway);
        token = new MockERC20();
        mockVault = new MockMorphoVaultV2(address(token));
        mockOracle = new MockChainlinkOracle(1e8); // $1
        // Add token to whitelist
        treasury.addToWhitelist(address(token), address(mockVault), address(mockOracle), 1 hours);
    }

    // --- addToWhitelist ---
    function test_addToWhitelist_success() public {
        MockERC20 _token2 = new MockERC20();
        MockMorphoVaultV2 _vault2 = new MockMorphoVaultV2(address(_token2));
        MockChainlinkOracle _oracle2 = new MockChainlinkOracle(1e8);
        treasury.addToWhitelist(address(_token2), address(_vault2), address(_oracle2), 1 hours);
        assertTrue(treasury.isWhitelistedToken(address(_token2)));
    }

    function test_addToWhitelist_revertOnZeroAddress() public {
        vm.expectRevert(Treasury.AddressIsZero.selector);
        treasury.addToWhitelist(address(0), address(mockVault), address(mockOracle), 1 hours);
    }

    function test_addToWhitelist_revertOnStalePeriodZero() public {
        vm.expectRevert(Treasury.InvalidStalePeriod.selector);
        treasury.addToWhitelist(address(token), address(mockVault), address(mockOracle), 0);
    }

    function test_addToWhitelist_revertOnAssetMismatch() public {
        MockERC20 _fakeToken = new MockERC20();
        vm.expectRevert(Treasury.AssetMismatch.selector);
        treasury.addToWhitelist(address(_fakeToken), address(mockVault), address(mockOracle), 1 hours);
    }

    // --- removeFromWhitelist ---
    function test_removeFromWhitelist_success() public {
        treasury.removeFromWhitelist(address(token));
        assertFalse(treasury.isWhitelistedToken(address(token)));
    }

    function test_removeFromWhitelist_revertIfNotWhitelisted() public {
        MockERC20 _token2 = new MockERC20();
        vm.expectRevert(Treasury.RemoveFromListFailed.selector);
        treasury.removeFromWhitelist(address(_token2));
    }

    // --- addKeeper ---
    function test_addKeeper_success() public {
        treasury.addKeeper(keeper);
        assertTrue(treasury.isKeeper(keeper));
    }

    function test_addKeeper_revertOnZeroAddress() public {
        vm.expectRevert(Treasury.AddressIsZero.selector);
        treasury.addKeeper(address(0));
    }

    // --- removeKeeper ---
    function test_removeKeeper_success() public {
        treasury.addKeeper(keeper);
        treasury.removeKeeper(keeper);
        assertFalse(treasury.isKeeper(keeper));
    }

    function test_removeKeeper_revertIfNotPresent() public {
        vm.expectRevert(Treasury.RemoveFromListFailed.selector);
        treasury.removeKeeper(keeper);
    }

    // --- migrate ---
    function test_migrate_success() public {
        Treasury _newTreasury = new Treasury(address(vusd));
        uint256 _tokenAmount = 100 * TOKEN_UNIT; // 100 tokens
        uint256 _vaultShares = 50 * VAULT_UNIT; // 50 shares
        deal(address(token), address(treasury), _tokenAmount);
        deal(address(mockVault), address(treasury), _vaultShares);
        // Migrate
        treasury.migrate(address(_newTreasury));
        assertEq(token.balanceOf(address(_newTreasury)), _tokenAmount);
        assertEq(mockVault.balanceOf(address(_newTreasury)), _vaultShares);
    }

    function test_migrate_revertOnZeroAddress() public {
        vm.expectRevert(Treasury.AddressIsZero.selector);
        treasury.migrate(address(0));
    }

    function test_migrate_revertOnVUSDMismatch() public {
        VUSD _fakeVUSD = new VUSD(owner);
        Treasury _newTreasury = new Treasury(address(_fakeVUSD));
        vm.expectRevert(Treasury.VUSDMismatch.selector);
        treasury.migrate(address(_newTreasury));
    }

    // --- sweep ---
    function test_sweep_success() public {
        MockERC20 _other = new MockERC20();
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        deal(address(_other), address(treasury), _tokenAmount);
        treasury.sweep(address(_other), alice);
        assertEq(_other.balanceOf(alice), _tokenAmount);
    }

    function test_sweep_revertOnReservedToken() public {
        vm.expectRevert(Treasury.ReservedToken.selector);
        treasury.sweep(address(token), alice);
    }

    function test_sweep_revertOnZeroReceiver() public {
        MockERC20 _other = new MockERC20();
        vm.expectRevert(Treasury.AddressIsZero.selector);
        treasury.sweep(address(_other), address(0));
    }

    // --- updateOracle ---
    function test_updateOracle_success() public {
        address _newOracle = address(new MockChainlinkOracle(2e8));
        treasury.updateOracle(address(token), _newOracle, 2 hours);
        (, address _oracle, uint256 _stalePeriod,,) = treasury.tokenConfig(address(token));
        assertEq(_oracle, _newOracle);
        assertEq(_stalePeriod, 2 hours);
    }

    function test_updateOracle_revertIfNotWhitelisted() public {
        MockERC20 _token2 = new MockERC20();
        MockChainlinkOracle _oracle2 = new MockChainlinkOracle(1e8);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        treasury.updateOracle(address(_token2), address(_oracle2), 1 hours);
    }

    function test_updateOracle_revertOnZeroAddress() public {
        vm.expectRevert(Treasury.AddressIsZero.selector);
        treasury.updateOracle(address(token), address(0), 1 hours);
    }

    function test_updateOracle_revertOnStalePeriodZero() public {
        MockChainlinkOracle _newOracle = new MockChainlinkOracle(2e8);
        vm.expectRevert(Treasury.InvalidStalePeriod.selector);
        treasury.updateOracle(address(token), address(_newOracle), 0);
    }

    // --- updatePriceTolerance ---
    function test_updatePriceTolerance_success() public {
        treasury.updatePriceTolerance(500);
        assertEq(treasury.priceTolerance(), 500);
    }

    function test_updatePriceTolerance_revertIfTooHigh() public {
        uint256 _max = treasury.MAX_BPS();
        vm.expectRevert(Treasury.InvalidPriceTolerance.selector);
        treasury.updatePriceTolerance(_max + 1);
    }

    // --- updateSwapper ---
    function test_updateSwapper_success() public {
        address _newSwapper = makeAddr("newSwapper");
        treasury.updateSwapper(_newSwapper);
        assertEq(treasury.swapper(), _newSwapper);
    }

    function test_updateSwapper_revertOnZeroAddress() public {
        vm.expectRevert(Treasury.AddressIsZero.selector);
        treasury.updateSwapper(address(0));
    }

    // --- withdrawAll ---
    function test_withdrawAll_success() public {
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        deal(address(token), address(treasury), _tokenAmount);
        treasury.push(address(token), _tokenAmount);

        address[] memory _tokens = new address[](1);
        _tokens[0] = address(token);
        assertEq(token.balanceOf(alice), 0);
        treasury.withdrawAll(_tokens, alice);
        assertEq(token.balanceOf(alice), _tokenAmount);
    }

    function test_withdrawAll_revertOnZeroReceiver() public {
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(token);
        vm.expectRevert(Treasury.AddressIsZero.selector);
        treasury.withdrawAll(_tokens, address(0));
    }

    function test_withdrawAll_revertIfNotWhitelisted() public {
        MockERC20 _token2 = new MockERC20();
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(_token2);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        treasury.withdrawAll(_tokens, alice);
    }

    // --- deposit onlyGateway ---
    function test_deposit_onlyGateway_success() public {
        uint256 _tokenAmount = 10 * TOKEN_UNIT;
        deal(address(token), address(treasury), _tokenAmount);
        vm.prank(gateway);
        treasury.deposit(address(token), _tokenAmount);
        assertEq(mockVault.balanceOf(address(treasury)), mockVault.convertToShares(_tokenAmount));
    }

    function test_deposit_onlyGateway_revertIfNotWhitelisted() public {
        MockERC20 _token2 = new MockERC20();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        vm.prank(gateway);
        treasury.deposit(address(_token2), 10 * TOKEN_UNIT);
    }

    function test_deposit_onlyGateway_revertIfDepositPaused() public {
        treasury.toggleDepositActive(address(token));
        vm.expectRevert(abi.encodeWithSignature("DepositIsPaused(address)", token));
        vm.prank(gateway);
        treasury.deposit(address(token), 10 * TOKEN_UNIT);
    }

    // --- withdraw onlyGateway ---
    function test_withdraw_onlyGateway_withdrawFromVault() public {
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        deal(address(token), address(treasury), _tokenAmount);
        treasury.push(address(token), _tokenAmount);

        assertEq(token.balanceOf(alice), 0);
        vm.prank(gateway);
        treasury.withdraw(address(token), _tokenAmount / 2, alice);
        assertEq(token.balanceOf(alice), _tokenAmount / 2);
    }

    function test_withdraw_onlyGateway_withdrawFromTreasury() public {
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        deal(address(token), address(treasury), _tokenAmount);

        assertEq(token.balanceOf(alice), 0);
        vm.prank(gateway);
        treasury.withdraw(address(token), _tokenAmount / 2, alice);
        assertEq(token.balanceOf(alice), _tokenAmount / 2);
    }

    function test_withdraw_onlyGateway_withdrawFromTreasuryAndVault() public {
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        deal(address(token), address(treasury), _tokenAmount);
        // push half to vault and keep half in treasury
        treasury.push(address(token), _tokenAmount / 2);

        assertEq(token.balanceOf(alice), 0);
        vm.prank(gateway);
        // withdraw _tokenAmount
        treasury.withdraw(address(token), _tokenAmount, alice);
        assertEq(token.balanceOf(alice), _tokenAmount);
    }

    function test_withdraw_onlyGateway_revertIfNotWhitelisted() public {
        MockERC20 _token2 = new MockERC20();

        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        vm.prank(gateway);
        treasury.withdraw(address(_token2), 10 * TOKEN_UNIT, alice);
    }

    function test_withdraw_onlyGateway_revertIfWithdrawPaused() public {
        treasury.toggleWithdrawActive(address(token));
        vm.expectRevert(abi.encodeWithSignature("WithdrawIsPaused(address)", token));
        vm.prank(gateway);
        treasury.withdraw(address(token), 10 * TOKEN_UNIT, alice);
    }

    // --- push ---
    function test_push_onlyKeeper_success() public {
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        treasury.addKeeper(keeper);
        deal(address(token), address(treasury), _tokenAmount);
        treasury.push(address(token), _tokenAmount);
        assertEq(mockVault.balanceOf(address(treasury)), _tokenAmount * VAULT_UNIT / TOKEN_UNIT);
    }

    function test_push_onlyKeeper_revertIfNotWhitelisted() public {
        treasury.addKeeper(keeper);
        MockERC20 _token2 = new MockERC20();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        vm.prank(keeper);
        treasury.push(address(_token2), 10 * TOKEN_UNIT);
    }

    // --- pull ---
    function test_pull_onlyKeeper_success() public {
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        treasury.addKeeper(keeper);
        deal(address(token), address(treasury), _tokenAmount);
        treasury.push(address(token), _tokenAmount);
        assertEq(token.balanceOf(address(treasury)), 0);
        vm.prank(keeper);
        // pull half of the amount
        treasury.pull(address(token), _tokenAmount / 2);
        assertEq(token.balanceOf(address(treasury)), _tokenAmount / 2);
    }

    function test_pull_onlyKeeper_revertIfNotWhitelisted() public {
        treasury.addKeeper(keeper);
        MockERC20 _token2 = new MockERC20();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        vm.prank(keeper);
        treasury.pull(address(_token2), 10 * TOKEN_UNIT);
    }

    // --- toggleDepositActive ---
    function test_toggleDepositActive_onlyKeeper_success() public {
        treasury.addKeeper(keeper);
        (,,, bool depositActiveBefore,) = treasury.tokenConfig(address(token));
        vm.prank(keeper);
        treasury.toggleDepositActive(address(token));
        (,,, bool depositActiveAfter,) = treasury.tokenConfig(address(token));

        assertTrue(depositActiveBefore != depositActiveAfter);
    }

    function test_toggleDepositActive_onlyKeeper_revertIfNotWhitelisted() public {
        treasury.addKeeper(keeper);
        MockERC20 _token2 = new MockERC20();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        vm.prank(keeper);
        treasury.toggleDepositActive(address(_token2));
    }

    // --- toggleWithdrawActive ---
    function test_toggleWithdrawActive_onlyKeeper_success() public {
        treasury.addKeeper(keeper);
        (,,,, bool withdrawActiveBefore) = treasury.tokenConfig(address(token));
        vm.prank(keeper);
        treasury.toggleWithdrawActive(address(token));
        (,,,, bool withdrawActiveAfter) = treasury.tokenConfig(address(token));
        assertTrue(withdrawActiveBefore != withdrawActiveAfter);
    }

    function test_toggleWithdrawActive_onlyKeeper_revertIfNotWhitelisted() public {
        treasury.addKeeper(keeper);
        MockERC20 _token2 = new MockERC20();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", _token2));
        vm.prank(keeper);
        treasury.toggleWithdrawActive(address(_token2));
    }

    // --- swap ---
    function test_swap_onlyKeeper_success() public {
        address _swapper = address(new MockSwapper());
        treasury.updateSwapper(_swapper);
        deal(address(token), _swapper, 10000 * TOKEN_UNIT);

        MockERC20 _other = new MockERC20();
        uint256 _amountIn = 100 * TOKEN_UNIT;
        deal(address(_other), address(treasury), _amountIn);

        assertEq(token.balanceOf(address(treasury)), 0);
        uint256 _minAmountOut = 500 * TOKEN_UNIT;
        treasury.addKeeper(keeper);
        vm.prank(keeper);
        treasury.swap(address(_other), address(token), _amountIn, _minAmountOut);

        assertGt(token.balanceOf(address(treasury)), _minAmountOut);
    }

    function test_swap_onlyKeeper_revertIfReservedToken() public {
        treasury.addKeeper(keeper);
        vm.expectRevert(Treasury.ReservedToken.selector);
        vm.prank(keeper);
        treasury.swap(address(token), address(token), 10 * TOKEN_UNIT, 1);
    }

    // --- getters ---
    function test_getPrice_success() public view {
        (uint256 _latest, uint256 _unitPrice) = treasury.getPrice(address(token));
        assertEq(_latest, 1e8);
        assertEq(_unitPrice, 1e8);
    }

    function test_getPrice_revertIfStale() public {
        vm.warp(2 hours);
        vm.expectRevert(Treasury.StalePrice.selector);
        treasury.getPrice(address(token));
    }

    function test_getPrice_revertIfOutOfTolerance() public {
        mockOracle.updatePrice(2e8); // $2
        vm.expectRevert(abi.encodeWithSignature("PriceExceedTolerance(uint256,uint256,uint256)", 2e8, 1.01e8, 0.99e8));
        treasury.getPrice(address(token));
    }

    function test_isWhitelistedToken() public view {
        assertTrue(treasury.isWhitelistedToken(address(token)));
    }

    function test_keepers() public view {
        address[] memory _keepers = treasury.keepers();
        assertTrue(_keepers.length > 0);
    }

    function test_whitelistedTokens() public view {
        address[] memory _tokens = treasury.whitelistedTokens();
        assertTrue(_tokens.length > 0);
    }

    function test_withdrawable() public {
        uint256 _tokenAmount = 100 * TOKEN_UNIT;
        treasury.addKeeper(keeper);
        deal(address(token), address(treasury), _tokenAmount);
        vm.prank(keeper);
        // push half amount
        treasury.push(address(token), 50 * TOKEN_UNIT);

        uint256 _withdrawable = treasury.withdrawable(address(token));
        // withdrawable should include token balance in treasury and vault
        assertEq(_withdrawable, _tokenAmount);
    }

    function test_withdrawable_zeroIfNotWhitelisted() public {
        MockERC20 _token2 = new MockERC20();
        assertEq(treasury.withdrawable(address(_token2)), 0);
    }
}
