// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPeggedToken} from "./IPeggedToken.sol";

/// @title IGateway - Interface for PeggedToken Gateway
interface IGateway {
    /// @notice Adds address to instant redeem whitelist
    /// @param account_ Address to whitelist
    function addToInstantRedeemWhitelist(address account_) external;

    /// @notice Cancels redeem request and returns locked peggedToken to user
    /// @param tokenOut_ Token address for the request to cancel
    function cancelRedeemRequest(address tokenOut_) external;

    /// @notice Deposits tokens to receive PeggedToken
    /// @param tokenIn_ Token to deposit
    /// @param amountIn_ Amount of tokens to deposit
    /// @param minPeggedTokenOut_ Minimum PeggedToken to receive
    /// @param receiver_ Address to receive the PeggedToken
    /// @return Amount of PeggedToken minted
    function deposit(address tokenIn_, uint256 amountIn_, uint256 minPeggedTokenOut_, address receiver_)
        external
        returns (uint256);

    /// @notice Gets all whitelisted addresses
    /// @return Array of whitelisted addresses
    function getInstantRedeemWhitelist() external view returns (address[] memory);

    /// @notice Gets total peggedToken requested for redemption for a specific token
    /// @param tokenOut_ Token address to check queue for
    /// @return Total peggedToken amount in redemption queue for the token
    function getRedeemQueueForToken(address tokenOut_) external view returns (uint256);

    /// @notice Gets redeem request details for a user and specific token
    /// @param user_ User address
    /// @param tokenOut_ Token address
    /// @return amountLocked Amount of peggedToken locked in Gateway contract
    /// @return claimableAt Timestamp when request can be claimed
    function getRedeemRequest(address user_, address tokenOut_)
        external
        view
        returns (uint256 amountLocked, uint256 claimableAt);

    /// @notice Checks if address is whitelisted for instant redeem/withdraw
    /// @param account_ Address to check
    /// @return True if whitelisted
    function isInstantRedeemWhitelisted(address account_) external view returns (bool);

    /// @notice Returns maximum deposit amount possible
    function maxDeposit() external pure returns (uint256);

    /// @notice Returns maximum mint amount possible
    function maxMint() external view returns (uint256);

    /// @notice Returns maximum PeggedToken amount owner can redeem
    /// @param owner_ Address to check redeem limit for
    function maxRedeem(address owner_) external view returns (uint256);

    /// @notice Returns maximum token amount that can be withdrawn
    /// @param tokenOut_ Token to withdraw
    function maxWithdraw(address tokenOut_) external view returns (uint256);

    /// @notice Mints PeggedToken tokens directly (admin function)
    /// @param amount_ Amount of PeggedToken to mint
    /// @param receiver_ Address to receive the minted PeggedToken
    function mint(uint256 amount_, address receiver_) external;

    /// @notice Mints exact PeggedToken amount by depositing tokens
    /// @param tokenIn_ Token to deposit
    /// @param peggedTokenOut_ Exact PeggedToken amount to mint
    /// @param maxAmountIn_ Maximum tokens to deposit
    /// @param receiver_ Address to receive the PeggedToken
    /// @return Amount of tokens deposited
    function mint(address tokenIn_, uint256 peggedTokenOut_, uint256 maxAmountIn_, address receiver_)
        external
        returns (uint256);

    /// @notice Returns current mint fee in basis points
    function mintFee() external view returns (uint256);

    /// @notice Returns current mint limit in PeggedToken
    function mintLimit() external view returns (uint256);

    /// @notice Returns the name of the Gateway
    // solhint-disable-next-line func-name-mixedcase
    function NAME() external view returns (string memory);

    /// @notice Returns contract owner address
    function owner() external view returns (address);

    /// @notice Returns PeggedToken token contract
    // solhint-disable-next-line func-name-mixedcase
    function PEGGED_TOKEN() external view returns (IPeggedToken);

