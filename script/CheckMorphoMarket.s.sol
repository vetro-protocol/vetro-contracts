// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MarketParams, Market, IMorpho, IIRM} from "./interfaces/IMorpho.sol";

/// @title CheckMorphoMarket
/// @notice Reads and prints market state, utilization, and interest rates for any Morpho market.
///
/// Usage:
///   MARKET_ID=0x... forge script script/CheckMorphoMarket.s.sol --rpc-url $ETHEREUM_NODE_URL
contract CheckMorphoMarket is Script {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    function run() external view {
        bytes32 marketId = vm.envBytes32("MARKET_ID");
        IMorpho morpho = IMorpho(MORPHO);

        // 1. Get market params
        (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) =
            morpho.idToMarketParams(marketId);

        console.log("=== Market Params ===");
        console.log("Loan Token:", loanToken);
        console.log("Collateral Token:", collateralToken);
        console.log("Oracle:", oracle);
        console.log("IRM:", irm);
        console.log("LLTV:", lltv);

        // 2. Get market state
        (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        ) = morpho.market(marketId);

        console.log("=== Market State ===");
        console.log("Total Supply Assets:", totalSupplyAssets);
        console.log("Total Supply Shares:", totalSupplyShares);
        console.log("Total Borrow Assets:", totalBorrowAssets);
        console.log("Total Borrow Shares:", totalBorrowShares);
        console.log("Last Update:", lastUpdate);
        console.log("Fee:", fee);

        // 3. Calculate utilization
        uint256 utilization = 0;
        if (totalSupplyAssets > 0) {
            utilization = uint256(totalBorrowAssets) * 10000 / uint256(totalSupplyAssets);
        }
        console.log("=== Utilization ===");
        console.log("Utilization (bps):", utilization); // 9000 = 90%

        // 4. Get borrow rate from IRM
        MarketParams memory params = MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });

        Market memory mkt = Market({
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: totalBorrowShares,
            lastUpdate: lastUpdate,
            fee: fee
        });

        uint256 borrowRatePerSecond = IIRM(IRM).borrowRateView(params, mkt);
        console.log("=== Interest Rates ===");
        console.log("Borrow Rate (per second, 1e18):", borrowRatePerSecond);

        // APR = rate * seconds_per_year (no compounding)
        uint256 borrowAPR = borrowRatePerSecond * 365.25 days * 100 / 1e18;
        console.log("Borrow APR (%):", borrowAPR);

        // Supply APR = Borrow APR * utilization * (1 - fee)
        uint256 supplyAPR = borrowAPR * utilization / 10000;
        console.log("Supply APR (%):", supplyAPR);
    }
}
