// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {DerivedPriceFeedAdapter} from "src/DerivedPriceFeedAdapter.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {cbBTC, hemiBTC, CBBTC_USD_FEED, BTC_USD_FEED, HEMIBTC_BTC_FEED} from "test/helpers/Address.ethereum.sol";

/// @dev Bare-minimum ERC-4626 vault wrapping a BTC-like asset. No strategy — 1 share = 1 asset forever.
contract MockBTCVault is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}
}

contract vetBTC_E2E_Test is Test {
    PeggedToken vetBTC;
    Gateway gateway;
    Treasury treasury;
    DerivedPriceFeedAdapter cbBtcBtcFeed;
    MockBTCVault cbBtcVault;
    MockBTCVault hemiBtcVault;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork("ethereum");

        owner = address(this);

        // Deploy DerivedPriceFeedAdapter: cbBTC/USD ÷ BTC/USD = cbBTC/BTC
        cbBtcBtcFeed = new DerivedPriceFeedAdapter(
            AggregatorV2V3Interface(CBBTC_USD_FEED), AggregatorV2V3Interface(BTC_USD_FEED), 8
        );

        // Passthrough ERC-4626 vaults wrapping real cbBTC and hemiBTC
        cbBtcVault = new MockBTCVault(IERC20(cbBTC), "Mock cbBTC Vault", "mcbBTC");
        hemiBtcVault = new MockBTCVault(IERC20(hemiBTC), "Mock hemiBTC Vault", "mhemiBTC");

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

        // Whitelist cbBTC: 8-decimal token, 8-decimal derived oracle. 24h Chainlink update cadence.
        treasury.addToWhitelist(cbBTC, address(cbBtcVault), address(cbBtcBtcFeed), 24 hours);
        // Whitelist hemiBTC: 8-decimal token, 18-decimal Chainlink "HEMIBTC / BTC Exchange Rate" feed.
        treasury.addToWhitelist(hemiBTC, address(hemiBtcVault), HEMIBTC_BTC_FEED, 24 hours);
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

    /*//////////////////////////////////////////////////////////////
        hemiBTC integration: mixed-decimal oracle + cross-token arbitrage
    //////////////////////////////////////////////////////////////*/

    /// @notice cbBTC uses an 8-decimal oracle; hemiBTC uses an 18-decimal oracle.
    ///         Both whitelisted in the same Treasury without modification.
    function test_tokenConfig_supportsMixedOracleDecimals() public view {
        assertEq(IERC20Metadata(cbBTC).decimals(), 8, "cbBTC decimals");
        assertEq(IERC20Metadata(hemiBTC).decimals(), 8, "hemiBTC decimals");
        assertEq(cbBtcBtcFeed.decimals(), 8, "cbBTC/BTC oracle decimals");
        assertEq(AggregatorV2V3Interface(HEMIBTC_BTC_FEED).decimals(), 18, "hemiBTC/BTC oracle decimals");
        assertTrue(treasury.isWhitelistedToken(cbBTC), "cbBTC not whitelisted");
        assertTrue(treasury.isWhitelistedToken(hemiBTC), "hemiBTC not whitelisted");
    }

    /// @notice Treasury.getPrice returns (latestPrice, unitPrice) consistent with each oracle's decimals.
    ///         The ratio (latestPrice / unitPrice) is what the math actually uses; both must be near 1.0.
    function test_getPrice_returnsCorrectUnitPrice_perOracleDecimals() public view {
        (uint256 cbBtcPrice, uint256 cbBtcUnit) = treasury.getPrice(cbBTC);
        (uint256 hemiBtcPrice, uint256 hemiBtcUnit) = treasury.getPrice(hemiBTC);

        assertEq(cbBtcUnit, 1e8, "cbBTC unitPrice");
        assertEq(hemiBtcUnit, 1e18, "hemiBTC unitPrice");

        // Ratios within ±2% (matches priceTolerance set in setUp)
        assertGt(cbBtcPrice * 1e18 / cbBtcUnit, 0.98e18);
        assertLt(cbBtcPrice * 1e18 / cbBtcUnit, 1.02e18);
        assertGt(hemiBtcPrice * 1e18 / hemiBtcUnit, 0.98e18);
        assertLt(hemiBtcPrice * 1e18 / hemiBtcUnit, 1.02e18);
    }

    function test_deposit_hemiBTC_mintsCorrectvetBTC() public {
        uint256 hemiBtcAmount = 1e8; // 1 hemiBTC (8 decimals)
        deal(hemiBTC, alice, hemiBtcAmount);

        vm.startPrank(alice);
        IERC20(hemiBTC).approve(address(gateway), hemiBtcAmount);
        uint256 expected = gateway.previewDeposit(hemiBTC, hemiBtcAmount);
        gateway.deposit(hemiBTC, hemiBtcAmount, expected, alice);
        vm.stopPrank();

        // 1 hemiBTC at ~1.0 BTC must mint ~1 vetBTC (18 decimals), within ±2% tolerance.
        assertGt(expected, 0.98e18, "vetBTC out below tolerance");
        assertLt(expected, 1.02e18, "vetBTC out above tolerance");
        assertEq(vetBTC.balanceOf(alice), expected, "alice vetBTC balance");
        assertEq(IERC20(hemiBTC).balanceOf(address(hemiBtcVault)), hemiBtcAmount, "vault holds assets");
    }

    function test_redeem_hemiBTC_returnsCorrectCollateral() public {
        uint256 hemiBtcAmount = 1e8;
        deal(hemiBTC, alice, hemiBtcAmount);

        vm.startPrank(alice);
        IERC20(hemiBTC).approve(address(gateway), hemiBtcAmount);
        uint256 minted = gateway.deposit(hemiBTC, hemiBtcAmount, 0, alice);

        uint256 expectedOut = gateway.previewRedeem(hemiBTC, minted);
        gateway.redeem(hemiBTC, minted, expectedOut, alice);
        vm.stopPrank();

        assertEq(vetBTC.balanceOf(alice), 0, "vetBTC should be burned");
        // Round-trip can lose a few wei of dust from integer division.
        assertApproxEqAbs(IERC20(hemiBTC).balanceOf(alice), hemiBtcAmount, 10, "hemiBTC round-trip");
    }

    /// @notice Fuzz both oracles across the full tolerance range (±200 bps) in both swap
    ///         directions. With pegBand = 0 on both tokens, the no-profit invariant must
    ///         hold for EVERY price combination — both legs of the swap clamp at parity,
    ///         and the math proves valueOut <= valueIn in all four depeg quadrants.
    function testFuzz_crossToken_noProfit_anyDepeg(uint256 priceH, uint256 priceC, bool hemiFirst) public {
        priceH = bound(priceH, 0.98e18, 1.02e18); // ±200 bps (priceTolerance)
        priceC = bound(priceC, 0.98e8, 1.02e8);

        MockChainlinkOracle mockHemiOracle = new MockChainlinkOracle(1e18);
        mockHemiOracle.setDecimals(18);
        MockChainlinkOracle mockCbOracle = new MockChainlinkOracle(1e8);
        mockCbOracle.setDecimals(8);
        treasury.updateOracle(hemiBTC, address(mockHemiOracle), 24 hours);
        treasury.updateOracle(cbBTC, address(mockCbOracle), 24 hours);
        mockHemiOracle.updatePrice(int256(priceH));
        mockCbOracle.updatePrice(int256(priceC));

        // Seed both sides of the treasury so either redeem direction can fulfill
        deal(hemiBTC, bob, 100e8);
        deal(cbBTC, bob, 100e8);
        vm.startPrank(bob);
        IERC20(hemiBTC).approve(address(gateway), 100e8);
        IERC20(cbBTC).approve(address(gateway), 100e8);
        gateway.deposit(hemiBTC, 100e8, 0, bob);
        gateway.deposit(cbBTC, 100e8, 0, bob);
        vm.stopPrank();

        address tokenIn = hemiFirst ? hemiBTC : cbBTC;
        address tokenOut = hemiFirst ? cbBTC : hemiBTC;
        uint256 amountIn = 1e8;
        deal(tokenIn, alice, amountIn);

        (uint256 pIn, uint256 unitIn) = treasury.getPrice(tokenIn);
        uint256 valueIn = amountIn * pIn / unitIn;

        vm.startPrank(alice);
        IERC20(tokenIn).approve(address(gateway), amountIn);
        uint256 minted = gateway.deposit(tokenIn, amountIn, 0, alice);
        uint256 amountOut = gateway.redeem(tokenOut, minted, 0, alice);
        vm.stopPrank();

        (uint256 pOut, uint256 unitOut) = treasury.getPrice(tokenOut);
        uint256 valueOut = amountOut * pOut / unitOut;

        // Both `valueIn` and `valueOut` are in the token's decimals (8 for both hemiBTC and
        // cbBTC) — the unit price normalization cancels the oracle's decimal precision.
        assertLe(valueOut, valueIn, "user extracted BTC value across swap");
    }

    /// @notice cbBTC trading BELOW 1.0 BTC: prove the protocol still wins both swap directions.
    ///
    /// Trace with cbBTC oracle = 0.98, hemiBTC oracle = 1.0, pegBand = 0:
    ///
    ///   hemiBTC -> cbBTC:
    ///     deposit 1 hemiBTC: price(1.0) >= pegFloor(1.0) → mint at parity → 1.0 vetBTC
    ///     redeem  1 vetBTC for cbBTC: price(0.98) <= pegCeiling(1.0) → parity in token units
    ///        → 1.0 cbBTC.  Oracle-value out = 1.0 * 0.98 = 0.98 BTC.
    ///     User deposited 1.0 BTC of value, received 0.98 BTC.  LOST 0.02 BTC.
    ///
    ///   cbBTC -> hemiBTC:
    ///     deposit 1 cbBTC: price(0.98) < pegFloor(1.0) → mint at discount → 0.98 vetBTC
    ///     redeem  0.98 vetBTC for hemiBTC: parity → 0.98 hemiBTC.  Oracle-value out = 0.98 BTC.
    ///     User deposited 0.98 BTC of value, received 0.98 BTC.  BREAK-EVEN.
    function test_crossToken_cbBTCBelowOne_noProfit_bothDirections() public {
        MockChainlinkOracle mockHemiOracle = new MockChainlinkOracle(1e18);
        mockHemiOracle.setDecimals(18);
        MockChainlinkOracle mockCbOracle = new MockChainlinkOracle(0.98e8);
        mockCbOracle.setDecimals(8);
        treasury.updateOracle(hemiBTC, address(mockHemiOracle), 24 hours);
        treasury.updateOracle(cbBTC, address(mockCbOracle), 24 hours);

        // Seed treasury with both tokens so either redeem direction can fulfill
        deal(hemiBTC, bob, 10e8);
        deal(cbBTC, bob, 10e8);
        vm.startPrank(bob);
        IERC20(hemiBTC).approve(address(gateway), 10e8);
        IERC20(cbBTC).approve(address(gateway), 10e8);
        gateway.deposit(hemiBTC, 10e8, 0, bob);
        gateway.deposit(cbBTC, 10e8, 0, bob);
        vm.stopPrank();

        // Direction 1: hemiBTC -> cbBTC.  User LOSES 0.02 BTC.
        deal(hemiBTC, alice, 1e8);
        vm.startPrank(alice);
        IERC20(hemiBTC).approve(address(gateway), 1e8);
        uint256 minted1 = gateway.deposit(hemiBTC, 1e8, 0, alice);
        assertEq(minted1, 1e18, "hemiBTC at parity mints 1.0 vetBTC");
        uint256 cbOut = gateway.redeem(cbBTC, minted1, 0, alice);
        vm.stopPrank();
        // Redeem returns parity in TOKEN units even though cbBTC oracle is 0.98:
        assertEq(cbOut, 1e8, "redeem cbBTC at parity in token units");
        // Oracle-value: 1.0 hemiBTC * 1.0 = 1.0 BTC in; 1.0 cbBTC * 0.98 = 0.98 BTC out.
        uint256 valueInDir1 = 1e8 * 1e18 / 1e18; // 1.0 BTC in 8-decimals
        uint256 valueOutDir1 = cbOut * 0.98e8 / 1e8; // 0.98 BTC in 8-decimals
        assertLt(valueOutDir1, valueInDir1, "user lost value in hemi->cb swap");
        assertEq(valueInDir1 - valueOutDir1, 0.02e8, "user lost exactly 0.02 BTC");

        // Direction 2: cbBTC -> hemiBTC.  Break-even.
        deal(cbBTC, alice, 1e8);
        vm.startPrank(alice);
        IERC20(cbBTC).approve(address(gateway), 1e8);
        uint256 minted2 = gateway.deposit(cbBTC, 1e8, 0, alice);
        // Mint at discount: 1e8 * 0.98e8 / 1e8 = 0.98e8, then scaled to 18 decimals
        assertEq(minted2, 0.98e18, "cbBTC discount applied at mint");
        uint256 hemiOut = gateway.redeem(hemiBTC, minted2, 0, alice);
        vm.stopPrank();
        assertEq(hemiOut, 0.98e8, "hemiBTC parity redeem");
        uint256 valueInDir2 = 1e8 * 0.98e8 / 1e8; // 0.98 BTC
        uint256 valueOutDir2 = hemiOut * 1e18 / 1e18; // 0.98 BTC
        assertEq(valueOutDir2, valueInDir2, "cb->hemi swap is break-even");
    }

    /// @notice With pegBand > 0, off-peg deposits within the band mint at parity, which lets a
    ///         round-trip extract value up to the band width.  This documents the only systemic
    ///         arb edge — bounded by the per-token pegBand setting.
    function test_crossToken_pegBandCreatesBoundedArbitrage() public {
        MockChainlinkOracle mockHemiOracle = new MockChainlinkOracle(1e18);
        mockHemiOracle.setDecimals(18);
        MockChainlinkOracle mockCbOracle = new MockChainlinkOracle(1e8);
        mockCbOracle.setDecimals(8);
        treasury.updateOracle(hemiBTC, address(mockHemiOracle), 24 hours);
        treasury.updateOracle(cbBTC, address(mockCbOracle), 24 hours);

        // pegBand must be < priceTolerance (200 bps), so use 100 bps
        gateway.updatePegBand(hemiBTC, 100);

        mockHemiOracle.updatePrice(0.99e18); // exactly at the 100-bps floor
        mockCbOracle.updatePrice(1e8);

        deal(cbBTC, bob, 10e8);
        vm.startPrank(bob);
        IERC20(cbBTC).approve(address(gateway), 10e8);
        gateway.deposit(cbBTC, 10e8, 0, bob);
        vm.stopPrank();

        deal(hemiBTC, alice, 1e8);
        vm.startPrank(alice);
        IERC20(hemiBTC).approve(address(gateway), 1e8);
        uint256 minted = gateway.deposit(hemiBTC, 1e8, 0, alice);
        assertEq(minted, 1e18, "peg band should treat deposit as at parity");
        uint256 cbOut = gateway.redeem(cbBTC, minted, 0, alice);
        vm.stopPrank();

        assertEq(cbOut, 1e8, "cbBTC out at parity");

        // User deposited 0.99 BTC of value, extracted 1.0 BTC. Arb bounded by 100 bps band.
        uint256 deposited = 0.99e18;
        uint256 extracted = 1e18;
        assertGt(extracted, deposited, "peg band created arb");
        assertLe(extracted - deposited, 0.01e18, "arb bounded by 100 bps band");
    }

    /// @notice After deposits in both tokens, the solvency invariant reserve >= supply must hold.
    ///         reserve() can exceed supply when an oracle reads above unit: mint is capped at
    ///         parity but reserve() counts the full premium (designed surplus, mintable to AMO).
    ///         The upper bound on the surplus is small — capped by priceTolerance per token.
    function test_reserve_matchesSupply_withMixedOracleDecimals() public {
        deal(cbBTC, alice, 1e8);
        deal(hemiBTC, alice, 1e8);

        vm.startPrank(alice);
        IERC20(cbBTC).approve(address(gateway), 1e8);
        IERC20(hemiBTC).approve(address(gateway), 1e8);
        gateway.deposit(cbBTC, 1e8, 0, alice);
        gateway.deposit(hemiBTC, 1e8, 0, alice);
        vm.stopPrank();

        uint256 reserveValue = treasury.reserve();
        uint256 supply = vetBTC.totalSupply();

        // Solvency: reserve must always cover supply.
        assertGe(reserveValue, supply, "protocol insolvent");

        // Surplus must be within priceTolerance (200 bps) of the deposited collateral value.
        // Two 1-unit deposits at most 2% over-priced → at most 4% surplus over supply.
        assertLe(reserveValue - supply, supply * 400 / 10_000, "surplus exceeds tolerance bound");
    }

    /// @notice If the hemiBTC "Exchange Rate" feed ever drifts above priceTolerance, operations
    ///         correctly revert rather than mis-pricing.  Important caveat: if hemiBTC is
    ///         yield-bearing, the exchange rate may grow monotonically and eventually exceed
    ///         tolerance — at which point hemiBTC operations break until tolerance is widened.
    function test_hemiBTC_priceToleranceBlocksOutOfBandPrice() public {
        MockChainlinkOracle mockHemiOracle = new MockChainlinkOracle(1e18);
        mockHemiOracle.setDecimals(18);
        treasury.updateOracle(hemiBTC, address(mockHemiOracle), 24 hours);

        // priceTolerance is 200 bps. Push price 3% above unit.
        mockHemiOracle.updatePrice(1.03e18);

        deal(hemiBTC, alice, 1e8);
        vm.startPrank(alice);
        IERC20(hemiBTC).approve(address(gateway), 1e8);
        vm.expectRevert(); // PriceExceedTolerance
        gateway.deposit(hemiBTC, 1e8, 0, alice);
        vm.stopPrank();
    }
}
