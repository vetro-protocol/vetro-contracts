// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IVUSD} from "./interfaces/IVUSD.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @title Gateway - Handles both minting and redeeming of VUSD
contract Gateway is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsNull();
    error CallerIsNotOwner(address caller);
    error ExceededMaxMint(uint256 requested, uint256 available);
    error ExceededMaxWithdraw(uint256 requested, uint256 available);
    error FeeOnTransferToken(address);
    error InvalidMintFee(uint256);
    error InvalidRedeemFee(uint256);
    error MintableIsLessThanMinimum(uint256 vusdOut, uint256 minVusdOut);
    error RedeemableIsLessThanMinimum(uint256 tokenOut, uint256 minTokenOut);
    error TokenAmountIsHigherThanMax(uint256 tokenIn, uint256 maxTokenIn);
    error VusdToBurnIsHigherThanMax(uint256 vusdIn, uint256 maxVusdIn);

    string public constant NAME = "VUSD-Gateway";
    string public constant VERSION = "2.0.0";
    uint256 public constant MAX_BPS = 10_000; // 10_000 = 100%

    IVUSD public immutable vusd;
    uint8 internal immutable vusdDecimals;

    /// @dev by default there is no mint fee
    uint256 public mintFee;
    /// @dev by default there is 0.3% redeem fee
    uint256 public redeemFee = 30;
    uint256 public mintLimit; // VUSD mint limit

    event Deposit(address indexed token, uint256 tokenAmount, uint256 vusdAmount, address indexed receiver);
    event MintLimitUpdated(uint256 previousMintLimit, uint256 newMintLimit);
    event UpdatedMintFee(uint256 previousMintFee, uint256 newMintFee);
    event UpdatedRedeemFee(uint256 previousRedeemFee, uint256 newRedeemFee);
    event Withdraw(address indexed token, uint256 tokenAmount, uint256 vusdAmount, address indexed receiver);

    constructor(address vusd_, uint256 mintLimit_) {
        if (vusd_ == address(0)) revert AddressIsNull();
        vusd = IVUSD(vusd_);
        mintLimit = mintLimit_;
        vusdDecimals = IERC20Metadata(vusd_).decimals();
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert CallerIsNotOwner(msg.sender);
        _;
    }

    /*/////////////////////////////////////////////////////////////
                            onlyOwner
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice OnlyOwner: Mint VUSD directly to owner
     * @param amount_ Amount of VUSD to mint
     * @param receiver_ Address of VUSD receiver
     */
    function mint(uint256 amount_, address receiver_) external onlyOwner {
        if (receiver_ == address(0)) revert AddressIsNull();
        uint256 _maxMintable = maxMint();
        if (_maxMintable < amount_) revert ExceededMaxMint(amount_, _maxMintable);
        vusd.mint(receiver_, amount_);
    }

    /// @notice OnlyOwner: Update mint fee
    function updateMintFee(uint256 newMintFee_) external onlyOwner {
        if (newMintFee_ >= MAX_BPS) revert InvalidMintFee(newMintFee_);
        emit UpdatedMintFee(mintFee, newMintFee_);
        mintFee = newMintFee_;
    }

    /// @notice OnlyOwner: Update mint limit
    function updateMintLimit(uint256 newMintLimit_) external onlyOwner {
        emit MintLimitUpdated(mintLimit, newMintLimit_);
        mintLimit = newMintLimit_;
    }

    /// @notice OnlyOwner: Update redeem fee
    function updateRedeemFee(uint256 newRedeemFee_) external onlyOwner {
        if (newRedeemFee_ >= MAX_BPS) revert InvalidRedeemFee(newRedeemFee_);
        emit UpdatedRedeemFee(redeemFee, newRedeemFee_);
        redeemFee = newRedeemFee_;
    }

    /*/////////////////////////////////////////////////////////////
                            Write Functions
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit supported token and mint VUSD
     * @param tokenIn_ Address of token being deposited
     * @param amountIn_ Amount of token_
     * @param minVusdOut_ Minimum amount of VUSD expected to mint
     * @param receiver_ Address of VUSD receiver
     */
    function deposit(address tokenIn_, uint256 amountIn_, uint256 minVusdOut_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _vusdAmount = previewDeposit(tokenIn_, amountIn_);
        if (_vusdAmount < minVusdOut_) revert MintableIsLessThanMinimum(_vusdAmount, minVusdOut_);
        _deposit(tokenIn_, amountIn_, _vusdAmount, receiver_);
        return _vusdAmount;
    }

    /**
     * @notice Mint VUSD by depositing a supported token
     * @param tokenIn_ Address of token being deposited
     * @param vusdOut_ Amount of VUSD to mint
     * @param maxAmountIn_ Maximum amount of token to deposit
     * @param receiver_ Address of VUSD receiver
     */
    function mint(address tokenIn_, uint256 vusdOut_, uint256 maxAmountIn_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _tokenAmount = previewMint(tokenIn_, vusdOut_);
        if (_tokenAmount > maxAmountIn_) revert TokenAmountIsHigherThanMax(_tokenAmount, maxAmountIn_);
        _deposit(tokenIn_, _tokenAmount, vusdOut_, receiver_);
        return _tokenAmount;
    }

    /**
     * @notice Redeem supported token and burn VUSD amount less redeem fee, if any.
     * Note: VUSD will be burnt from caller and there is no need to approve this contract to burn VUSD.
     * @param tokenOut_ Token to redeem
     * @param vusdIn_ VUSD amount to burn.
     * @param minAmountOut_ Minimum amount of token expected to receive
     * @param receiver_ Address of token receiver
     * @dev We are not checking maxWithdraw for amountOut as it can be gas heavy computation. Redeem
     * will fail if there is not enough token to withdraw in treasury.
     */
    function redeem(address tokenOut_, uint256 vusdIn_, uint256 minAmountOut_, address receiver_)
        external
        nonReentrant
    {
        // @dev We are not checking _redeemable against total redeemable of token as it can be
        // gas heavy computation. If treasury has less than requested then it will fail anyway.
        uint256 _tokenAmount = previewRedeem(tokenOut_, vusdIn_);
        if (_tokenAmount < minAmountOut_) revert RedeemableIsLessThanMinimum(_tokenAmount, minAmountOut_);
        _withdraw(tokenOut_, _tokenAmount, vusdIn_, receiver_);
    }

    function withdraw(address tokenOut_, uint256 amountOut_, uint256 maxVusdIn_, address receiver_)
        external
        nonReentrant
    {
        uint256 _vusdToBurn = previewWithdraw(tokenOut_, amountOut_);
        if (_vusdToBurn > maxVusdIn_) revert VusdToBurnIsHigherThanMax(_vusdToBurn, maxVusdIn_);
        _withdraw(tokenOut_, amountOut_, _vusdToBurn, receiver_);
    }

    /*/////////////////////////////////////////////////////////////
                            Read Functions
    /////////////////////////////////////////////////////////////*/

    /// @notice Returns the maximum amount of the token that can be deposited.
    function maxDeposit() external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns the maximum amount of VUSD that can be minted.
    function maxMint() public view returns (uint256) {
        uint256 _totalSupply = vusd.totalSupply();
        uint256 _mintableLimit = mintLimit;
        return _mintableLimit > _totalSupply ? _mintableLimit - _totalSupply : 0;
    }

    /// @notice Returns the maximum amount of VUSD that can be redeemed for given owner.
    function maxRedeem(address owner_) external view returns (uint256) {
        return vusd.balanceOf(owner_);
    }

    /// @notice Returns the maximum amount of the token that can be withdrawn.
    function maxWithdraw(address tokenOut_) public view returns (uint256) {
        return ITreasury(treasury()).withdrawable(tokenOut_);
    }

    /// @dev Owner is defined in VUSD token contract only
    function owner() public view returns (address) {
        return vusd.owner();
    }

    function previewDeposit(address tokenIn_, uint256 amountIn_) public view returns (uint256) {
        // Calculate mintable based on given amountIn_, price of given token and mint fee.
        return _calculateVusdOutput(tokenIn_, amountIn_);
    }

    function previewMint(address tokenIn_, uint256 vusdOut_) public view returns (uint256) {
        uint256 _oneToken = 10 ** IERC20Metadata(tokenIn_).decimals();
        uint256 _vusdForOneToken = _calculateVusdOutput(tokenIn_, _oneToken);
        return vusdOut_.mulDiv(_oneToken, _vusdForOneToken, Math.Rounding.Ceil);
    }

    function previewRedeem(address tokenOut_, uint256 vusdIn_) public view returns (uint256) {
        // Calculate redeemable based on given vusdAmount_, price of given token and redeem fee.
        return _calculateTokenOutput(tokenOut_, vusdIn_);
    }

    function previewWithdraw(address tokenOut_, uint256 amountOut) public view returns (uint256) {
        uint256 _oneVUSD = 10 ** vusdDecimals;
        uint256 _tokensForOneVUSD = _calculateTokenOutput(tokenOut_, _oneVUSD);
        return amountOut.mulDiv(_oneVUSD, _tokensForOneVUSD, Math.Rounding.Ceil);
    }

    /// @dev Treasury is defined in VUSD token contract only
    function treasury() public view returns (address) {
        return vusd.treasury();
    }

    /*/////////////////////////////////////////////////////////////
                        Internal Functions
    /////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculate VUSD to mint based on mintFee and token price.
     * @return VUSD amount to mint
     */
    function _calculateVusdOutput(address tokenIn_, uint256 amountIn_) private view returns (uint256) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenIn_);
        uint256 _amountInAfterFee = mintFee > 0 ? amountIn_.mulDiv((MAX_BPS - mintFee), MAX_BPS) : amountIn_;
        uint256 _rawVusdAmount =
            _latestPrice >= _unitPrice ? _amountInAfterFee : _amountInAfterFee.mulDiv(_latestPrice, _unitPrice);
        // convert _rawVusdAmount into vusd decimal
        return _rawVusdAmount * 10 ** (vusdDecimals - IERC20Metadata(tokenIn_).decimals());
    }

    /**
     * @notice Calculate token amount to withdraw based on oracle price and redeemFee.
     * Also covert 18 decimal VUSD amount to token_ defined decimal amount.
     * @return Token amount to withdraw
     */
    function _calculateTokenOutput(address tokenOut_, uint256 vusdIn_) private view returns (uint256) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenOut_);
        uint256 _vusdInAfterFee = redeemFee > 0 ? vusdIn_.mulDiv((MAX_BPS - redeemFee), MAX_BPS) : vusdIn_;
        uint256 _rawTokenAmount =
            _latestPrice <= _unitPrice ? _vusdInAfterFee : _vusdInAfterFee.mulDiv(_unitPrice, _latestPrice);
        // convert _rawTokenAmount to token_ decimal
        return _rawTokenAmount / 10 ** (vusdDecimals - IERC20Metadata(tokenOut_).decimals());
    }

    function _deposit(address tokenIn_, uint256 amountIn_, uint256 vusdOut_, address receiver_) private {
        uint256 _maxMintable = maxMint();
        if (vusdOut_ > _maxMintable) revert ExceededMaxMint(vusdOut_, _maxMintable);

        address _treasury = treasury();

        uint256 _balanceBefore = IERC20(tokenIn_).balanceOf(_treasury);
        IERC20(tokenIn_).safeTransferFrom(msg.sender, _treasury, amountIn_);
        uint256 _balanceAfter = IERC20(tokenIn_).balanceOf(_treasury);
        if ((_balanceAfter - _balanceBefore) != amountIn_) revert FeeOnTransferToken(tokenIn_);

        ITreasury(_treasury).deposit(tokenIn_, amountIn_);
        vusd.mint(receiver_, vusdOut_);

        emit Deposit(tokenIn_, amountIn_, vusdOut_, receiver_);
    }

    function _withdraw(address tokenOut_, uint256 amountOut_, uint256 vusdIn_, address receiver_) private {
        uint256 _maxWithdraw = maxWithdraw(tokenOut_);
        if (amountOut_ > _maxWithdraw) revert ExceededMaxWithdraw(amountOut_, _maxWithdraw);
        vusd.burnFrom(msg.sender, vusdIn_);
        ITreasury(treasury()).withdraw(tokenOut_, amountOut_, receiver_);

        emit Withdraw(tokenOut_, amountOut_, vusdIn_, receiver_);
    }
}
