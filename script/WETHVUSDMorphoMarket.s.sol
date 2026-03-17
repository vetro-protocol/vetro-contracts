// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketParams, IMorpho, IWETH} from "./interfaces/IMorpho.sol";

/// @title WETHVUSDMorphoMarket
/// @notice Creates a WETH/VUSD Morpho market and seeds it with supply + borrow to achieve ~90% utilization.
///         Wraps ETH to WETH for collateral.
///
/// Usage:
///   forge script script/WETHVUSDMorphoMarket.s.sol --rpc-url $ETHEREUM_NODE_URL --broadcast --private-key $PRIVATE_KEY
///
/// Prerequisites:
///   - Caller must hold enough VUSD (loan token) and ETH (for WETH collateral)
contract WETHVUSDMorphoMarket is Script {
    // --- Morpho mainnet ---
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // --- Market tokens ---
    address constant VUSD = 0xCa83DDE9c22254f58e771bE5E157773212AcBAc3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // --- Market config ---
    address constant ORACLE = 0x4F90106502F3560a8e1Cc7A6801C706fa8DABA27;
    address constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC; // AdaptiveCurveIRM
    uint256 constant LLTV = 860000000000000000; // 86%

    // --- Seed amounts ---
    // Supply 1 VUSD, borrow 0.9 VUSD → 90% utilization
    // Collateral at 60% LTV: 0.9 / 0.60 / ~2000 = 0.00075 WETH
    // Using 0.001 WETH (1e15 wei) for safety buffer
    uint256 constant SUPPLY_AMOUNT = 1e18; // 1 VUSD
    uint256 constant COLLATERAL_AMOUNT = 1e15; // 0.001 WETH (18 decimals, ~60% LTV at ~$2000 ETH)
    uint256 constant BORROW_AMOUNT = 0.9e18; // 0.9 VUSD → 90% utilization

    function run() external {
        MarketParams memory params =
            MarketParams({loanToken: VUSD, collateralToken: WETH, oracle: ORACLE, irm: IRM, lltv: LLTV});

        address caller = msg.sender;
        IMorpho morpho = IMorpho(MORPHO);
        IWETH weth = IWETH(WETH);

        vm.startBroadcast();

        // 1. Create the Morpho market
        morpho.createMarket(params);
        console.log("Market created");

        // 2. Wrap ETH to WETH for collateral
        weth.deposit{value: COLLATERAL_AMOUNT}();
        console.log("Wrapped ETH to WETH:", COLLATERAL_AMOUNT);

        // 3. Approve Morpho to spend loan token and collateral
        IERC20(VUSD).approve(MORPHO, SUPPLY_AMOUNT);
        weth.approve(MORPHO, COLLATERAL_AMOUNT);

        // 4. Supply VUSD as lender (creates the liquidity pool)
        (uint256 assetsSupplied,) = morpho.supply(params, SUPPLY_AMOUNT, 0, caller, "");
        console.log("Supplied VUSD:", assetsSupplied);

        // 5. Supply WETH as collateral (enables borrowing)
        morpho.supplyCollateral(params, COLLATERAL_AMOUNT, caller, "");
        console.log("Collateral deposited:", COLLATERAL_AMOUNT);

        // 6. Borrow 90% of supplied VUSD → sets utilization to ~90%
        (uint256 assetsBorrowed,) = morpho.borrow(params, BORROW_AMOUNT, 0, caller, caller);
        console.log("Borrowed VUSD:", assetsBorrowed);

        vm.stopBroadcast();

        console.log("Market created and seeded. Utilization: ~90%");
    }
}
