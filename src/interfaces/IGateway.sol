// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPeggedToken} from "./IPeggedToken.sol";

/// @title IGateway - Interface for PeggedToken Gateway
interface IGateway {
    /// @notice Registers a spoke (DEFAULT_ADMIN). It mints nothing until its mint limit is raised.
    /// @param spoke_ Spoke to add
    function addSpoke(address spoke_) external;

    /// @notice Adds address to instant redeem whitelist
    /// @param account_ Address to whitelist
    function addToInstantRedeemWhitelist(address account_) external;

    /// @notice Returns current AMO mint limit above reserve
    function amoMintLimit() external view returns (uint256);

    /// @notice Returns current AMO-minted supply tracked by treasury
    function amoSupply() external view returns (uint256);

    /// @notice Supply the Treasury backs: total supply less spoke supply (the AMO's included)
    function coreSupply() external view returns (uint256);

    /// @notice Burns AMO-minted PeggedToken to reduce AMO supply
    /// @dev Exempt from the sanctions list: burning only reduces supply and AMO debt
    /// @param amount_ Amount of PeggedToken to burn
    function burnFromAMO(uint256 amount_) external;

    /// @notice Burns PeggedToken from `account_` against the calling spoke's supply (spoke only). The spoke decides
    /// who may redeem and pays them; the burn needs no allowance and never exceeds the spoke's supply. Neither party
    /// may be sanctioned.
    /// @param account_ Holder to burn from
    /// @param receiver_ Who the spoke pays for the burn, reported by the spoke for screening
    /// @param amount_ PeggedToken amount to burn
    function burnFromSpoke(address account_, address receiver_, uint256 amount_) external;

    /// @notice Cancels redeem request and returns locked peggedToken to user
    function cancelRedeemRequest() external;

    /// @notice Lowers a spoke's mint limit (DEFAULT_ADMIN). Zero, or anything at or below its supply, stops its mints
    /// and never blocks its redeems.
    /// @param spoke_ Registered spoke
    /// @param newLimit_ New limit in PeggedToken, below the current one
    function decreaseSpokeMintLimit(address spoke_, uint256 newLimit_) external;

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

    /// @notice Gets redeem request details for a user
    /// @param user_ User address
    /// @return amountLocked Amount of peggedToken locked in Gateway contract
    /// @return claimableAt Timestamp when request can be claimed
    function getRedeemRequest(address user_) external view returns (uint256 amountLocked, uint256 claimableAt);

    /// @notice Gets all registered spokes
    function getSpokes() external view returns (address[] memory);

    /// @notice Mints up to `amount_` of a source's yield to `receiver_` (UMM role). The core's yield (`source_` is
    /// `address(0)`) is the Treasury's reserve above the core supply; a spoke's is its reserve above its supply, which
    /// joins that spoke's supply. Not bound by the mint limits, but counts against them.
    /// @dev Reverts with AddressIsZero for a zero `receiver_`, Treasury's Sanctioned if it is on the sanctions list,
    /// InvalidSpoke for an unregistered spoke (even with `amount_` 0), and when the source cannot be valued
    /// @param source_ `address(0)` for the core, else a registered spoke
    /// @param receiver_ Address to receive the minted PeggedToken
    /// @param amount_ Most to mint; `type(uint256).max` for all of it
    /// @return _minted PeggedToken minted
    function harvest(address source_, address receiver_, uint256 amount_) external returns (uint256 _minted);

    /// @notice Yield `harvest` can mint now for a source (`address(0)` for the core, else a registered spoke), whatever
    /// the receiver. Reverts when the source cannot be valued.
    function harvestable(address source_) external view returns (uint256);

    /// @notice Raises a spoke's mint limit (DEFAULT_ADMIN)
    /// @param spoke_ Registered spoke
    /// @param newLimit_ New limit in PeggedToken, above the current one
    function increaseSpokeMintLimit(address spoke_, uint256 newLimit_) external;

    /// @notice Checks if address is whitelisted for instant redeem/withdraw
    /// @param account_ Address to check
    /// @return True if whitelisted
    function isInstantRedeemWhitelisted(address account_) external view returns (bool);

    /// @notice Returns remaining AMO mint capacity
    function maxAmoMint() external view returns (uint256);

    /// @notice Returns the most of a token the Treasury accepts: the room under its deposit cap, bounded by what the
    /// yield vault accepts
    /// @dev Not a guarantee that a deposit succeeds: the minted amount must also fit in {maxMint}, and the token's
    /// price must be fresh and within tolerance
    /// @param tokenIn_ Token to deposit
    function maxDeposit(address tokenIn_) external view returns (uint256);

