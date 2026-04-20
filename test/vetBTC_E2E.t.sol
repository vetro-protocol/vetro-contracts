// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {DerivedPriceFeedAdapter} from "src/DerivedPriceFeedAdapter.sol";
import {cbBTC, CBBTC_USD_FEED, BTC_USD_FEED} from "test/helpers/Address.ethereum.sol";

/// @dev Bare-minimum ERC-4626 vault wrapping cbBTC. No strategy — 1 share = 1 asset forever.
contract MockCbBTCVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock cbBTC Vault", "mcbBTC") ERC4626(asset_) {}
}

contract vetBTC_E2E_Test is Test {
    PeggedToken vetBTC;
    Gateway gateway;
    Treasury treasury;
    DerivedPriceFeedAdapter cbBtcBtcFeed;
    MockCbBTCVault cbBtcVault;

    address owner;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork("ethereum");

        owner = address(this);

        // Deploy DerivedPriceFeedAdapter: cbBTC/USD ÷ BTC/USD = cbBTC/BTC
        cbBtcBtcFeed =
            new DerivedPriceFeedAdapter(AggregatorV2V3Interface(CBBTC_USD_FEED), AggregatorV2V3Interface(BTC_USD_FEED));

        // Deploy a passthrough ERC-4626 vault wrapping real cbBTC
        cbBtcVault = new MockCbBTCVault(IERC20(cbBTC));

        // Deploy core contracts
        vetBTC = new PeggedToken("Vetro BTC", "vetBTC", owner);
        treasury = new Treasury(address(vetBTC), owner);
        vetBTC.updateTreasury(address(treasury));

        Gateway implementation = new Gateway();
        bytes memory initData =
            abi.encodeWithSelector(Gateway.initialize.selector, address(vetBTC), type(uint256).max, 7 days);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        gateway = Gateway(address(proxy));

        vetBTC.updateGateway(address(gateway));
        treasury.grantRole(treasury.UMM_ROLE(), owner);
        gateway.setWithdrawalDelayEnabled(false);

        // cbBTC/BTC can trade at ~1-2% discount; widen treasury tolerance to accommodate
        treasury.updatePriceTolerance(200); // 2% (200 BPS)

        // Whitelist cbBTC backed by mock vault, priced via DerivedPriceFeedAdapter
        // cbBTC/BTC Chainlink feeds update every 24 hours
        treasury.addToWhitelist(cbBTC, address(cbBtcVault), address(cbBtcBtcFeed), 24 hours);
    }

    function test_derivedFeed_matchesManualCalculation() public view {
        (, int256 btcUsd,,,) = AggregatorV2V3Interface(BTC_USD_FEED).latestRoundData();
        (, int256 cbBtcUsd,,,) = AggregatorV2V3Interface(CBBTC_USD_FEED).latestRoundData();
        (, int256 derived,,,) = cbBtcBtcFeed.latestRoundData();

        int256 expected = (cbBtcUsd * 1e8) / btcUsd;
        assertEq(derived, expected);
        // cbBTC/BTC should be close to 1 (within 5% — cbBTC may trade at a small discount)
        assertGt(derived, 0.95e8);
        assertLt(derived, 1.05e8);
    }

    function test_deposit_cbBTC_mintsvetBTC() public {
        uint256 cbBtcAmount = 1e8; // 1 cbBTC (8 decimals)
        deal(cbBTC, alice, cbBtcAmount);

        uint256 sharesBefore = IERC20(address(cbBtcVault)).balanceOf(address(treasury));

        vm.startPrank(alice);
        IERC20(cbBTC).approve(address(gateway), cbBtcAmount);
        uint256 expectedvetBTCOut = gateway.previewDeposit(cbBTC, cbBtcAmount);
        gateway.deposit(cbBTC, cbBtcAmount, expectedvetBTCOut, alice);
        vm.stopPrank();

        assertEq(vetBTC.balanceOf(alice), expectedvetBTCOut);
        assertGt(IERC20(address(cbBtcVault)).balanceOf(address(treasury)), sharesBefore);
    }

    function test_redeem_vetBTC_returnsCollateral() public {
        uint256 cbBtcAmount = 1e8; // 1 cbBTC
        deal(cbBTC, alice, cbBtcAmount);

        vm.startPrank(alice);
        IERC20(cbBTC).approve(address(gateway), cbBtcAmount);
        uint256 expectedvetBTCOut = gateway.previewDeposit(cbBTC, cbBtcAmount);
        gateway.deposit(cbBTC, cbBtcAmount, expectedvetBTCOut, alice);

        uint256 vetBTCIn = vetBTC.balanceOf(alice);
        uint256 expectedCbBtcOut = gateway.previewRedeem(cbBTC, vetBTCIn);
        gateway.redeem(cbBTC, vetBTCIn, expectedCbBtcOut, alice);
        vm.stopPrank();

        assertEq(vetBTC.balanceOf(alice), 0);
        assertEq(IERC20(cbBTC).balanceOf(alice), expectedCbBtcOut);
    }

    function test_mint_excess_after_yield() public {
        uint256 cbBtcAmount = 1e8; // 1 cbBTC
        deal(cbBTC, alice, cbBtcAmount);

        vm.startPrank(alice);
        IERC20(cbBTC).approve(address(gateway), cbBtcAmount);
        uint256 expectedvetBTCOut = gateway.previewDeposit(cbBTC, cbBtcAmount);
        gateway.deposit(cbBTC, cbBtcAmount, expectedvetBTCOut, alice);
        vm.stopPrank();

        assertEq(vetBTC.totalSupply(), expectedvetBTCOut);

        // Simulate yield: add cbBTC directly to vault
        uint256 yieldAmount = 0.01e8; // 0.01 cbBTC
        deal(cbBTC, address(cbBtcVault), IERC20(cbBTC).balanceOf(address(cbBtcVault)) + yieldAmount);

        uint256 reserveAfterYield = treasury.reserve();
        uint256 supplyBeforeMint = vetBTC.totalSupply();
        uint256 excess = reserveAfterYield - supplyBeforeMint;
        assertGt(excess, 0);

        gateway.updateAmoMintLimit(excess);
        gateway.mintToAMO(excess, owner);

        assertEq(vetBTC.balanceOf(owner), excess);
        assertEq(vetBTC.totalSupply(), supplyBeforeMint + excess);
        assertEq(treasury.reserve(), vetBTC.totalSupply());
    }
}
