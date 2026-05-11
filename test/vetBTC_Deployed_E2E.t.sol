// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Gateway} from "src/Gateway.sol";
import {Treasury} from "src/Treasury.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {cbBTC, hemiBTC, HEMIBTC_BTC_FEED} from "test/helpers/Address.ethereum.sol";

/// Minimal interface for the whitelisted yield vault deployed at the hemiBTC vault address.
/// Only the `addToWhitelist` function is used here; the rest of the API is the standard ERC-4626.
interface IWhitelistedYieldVault {
    function addToWhitelist(address account_) external;
    function isWhitelisted(address account_) external view returns (bool);
    function owner() external view returns (address);
}

/// @title vetBTC end-to-end test against the actually deployed mainnet contracts.
/// @notice Forks Ethereum and exercises one full deposit -> request -> wait -> redeem cycle
///         for each of WBTC, cbBTC, and hemiBTC, using the live VetBTCGateway / VetBTCTreasury /
///         vetBTC token.
contract VetBTCDeployedE2E is Test {
    // --- live mainnet addresses -------------------------------------------------------------
    address constant VETBTC = 0xf196C68233464A16CFDa319a47c21f4cECa62001;
    address constant VETBTC_TREASURY = 0xd25a7b0b817fD816d0995eC67fb70e75EE65Bd7F;
    address constant VETBTC_GATEWAY = 0xCBA2Ffa0AC52d7871a4221a871793Eb788013faB;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WBTC_VAULT = 0x30c410D92e54B2b492D725D6CEBed98891817C91;
    address constant CBBTC_VAULT = 0xD954d72D885f8409bCBe3f15ad2fc3EcA4a5Ba33;
    address constant HEMI_VAULT = 0x54b8a87c9f85Dd2515CaAE1fad2dd85199900076;

    // Live on-chain roles (queried via cast at the latest mainnet block)
    address constant TREASURY_ADMIN = 0xE173b056eF552c7322040703dDfC1e0638A575d3;
    address constant HEMI_VAULT_OWNER = 0x26D4333E2E5572A5609ddEDd65748F8F237042D9;

    PeggedToken vetBTC = PeggedToken(VETBTC);
    Gateway gateway = Gateway(VETBTC_GATEWAY);
    Treasury treasury = Treasury(VETBTC_TREASURY);

    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork("ethereum");

        // Step 1: vault owner whitelists the Treasury so it can deposit hemiBTC.
        if (!IWhitelistedYieldVault(HEMI_VAULT).isWhitelisted(VETBTC_TREASURY)) {
            vm.prank(HEMI_VAULT_OWNER);
            IWhitelistedYieldVault(HEMI_VAULT).addToWhitelist(VETBTC_TREASURY);
        }
        assertTrue(
            IWhitelistedYieldVault(HEMI_VAULT).isWhitelisted(VETBTC_TREASURY),
            "treasury whitelist on hemiBTC vault failed"
        );

        // Step 2: DEFAULT_ADMIN registers hemiBTC as a backing token in the Treasury.
        //         If governance has already done this on-chain, the call is skipped.
        if (!treasury.isWhitelistedToken(hemiBTC)) {
            vm.prank(TREASURY_ADMIN);
            treasury.addToWhitelist(hemiBTC, HEMI_VAULT, HEMIBTC_BTC_FEED, 24 hours);
        }
        assertTrue(treasury.isWhitelistedToken(hemiBTC), "hemiBTC not whitelisted in treasury");
    }

    /// @notice Full cycle for WBTC.  Already configured on the live contracts; nothing extra needed.
    function test_fullCycle_WBTC() public {
        _runFullCycle(WBTC, WBTC_VAULT, 1e8); // 1 WBTC (8 decimals)
    }

    /// @notice Full cycle for cbBTC.  Already configured on the live contracts.
    function test_fullCycle_cbBTC() public {
        _runFullCycle(cbBTC, CBBTC_VAULT, 1e8); // 1 cbBTC (8 decimals)
    }

    /// @notice Full cycle for hemiBTC, enabled by the two whitelist steps in setUp.
    function test_fullCycle_hemiBTC() public {
        _runFullCycle(hemiBTC, HEMI_VAULT, 1e8); // 1 hemiBTC (8 decimals)
    }

    /// @notice Solvency check after all three deposits land — reserve must still cover supply.
    function test_reserve_coversSupply_afterAllThreeDeposits() public {
        _deposit(WBTC, 1e8);
        _deposit(cbBTC, 1e8);
        _deposit(hemiBTC, 1e8);
        assertGe(treasury.reserve(), vetBTC.totalSupply(), "treasury insolvent");
    }

    // --- internal helpers -------------------------------------------------------------------

    /// @dev Deposit -> requestRedeem -> warp past delay -> redeem.  Asserts that alice ends with
    ///      her original token amount back (within a few wei of integer-division dust).
    function _runFullCycle(address token_, address vault_, uint256 amount_) internal {
        uint256 vaultBalBefore = IERC20(vault_).balanceOf(VETBTC_TREASURY);

        // -- deposit
        uint256 minted = _deposit(token_, amount_);

        // Treasury received vault shares for the deposit
        assertGt(IERC20(vault_).balanceOf(VETBTC_TREASURY), vaultBalBefore, "vault shares not minted to treasury");

        // -- request redeem (locks vetBTC inside the gateway)
        vm.startPrank(alice);
        IERC20(VETBTC).approve(VETBTC_GATEWAY, minted);
        gateway.requestRedeem(minted);
        vm.stopPrank();

        (uint256 locked, uint256 claimableAt) = gateway.getRedeemRequest(alice);
        assertEq(locked, minted, "wrong amount locked");
        assertEq(claimableAt, block.timestamp + gateway.withdrawalDelay(), "wrong claimable time");

        // -- wait out the on-chain withdrawal delay
        vm.warp(claimableAt + 1);

        // -- redeem
        uint256 expectedOut = gateway.previewRedeem(token_, minted);
        vm.prank(alice);
        uint256 received = gateway.redeem(token_, minted, expectedOut, alice);

        // Cycle assertions
        assertEq(received, expectedOut, "received != preview");
        // The redeemed amount must be close to the original deposit (peg drift within priceTolerance
        // and integer-division dust account for the tiny gap).
        assertApproxEqRel(received, amount_, 0.02e18, "round-trip token amount drifted >2%");
        assertEq(vetBTC.balanceOf(alice), 0, "alice still holds vetBTC after redeem");
        (uint256 lockedAfter,) = gateway.getRedeemRequest(alice);
        assertEq(lockedAfter, 0, "redeem request not cleared");
    }

    function _deposit(address token_, uint256 amount_) internal returns (uint256) {
        deal(token_, alice, amount_);
        vm.startPrank(alice);
        IERC20(token_).approve(VETBTC_GATEWAY, amount_);
        uint256 minted = gateway.deposit(token_, amount_, 0, alice);
        vm.stopPrank();
        return minted;
    }
}