    /// @notice Returns remaining core mint capacity. Spoke mints are bound by their own limit.
    function maxMint() external view returns (uint256);

    /// @notice Returns maximum PeggedToken amount owner can redeem
    /// @param owner_ Address to check redeem limit for
    function maxRedeem(address owner_) external view returns (uint256);

    /// @notice Returns maximum token amount that can be withdrawn
    /// @param tokenOut_ Token to withdraw
    function maxWithdraw(address tokenOut_) external view returns (uint256);

    /// @notice Mints exact PeggedToken amount by depositing tokens
    /// @param tokenIn_ Token to deposit
    /// @param peggedTokenOut_ Exact PeggedToken amount to mint
    /// @param maxAmountIn_ Maximum tokens to deposit
    /// @param receiver_ Address to receive the PeggedToken
    /// @return Amount of tokens deposited
    function mint(address tokenIn_, uint256 peggedTokenOut_, uint256 maxAmountIn_, address receiver_)
        external
        returns (uint256);

    /// @notice Gets the mint fee for a specific token
    /// @param token_ Token address
    /// @return The mint fee in BPS
    function mintFee(address token_) external view returns (uint256);

    /// @notice Mints PeggedToken against the calling spoke's collateral (spoke only). Bound by the spoke's mint
    /// limit, and refused when it would leave the spoke's reserve below its supply. Neither party may be sanctioned.
    /// @param payer_ Who paid the spoke for the mint, reported by the spoke for screening
    /// @param receiver_ Address to receive the minted PeggedToken
    /// @param amount_ PeggedToken amount to mint
    function mintFromSpoke(address payer_, address receiver_, uint256 amount_) external;

    /// @notice Returns current mint limit in PeggedToken
    function mintLimit() external view returns (uint256);

    /// @notice Mints PeggedToken to AMO operations (UMM role)
    /// @dev Reverts with Treasury's Sanctioned if the caller or `receiver_` is on the sanctions list
    /// @param amount_ Amount of PeggedToken to mint
    /// @param receiver_ Address to receive the minted PeggedToken
    function mintToAMO(uint256 amount_, address receiver_) external;

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

    /// @notice Gets the redeem fee for a specific token
    /// @param token_ Token address
    /// @return The redeem fee in BPS
    function redeemFee(address token_) external view returns (uint256);

    /// @notice Removes address from instant redeem whitelist
    /// @param account_ Address to remove from whitelist
    function removeFromInstantRedeemWhitelist(address account_) external;

    /// @notice Unregisters a spoke (DEFAULT_ADMIN). Only at zero supply: removal ends its burns, which would
    /// cut its holders' exit and leave its supply on the core. Retire a spoke by stopping its mints, redeeming the
    /// remaining supply through it, then removing it.
    function removeSpoke(address spoke_) external;

    /// @notice Requests a redeem with delay period (locks peggedToken in contract)
    /// @param peggedTokenAmount_ Amount of peggedToken to lock in request
    function requestRedeem(uint256 peggedTokenAmount_) external;

    /// @notice Sets the withdrawal delay feature enabled or disabled
    /// @param enabled_ The intended state for withdrawal delay
    function setWithdrawalDelayEnabled(bool enabled_) external;

    /// @notice Returns the cap on a spoke's supply for its mints
    function spokeMintLimit(address spoke_) external view returns (uint256);

    /// @notice Returns the PeggedToken supply a spoke backs: minted through it, net of burns through it
    function spokeSupply(address spoke_) external view returns (uint256);

    /// @notice Returns the supply all spokes back: the AMO's (a special purpose spoke for now) plus every registered
    /// spoke's. Not the sum of `spokeSupply` over `getSpokes()`, which leaves out the AMO.
    function totalSpokeSupply() external view returns (uint256);

    /// @notice Returns treasury contract address
    function treasury() external view returns (address);

    /// @notice Updates the AMO mint limit
    /// @param newAmoMintLimit_ New limit value
    function updateAmoMintLimit(uint256 newAmoMintLimit_) external;

    /// @notice Updates the mint fee for a specific token
    /// @param token_ Token address
    /// @param newMintFee_ New fee in basis points (1 = 0.01%)
    function updateMintFee(address token_, uint256 newMintFee_) external;

    /// @notice Updates the maximum mint limit
    /// @param newMintLimit_ New maximum mint limit in PeggedToken
    function updateMintLimit(uint256 newMintLimit_) external;

    /// @notice Updates the redeem fee for a specific token
    /// @param token_ Token address
    /// @param newRedeemFee_ New fee in basis points (1 = 0.01%)
    function updateRedeemFee(address token_, uint256 newRedeemFee_) external;

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
