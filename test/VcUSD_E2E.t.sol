// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {USDC, tvUSDC, COMPOUND_V3_STRATEGY, USDC_USD_FEED} from "test/helpers/Address.ethereum.sol";

interface IStrategy {
    function keepers() external view returns (address[] memory);

    function rebalance(uint256 minProfit_, uint256 maxLoss_)
        external
        returns (uint256 _profit, uint256 _loss, uint256 _payback);

    function tvl() external view returns (uint256);
}

contract VcUSD_E2E_Test is Test {
    PeggedToken vcUSD;
    Gateway gateway;
    Treasury treasury;
    address owner;
    address alice = makeAddr("alice");
    address usdcVault;

    function setUp() public {
        vm.createSelectFork("ethereum");

        owner = address(this);
        usdcVault = tvUSDC;
        // Deploy core contracts
        vcUSD = new PeggedToken("viaUSD", "viaUSD", owner);
        treasury = new Treasury(address(vcUSD));
        vcUSD.updateTreasury(address(treasury));

        // Set a large mint limit for E2E
        gateway = new Gateway(address(vcUSD), type(uint256).max);
        vcUSD.updateGateway(address(gateway));

        // Whitelist USDC backed by real usdcVault using Chainlink USDC/USD feed
        treasury.addToWhitelist(USDC, usdcVault, USDC_USD_FEED, 24 hours);
    }

    function test_deposit_pushesFundsIntoVault() public {
        uint256 _usdcAmount = 100e6; // 100 USDC
        deal(USDC, alice, _usdcAmount);

        // Record vault shares before deposit
        uint256 _sharesBefore = IERC20(usdcVault).balanceOf(address(treasury));
        uint256 _expectedShares = IERC4626(usdcVault).convertToShares(_usdcAmount);

        // Deposit
        vm.startPrank(alice);
        IERC20(USDC).approve(address(gateway), _usdcAmount);
        uint256 _expectedViaUsdOut = gateway.previewDeposit(USDC, _usdcAmount);
        gateway.deposit(USDC, _usdcAmount, _expectedViaUsdOut, alice);
        vm.stopPrank();

        // Verify correct amount of viaUSD was minted to depositor
        assertEq(vcUSD.balanceOf(alice), _expectedViaUsdOut);

        // Verify treasury received the expected vault shares
        uint256 _sharesAfter = IERC20(usdcVault).balanceOf(address(treasury));
        assertEq(_sharesAfter - _sharesBefore, _expectedShares);
    }

    function test_redeem_afterStrategyRebalance() public {
        IStrategy _strategy = IStrategy(COMPOUND_V3_STRATEGY);
        uint256 _usdcAmount = 100e6; // 100 USDC
        deal(USDC, alice, _usdcAmount);

        // Step 1: Deposit USDC via gateway
        vm.startPrank(alice);
        IERC20(USDC).approve(address(gateway), _usdcAmount);
        uint256 _expectedViaUsdOut = gateway.previewDeposit(USDC, _usdcAmount);
        gateway.deposit(USDC, _usdcAmount, _expectedViaUsdOut, alice);
        vm.stopPrank();

        // Step 2: Trigger strategy rebalance to deploy funds
        address _keeper = _strategy.keepers()[0];
        vm.prank(_keeper);
        _strategy.rebalance(0, 0);
        // Verify strategy received funds
        assertGt(_strategy.tvl(), 0);

        // Step 3: Redeem viaUSD for USDC
        uint256 _viaUsdIn = vcUSD.balanceOf(alice);
        uint256 _expectedUsdcOut = gateway.previewRedeem(USDC, _viaUsdIn);
        vm.prank(alice);
        gateway.redeem(USDC, _viaUsdIn, _expectedUsdcOut, alice);

        // Step 4: Verify redemption worked correctly
        assertEq(vcUSD.balanceOf(alice), 0);
        assertEq(IERC20(USDC).balanceOf(alice), _expectedUsdcOut);
    }

    function test_mint_excess_after_yield() public {
        uint256 _usdcAmount = 100e6; // 100 USDC
        deal(USDC, alice, _usdcAmount);

        // Step 1: Deposit USDC via gateway
        vm.startPrank(alice);
        IERC20(USDC).approve(address(gateway), _usdcAmount);
        uint256 _expectedViaUsdOut = gateway.previewDeposit(USDC, _usdcAmount);
        gateway.deposit(USDC, _usdcAmount, _expectedViaUsdOut, alice);
        vm.stopPrank();

        // Verify initial state: reserve equals supply
        assertEq(vcUSD.totalSupply(), _expectedViaUsdOut);

        // Step 2: Simulate yield by dealing additional USDC into vault
        uint256 _yieldAmount = 10e6; // 10 USDC yield
        deal(USDC, usdcVault, IERC20(USDC).balanceOf(usdcVault) + _yieldAmount);

        // Step 3: Verify reserve increased due to yield
        uint256 _reserveAfterYield = treasury.reserve();
        uint256 _supplyBeforeMint = vcUSD.totalSupply();
        uint256 _excess = _reserveAfterYield - _supplyBeforeMint;
        assertGt(_excess, 0);

        // Step 4: Owner mints the excess reserve
        uint256 _mintAmount = _excess;
        vm.prank(owner);
        gateway.mint(_mintAmount, owner);

        // Step 5: Verify mint captured excess correctly
        assertEq(vcUSD.balanceOf(owner), _mintAmount);
        assertEq(vcUSD.totalSupply(), _supplyBeforeMint + _mintAmount);
        assertEq(treasury.reserve(), vcUSD.totalSupply());
    }
}

