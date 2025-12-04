// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IViat} from "./IViat.sol";

/// @title IGateway - Interface for viat Gateway
interface IGateway {
    /**
     * Write Functions
     */
    // onlyOwner functions
    /// @notice Mints viat tokens directly (admin function)
    /// @param amount_ Amount of viat to mint
    /// @param receiver_ Address to receive the minted viat
    function mint(uint256 amount_, address receiver_) external;

    /// @notice Updates the mint fee percentage
    /// @param newMintFee_ New fee in basis points (1 = 0.01%)
    function updateMintFee(uint256 newMintFee_) external;

    /// @notice Updates the maximum mint limit
    /// @param newMintLimit_ New maximum mint limit in viat
    function updateMintLimit(uint256 newMintLimit_) external;

    /// @notice Updates the redeem fee percentage
    /// @param newRedeemFee_ New fee in basis points (1 = 0.01%)
    function updateRedeemFee(uint256 newRedeemFee_) external;

    // user functions
    /// @notice Deposits tokens to receive viat
    /// @param tokenIn_ Token to deposit
    /// @param amountIn_ Amount of tokens to deposit
    /// @param minViatOut_ Minimum viat to receive
    /// @param receiver_ Address to receive the viat
    /// @return Amount of viat minted
    function deposit(address tokenIn_, uint256 amountIn_, uint256 minViatOut_, address receiver_)
        external
        returns (uint256);

    /// @notice Mints exact viat amount by depositing tokens
    /// @param tokenIn_ Token to deposit
    /// @param viatOut_ Exact viat amount to mint
    /// @param maxAmountIn_ Maximum tokens to deposit
    /// @param receiver_ Address to receive the viat
    /// @return Amount of tokens deposited
    function mint(address tokenIn_, uint256 viatOut_, uint256 maxAmountIn_, address receiver_)
        external
        returns (uint256);

    /// @notice Redeems viat for exact token amount
    /// @param tokenOut_ Token to receive
    /// @param viatIn_ viat amount to burn
    /// @param minAmountOut_ Minimum tokens to receive
    /// @param receiver_ Address to receive the tokens
    /// @return Amount of tokens received
    function redeem(address tokenOut_, uint256 viatIn_, uint256 minAmountOut_, address receiver_)
        external
        returns (uint256);

    /// @notice Withdraws exact token amount by burning viat
    /// @param tokenOut_ Token to receive
    /// @param amountOut_ Exact token amount to receive
    /// @param maxViatIn_ Maximum viat to burn
    /// @param receiver_ Address to receive the tokens
    /// @return Amount of viat burnt
    function withdraw(address tokenOut_, uint256 amountOut_, uint256 maxViatIn_, address receiver_)
        external
        returns (uint256);

    /**
     * View Functions
     */
    // State getters
    /// @notice Returns viaToken contract
    /// forge-lint: disable-next-line(mixed-case-function)
    function VIAT() external view returns (IViat);

    /// @notice Returns current mint fee in basis points
    function mintFee() external view returns (uint256);

    /// @notice Returns current redeem fee in basis points
    function redeemFee() external view returns (uint256);

    /// @notice Returns current mint limit for viat
    function mintLimit() external view returns (uint256);

    // Max amounts
    /// @notice Returns maximum deposit amount possible
    function maxDeposit() external view returns (uint256);

    /// @notice Returns maximum mint amount possible
    function maxMint() external view returns (uint256);

    /// @notice Returns maximum viat amount owner can redeem
    /// @param owner_ Address to check redeem limit for
    function maxRedeem(address owner_) external view returns (uint256);

    /// @notice Returns maximum token amount that can be withdrawn
    /// @param tokenOut_ Token to withdraw
    function maxWithdraw(address tokenOut_) external view returns (uint256);

    // Preview functions
    /// @notice Simulates deposit of tokens for viat
    /// @param tokenIn_ Token to deposit
    /// @param amountIn_ Amount of tokens to deposit
    /// @return _viatOut Expected viat output
    function previewDeposit(address tokenIn_, uint256 amountIn_) external view returns (uint256 _viatOut);

    /// @notice Simulates minting exact viat amount
    /// @param tokenIn_ Token to deposit
    /// @param viatOut_ viat amount to mint
    /// @return _amountIn Required token input
    function previewMint(address tokenIn_, uint256 viatOut_) external view returns (uint256 _amountIn);

    /// @notice Simulates redeeming viat for tokens
    /// @param tokenOut_ Token to receive
    /// @param viatIn_ viat amount to redeem
    /// @return _amountOut Expected token output
    function previewRedeem(address tokenOut_, uint256 viatIn_) external view returns (uint256 _amountOut);

    /// @notice Simulates withdrawing exact token amount
    /// @param tokenOut_ Token to withdraw
    /// @param amountOut_ Token amount to withdraw
    /// @return _viatIn Required viat input
    function previewWithdraw(address tokenOut_, uint256 amountOut_) external view returns (uint256 _viatIn);

    // Other getters
    /// @notice Returns contract owner address
    function owner() external view returns (address);

    /// @notice Returns treasury contract address
    function treasury() external view returns (address);
}
