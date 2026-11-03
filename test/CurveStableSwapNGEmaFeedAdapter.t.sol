// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/interfaces/feeds/AggregatorV2V3Interface.sol";
import {CurveStableSwapNGEmaFeedAdapter} from "src/CurveStableSwapNGEmaFeedAdapter.sol";
import {ICurveStableSwapNG} from "src/interfaces/curve/ICurveStableSwapNG.sol";
import {FixedPriceFeedAdapter} from "src/FixedPriceFeedAdapter.sol";
import {MinPriceFeedAdapter} from "src/MinPriceFeedAdapter.sol";
import {MockChainlinkOracle} from "test/mocks/MockChainlinkOracle.sol";
import {MockCurveStableSwapNG} from "test/mocks/MockCurveStableSwapNG.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract CurveStableSwapNGEmaFeedAdapterTest is Test {
    MockERC20 wbtc;
    MockERC20 cbBtc;
    MockERC20 hemiBtc;
    MockCurveStableSwapNG pool;
    FixedPriceFeedAdapter wbtcUnit;
    MockChainlinkOracle wbtcBtc;

    // hemiBTC priced in WBTC, the peg unit
    CurveStableSwapNGEmaFeedAdapter hemiInWbtc;

    function setUp() public {
        vm.warp(10 days);
        wbtc = new MockERC20();
        cbBtc = new MockERC20();
        hemiBtc = new MockERC20();
        wbtc.setDecimals(8);
        cbBtc.setDecimals(8);
        hemiBtc.setDecimals(8);

        address[] memory _coins = new address[](3);
        (_coins[0], _coins[1], _coins[2]) = (address(wbtc), address(cbBtc), address(hemiBtc));
        pool = new MockCurveStableSwapNG(_coins);
        pool.setPriceOracle(0, 1.0016e18); // cbBTC in WBTC
        pool.setPriceOracle(1, 0.9991e18); // hemiBTC in WBTC

        wbtcUnit = new FixedPriceFeedAdapter(1e8, 8, "WBTC / WBTC");
        wbtcBtc = new MockChainlinkOracle(0.9982e8);
        hemiInWbtc = _adapter(address(hemiBtc), 2, address(wbtc), 0, wbtcUnit);
    }

    function _adapter(
        address base_,
        uint256 baseIndex_,
        address quote_,
        uint256 quoteIndex_,
        AggregatorV2V3Interface feed_
    ) private returns (CurveStableSwapNGEmaFeedAdapter) {
        return new CurveStableSwapNGEmaFeedAdapter(
            ICurveStableSwapNG(address(pool)), base_, baseIndex_, quote_, quoteIndex_, feed_
        );
    }

    function _answer(AggregatorV2V3Interface feed_) private view returns (int256 _price) {
        (, _price,,,) = feed_.latestRoundData();
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_storesConfig() public view {
        assertEq(address(hemiInWbtc.pool()), address(pool));
        assertEq(hemiInWbtc.baseIndex(), 2);
        assertEq(hemiInWbtc.quoteIndex(), 0);
        assertEq(address(hemiInWbtc.quoteFeed()), address(wbtcUnit));
    }

    function test_constructor_revertIfZeroAddress() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        new CurveStableSwapNGEmaFeedAdapter(
            ICurveStableSwapNG(address(0)), address(hemiBtc), 2, address(wbtc), 0, wbtcUnit
        );
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        _adapter(address(0), 2, address(wbtc), 0, wbtcUnit);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        _adapter(address(hemiBtc), 2, address(0), 0, wbtcUnit);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.ZeroAddress.selector);
        _adapter(address(hemiBtc), 2, address(wbtc), 0, AggregatorV2V3Interface(address(0)));
    }

    function test_constructor_revertIfSameCoin() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.SameCoin.selector);
        _adapter(address(hemiBtc), 2, address(hemiBtc), 2, wbtcUnit);
    }

    function test_constructor_revertIfCoinNotAtIndex() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.CoinMismatch.selector);
        _adapter(address(hemiBtc), 1, address(wbtc), 0, wbtcUnit);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.CoinMismatch.selector);
        _adapter(address(hemiBtc), 2, address(cbBtc), 0, wbtcUnit);
    }

    function test_constructor_revertIfIndexPastLastCoin() public {
        vm.expectRevert();
        _adapter(address(hemiBtc), 3, address(wbtc), 0, wbtcUnit);
    }

    function test_constructor_revertIfBaseHasRateOracle() public {
        pool.setRate(2, 1.106e18); // e.g. weETH
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.NotPlainCoin.selector);
        _adapter(address(hemiBtc), 2, address(wbtc), 0, wbtcUnit);
    }

    function test_constructor_revertIfQuoteHasRateOracle() public {
        pool.setRate(0, 1.106e18);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.NotPlainCoin.selector);
        _adapter(address(hemiBtc), 2, address(wbtc), 0, wbtcUnit);
    }

    function test_constructor_ignoresRateOnOtherCoin() public {
        // A rate on a coin that is neither base nor quote cancels out of the ratio
        pool.setRate(1, 1.106e18);
        _adapter(address(hemiBtc), 2, address(wbtc), 0, wbtcUnit);
    }

    function test_constructor_plainCoinCheckFollowsDecimals() public {
        MockERC20 _usdc = new MockERC20(); // 6 decimals, plain rate 1e30
        address[] memory _coins = new address[](2);
        (_coins[0], _coins[1]) = (address(wbtc), address(_usdc));
        pool = new MockCurveStableSwapNG(_coins);
        _adapter(address(_usdc), 1, address(wbtc), 0, wbtcUnit);

        pool.setRate(1, 1e28); // an 8-decimal coin's rate on a 6-decimal coin
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.NotPlainCoin.selector);
        _adapter(address(_usdc), 1, address(wbtc), 0, wbtcUnit);
    }

    // ── metadata ─────────────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(hemiInWbtc.decimals(), 18);
        assertEq(hemiInWbtc.version(), 1);
        assertEq(hemiInWbtc.latestRound(), 1);
    }

    function test_description_namesBothCoinsAndQuoteFeed() public {
        vm.mockCall(address(hemiBtc), abi.encodeCall(IERC20Metadata.symbol, ()), abi.encode("hemiBTC"));
        vm.mockCall(address(wbtc), abi.encodeCall(IERC20Metadata.symbol, ()), abi.encode("WBTC"));
        assertEq(hemiInWbtc.description(), "Curve EMA hemiBTC / WBTC x WBTC / WBTC");
    }

    // ── EMA ratio ────────────────────────────────────────────────────────────

    function test_emaRatio_quoteIsCoin0() public view {
        assertEq(hemiInWbtc.emaRatio(), 0.9991e18);
    }

    function test_emaRatio_baseIsCoin0() public {
        CurveStableSwapNGEmaFeedAdapter _wbtcInHemi = _adapter(address(wbtc), 0, address(hemiBtc), 2, wbtcUnit);
        assertEq(_wbtcInHemi.emaRatio(), uint256(1e36) / 0.9991e18);
    }

    function test_emaRatio_crossRateBetweenNonZeroIndices() public {
        CurveStableSwapNGEmaFeedAdapter _hemiInCbBtc = _adapter(address(hemiBtc), 2, address(cbBtc), 1, wbtcUnit);
        assertEq(_hemiInCbBtc.emaRatio(), uint256(0.9991e18) * 1e18 / 1.0016e18);
    }

    // ── latestRoundData ──────────────────────────────────────────────────────

    function test_latestRoundData_fixedQuoteFeedIsEmaInQuoteCoin() public {
        vm.warp(block.timestamp + 1 days);
        (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound) =
            hemiInWbtc.latestRoundData();
        assertEq(_answer, 0.9991e18);
        assertEq(_updatedAt, block.timestamp, "a fixed feed always reads fresh");
        assertEq(_startedAt, block.timestamp);
        assertEq(_roundId, 1);
        assertEq(_answeredInRound, 1);
        assertEq(hemiInWbtc.latestAnswer(), 0.9991e18);
        assertEq(hemiInWbtc.latestTimestamp(), block.timestamp);
    }

    function test_latestRoundData_chainlinkQuoteFeedConvertsToItsUnit() public {
        CurveStableSwapNGEmaFeedAdapter _hemiInBtc = _adapter(address(hemiBtc), 2, address(wbtc), 0, wbtcBtc);
        uint256 _wbtcBtcAt = block.timestamp - 1 hours;
        wbtcBtc.setUpdatedAt(_wbtcBtcAt);

        (,,, uint256 _updatedAt,) = _hemiInBtc.latestRoundData();
        assertEq(_answer(_hemiInBtc), int256(uint256(0.9991e18) * 0.9982e8 / 1e8));
        assertEq(_updatedAt, _wbtcBtcAt, "staleness comes from the quote feed");
    }

    function test_latestRoundData_revertIfQuoteFeedNotPositive() public {
        CurveStableSwapNGEmaFeedAdapter _hemiInBtc = _adapter(address(hemiBtc), 2, address(wbtc), 0, wbtcBtc);
        wbtcBtc.updatePrice(0);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.InvalidPrice.selector);
        _hemiInBtc.latestRoundData();
    }

    function test_latestRoundData_revertIfEmaIsZero() public {
        pool.setPriceOracle(1, 0);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.InvalidPrice.selector);
        hemiInWbtc.latestRoundData();

        // A zero quote-coin EMA would divide by zero
        CurveStableSwapNGEmaFeedAdapter _cbInHemi = _adapter(address(cbBtc), 1, address(hemiBtc), 2, wbtcUnit);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.InvalidPrice.selector);
        _cbInHemi.latestRoundData();
    }

    function test_historicalRounds_revert() public {
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.HistoricalRoundsNotSupported.selector);
        hemiInWbtc.getRoundData(1);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.HistoricalRoundsNotSupported.selector);
        hemiInWbtc.getAnswer(1);
        vm.expectRevert(CurveStableSwapNGEmaFeedAdapter.HistoricalRoundsNotSupported.selector);
        hemiInWbtc.getTimestamp(1);
    }

    // ── paired with a Chainlink leg through MinPriceFeedAdapter ─────────────

    function test_min_regimes() public {
        // cbBTC/WBTC = min(Chainlink-derived cbBTC/WBTC, Curve EMA cbBTC/WBTC)
        MockChainlinkOracle _chainlink = new MockChainlinkOracle(1.0041e8);
        CurveStableSwapNGEmaFeedAdapter _ema = _adapter(address(cbBtc), 1, address(wbtc), 0, wbtcUnit);
        MinPriceFeedAdapter _feed = new MinPriceFeedAdapter(_chainlink, _ema, 18);

        // Chainlink lags above par: the EMA sets the price
        assertEq(_answer(_feed), 1.0016e18);

        // Market depeg the Chainlink leg has not caught yet: the EMA lowers the price
        pool.setPriceOracle(0, 0.97e18);
        assertEq(_answer(_feed), 0.97e18);

        // Chainlink reports a lower price than the EMA: Chainlink sets the price
        _chainlink.updatePrice(0.96e8);
        assertEq(_answer(_feed), 0.96e18);

        // Chainlink goes stale: the min reports its age, not the EMA's
        uint256 _chainlinkAt = block.timestamp;
        vm.warp(block.timestamp + 2 days);
        (,,, uint256 _updatedAt,) = _feed.latestRoundData();
        assertEq(_updatedAt, _chainlinkAt);
    }
}