    /// @notice Simulates deposit of tokens for PeggedToken
    /// @param tokenIn_ Token to deposit
    /// @param amountIn_ Amount of tokens to deposit
    /// @return _peggedTokenOut Expected PeggedToken output
    function previewDeposit(address tokenIn_, uint256 amountIn_) external view returns (uint256 _peggedTokenOut);

    /// @notice Simulates minting exact PeggedToken amount
    /// @param tokenIn_ Token to deposit
    /// @param peggedTokenOut_ PeggedToken amount to mint
    /// @return _amountIn Required token input
    function previewMint(address tokenIn_, uint256 peggedTokenOut_) external view returns (uint256 _amountIn);

    /// @notice Simulates redeeming PeggedToken for tokens
    /// @param tokenOut_ Token to receive
    /// @param peggedTokenIn_ PeggedToken amount to redeem
    /// @return _amountOut Expected token output
    function previewRedeem(address tokenOut_, uint256 peggedTokenIn_) external view returns (uint256 _amountOut);

    /// @notice Simulates withdrawing exact token amount
    /// @param tokenOut_ Token to withdraw
    /// @param amountOut_ Token amount to withdraw
    /// @return _peggedTokenIn Required PeggedToken input
    function previewWithdraw(address tokenOut_, uint256 amountOut_) external view returns (uint256 _peggedTokenIn);

    /// @notice Redeems PeggedToken for exact token amount
    /// @param tokenOut_ Token to receive
    /// @param peggedTokenIn_ PeggedToken amount to burn
    /// @param minAmountOut_ Minimum tokens to receive
    /// @param receiver_ Address to receive the tokens
    /// @return Amount of tokens received
    function redeem(address tokenOut_, uint256 peggedTokenIn_, uint256 minAmountOut_, address receiver_)
        external
        returns (uint256);

    /// @notice Returns current redeem fee in basis points
    function redeemFee() external view returns (uint256);

    /// @notice Removes address from instant redeem whitelist
    /// @param account_ Address to remove from whitelist
    function removeFromInstantRedeemWhitelist(address account_) external;

    /// @notice Requests a redeem with delay period (locks peggedToken in contract)
    /// @param tokenOut_ Token to redeem for
    /// @param peggedTokenAmount_ Amount of peggedToken to lock in request
    function requestRedeem(address tokenOut_, uint256 peggedTokenAmount_) external;

    /// @notice Toggles the withdrawal delay feature on/off
    function toggleWithdrawalDelay() external;

    /// @notice Returns treasury contract address
    function treasury() external view returns (address);

    /// @notice Updates the mint fee percentage
    /// @param newMintFee_ New fee in basis points (1 = 0.01%)
    function updateMintFee(uint256 newMintFee_) external;

    /// @notice Updates the maximum mint limit
    /// @param newMintLimit_ New maximum mint limit in PeggedToken
    function updateMintLimit(uint256 newMintLimit_) external;

    /// @notice Updates the redeem fee percentage
    /// @param newRedeemFee_ New fee in basis points (1 = 0.01%)
    function updateRedeemFee(uint256 newRedeemFee_) external;

    /// @notice Updates the withdrawal delay period
    /// @param newDelay_ New delay period in seconds
    function updateWithdrawalDelay(uint256 newDelay_) external;

    /// @notice Withdraws exact token amount by burning PeggedToken
    /// @param tokenOut_ Token to receive
    /// @param amountOut_ Exact token amount to receive
    /// @param maxPeggedTokenIn_ Maximum PeggedToken to burn
    /// @param receiver_ Address to receive the tokens
    /// @return Amount of PeggedToken burnt
    function withdraw(address tokenOut_, uint256 amountOut_, uint256 maxPeggedTokenIn_, address receiver_)
        external
        returns (uint256);

    /// @notice Returns withdrawal delay period in seconds
    function withdrawalDelay() external view returns (uint256);

    /// @notice Returns withdrawal delay enabled status
    function withdrawalDelayEnabled() external view returns (bool);
}
