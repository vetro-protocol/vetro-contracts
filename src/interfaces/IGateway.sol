// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVUSD} from "./IVUSD.sol";

/// @title IGateway - Interface for VUSD Gateway
interface IGateway {
    /**
     * Write Functions
     */
    // onlyOwner functions
    /// @notice Mints VUSD tokens directly (admin function)
    /// @param amount_ Amount of VUSD to mint
    /// @param receiver_ Address to receive the minted VUSD
    function mint(uint256 amount_, address receiver_) external;

    /// @notice Updates the mint fee percentage
    /// @param newMintFee_ New fee in basis points (1 = 0.01%)
    function updateMintFee(uint256 newMintFee_) external;

    /// @notice Updates the maximum mint limit
    /// @param newMintLimit_ New maximum mint limit in VUSD
    function updateMintLimit(uint256 newMintLimit_) external;

    /// @notice Updates the redeem fee percentage
    /// @param newRedeemFee_ New fee in basis points (1 = 0.01%)
    function updateRedeemFee(uint256 newRedeemFee_) external;

    // user functions
    /// @notice Deposits tokens to receive VUSD
    /// @param tokenIn_ Token to deposit
    /// @param amountIn_ Amount of tokens to deposit
    /// @param minVusdOut_ Minimum VUSD to receive
    /// @param receiver_ Address to receive the VUSD
    /// @return Amount of VUSD minted
    function deposit(address tokenIn_, uint256 amountIn_, uint256 minVusdOut_, address receiver_)
        external
        returns (uint256);

    /// @notice Mints exact VUSD amount by depositing tokens
    /// @param tokenIn_ Token to deposit
    /// @param vusdOut_ Exact VUSD amount to mint
    /// @param maxAmountIn_ Maximum tokens to spend
    /// @param receiver_ Address to receive the VUSD
    /// @return Amount of tokens spent
    function mint(address tokenIn_, uint256 vusdOut_, uint256 maxAmountIn_, address receiver_)
        external
        returns (uint256);

    /// @notice Redeems VUSD for exact token amount
    /// @param tokenOut_ Token to receive
    /// @param vusdIn_ VUSD amount to spend
    /// @param minAmountOut_ Minimum tokens to receive
    /// @param receiver_ Address to receive the tokens
    function redeem(address tokenOut_, uint256 vusdIn_, uint256 minAmountOut_, address receiver_) external;

    /// @notice Withdraws exact token amount by burning VUSD
    /// @param tokenOut_ Token to receive
    /// @param amountOut_ Exact token amount to receive
    /// @param maxVusdIn_ Maximum VUSD to spend
    /// @param receiver_ Address to receive the tokens
    function withdraw(address tokenOut_, uint256 amountOut_, uint256 maxVusdIn_, address receiver_) external;

    /**
     * View Functions
     */
    // State getters
    /// @notice Returns VUSD token contract
    /// forge-lint: disable-next-line(mixed-case-function)
    function VUSD() external view returns (IVUSD);

    /// @notice Returns current mint fee in basis points
    function mintFee() external view returns (uint256);

    /// @notice Returns current redeem fee in basis points
    function redeemFee() external view returns (uint256);

    /// @notice Returns current mint limit in VUSD
    function mintLimit() external view returns (uint256);

    // Max amounts
    /// @notice Returns maximum deposit amount possible
    function maxDeposit() external view returns (uint256);

    /// @notice Returns maximum mint amount possible
    function maxMint() external view returns (uint256);

    /// @notice Returns maximum VUSD amount owner can redeem
    /// @param owner_ Address to check redeem limit for
    function maxRedeem(address owner_) external view returns (uint256);

    /// @notice Returns maximum token amount that can be withdrawn
    /// @param tokenOut_ Token to withdraw
    function maxWithdraw(address tokenOut_) external view returns (uint256);

    // Preview functions
    /// @notice Simulates deposit of tokens for VUSD
    /// @param tokenIn_ Token to deposit
    /// @param amountIn_ Amount of tokens to deposit
    /// @return _vusdOut Expected VUSD output
    function previewDeposit(address tokenIn_, uint256 amountIn_) external view returns (uint256 _vusdOut);

    /// @notice Simulates minting exact VUSD amount
    /// @param tokenIn_ Token to deposit
    /// @param vusdOut_ VUSD amount to mint
    /// @return _amountIn Required token input
    function previewMint(address tokenIn_, uint256 vusdOut_) external view returns (uint256 _amountIn);

    /// @notice Simulates redeeming VUSD for tokens
    /// @param tokenOut_ Token to receive
    /// @param vusdIn_ VUSD amount to redeem
    /// @return _amountOut Expected token output
    function previewRedeem(address tokenOut_, uint256 vusdIn_) external view returns (uint256 _amountOut);

    /// @notice Simulates withdrawing exact token amount
    /// @param tokenOut_ Token to withdraw
    /// @param amountOut_ Token amount to withdraw
    /// @return _vusdIn Required VUSD input
    function previewWithdraw(address tokenOut_, uint256 amountOut_) external view returns (uint256 _vusdIn);

    /// @notice Returns treasury contract address
    function treasury() external view returns (address);
}
