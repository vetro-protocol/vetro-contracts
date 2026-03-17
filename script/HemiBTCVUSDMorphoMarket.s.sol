// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketParams, IMorpho} from "./interfaces/IMorpho.sol";

/// @title HemiBTCVUSDMorphoMarket
/// @notice Creates a hemiBTC/VUSD Morpho market and seeds it with supply + borrow to achieve ~90% utilization.
///         This prevents the AdaptiveCurveIRM from decaying the interest rate to 0%.
///
/// Usage:
///   forge script script/HemiBTCVUSDMorphoMarket.s.sol --rpc-url $ETHEREUM_NODE_URL --broadcast --private-key $PRIVATE_KEY
///
/// Prerequisites:
///   - Caller must hold enough VUSD (loan token) and hemiBTC (collateral token)
contract HemiBTCVUSDMorphoMarket is Script {
    // --- Morpho mainnet ---
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // --- Market tokens ---
    address constant VUSD = 0xCa83DDE9c22254f58e771bE5E157773212AcBAc3;
    address constant HEMI_BTC = 0x06ea695B91700071B161A434fED42D1DcbAD9f00;

    // --- Market config ---
    address constant ORACLE = 0xda360F40ECe64F63B87E214297734e57Fb281e8C;
    address constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC; // AdaptiveCurveIRM
    uint256 constant LLTV = 770000000000000000; // 77%

    // --- Seed amounts ---
    // Supply 1 VUSD, borrow 0.9 VUSD → 90% utilization
    // Collateral at 60% LTV: 0.9 / 0.60 / 74324.49 = 0.00002019 hemiBTC
    // Using 0.000021 hemiBTC (2100 units at 8 decimals) with small buffer
    uint256 constant SUPPLY_AMOUNT = 1e18; // 1 VUSD
    uint256 constant COLLATERAL_AMOUNT = 2100; // 0.000021 hemiBTC (8 decimals, ~60% LTV)
    uint256 constant BORROW_AMOUNT = 0.9e18; // 0.9 VUSD → 90% utilization

    function run() external {
        MarketParams memory params =
            MarketParams({loanToken: VUSD, collateralToken: HEMI_BTC, oracle: ORACLE, irm: IRM, lltv: LLTV});

        address caller = msg.sender;
        IMorpho morpho = IMorpho(MORPHO);

        vm.startBroadcast();

        // 1. Create the Morpho market
        morpho.createMarket(params);
        console.log("Market created");

        // 2. Approve Morpho to spend loan token and collateral
        IERC20(VUSD).approve(MORPHO, SUPPLY_AMOUNT);
        IERC20(HEMI_BTC).approve(MORPHO, COLLATERAL_AMOUNT);

        // 3. Supply VUSD as lender (creates the liquidity pool)
        (uint256 assetsSupplied,) = morpho.supply(params, SUPPLY_AMOUNT, 0, caller, "");
        console.log("Supplied VUSD:", assetsSupplied);

        // 4. Supply hemiBTC as collateral (enables borrowing)
        morpho.supplyCollateral(params, COLLATERAL_AMOUNT, caller, "");
        console.log("Collateral deposited:", COLLATERAL_AMOUNT);

        // 5. Borrow 90% of supplied VUSD → sets utilization to ~90%
        (uint256 assetsBorrowed,) = morpho.borrow(params, BORROW_AMOUNT, 0, caller, caller);
        console.log("Borrowed VUSD:", assetsBorrowed);

        vm.stopBroadcast();

        console.log("Market created and seeded. Utilization: ~90%");
    }
}
