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
import {IGateway} from "./interfaces/IGateway.sol";

/// @title Gateway - Handles both minting and redeeming of VUSD
contract Gateway is IGateway, ReentrancyGuardTransient {
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

    IVUSD public immutable VUSD;
    uint8 internal immutable VUSD_DECIMALS;

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
        VUSD = IVUSD(vusd_);
        mintLimit = mintLimit_;
        VUSD_DECIMALS = IERC20Metadata(vusd_).decimals();
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert CallerIsNotOwner(msg.sender);
        _;
    }

    /*/////////////////////////////////////////////////////////////
                            onlyOwner
    /////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGateway
    function mint(uint256 amount_, address receiver_) external onlyOwner {
        if (receiver_ == address(0)) revert AddressIsNull();
        uint256 _maxMintable = maxMint();
        if (_maxMintable < amount_) revert ExceededMaxMint(amount_, _maxMintable);
        VUSD.mint(receiver_, amount_);
    }

    /// @inheritdoc IGateway
    function updateMintFee(uint256 newMintFee_) external onlyOwner {
        if (newMintFee_ >= MAX_BPS) revert InvalidMintFee(newMintFee_);
        emit UpdatedMintFee(mintFee, newMintFee_);
        mintFee = newMintFee_;
    }

    /// @inheritdoc IGateway
    function updateMintLimit(uint256 newMintLimit_) external onlyOwner {
        emit MintLimitUpdated(mintLimit, newMintLimit_);
        mintLimit = newMintLimit_;
    }

    /// @inheritdoc IGateway
    function updateRedeemFee(uint256 newRedeemFee_) external onlyOwner {
        if (newRedeemFee_ >= MAX_BPS) revert InvalidRedeemFee(newRedeemFee_);
        emit UpdatedRedeemFee(redeemFee, newRedeemFee_);
        redeemFee = newRedeemFee_;
    }

    /*/////////////////////////////////////////////////////////////
                        Write Functions
    /////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGateway
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

    /// @inheritdoc IGateway
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

    /// @inheritdoc IGateway
    function redeem(address tokenOut_, uint256 vusdIn_, uint256 minAmountOut_, address receiver_)
        external
        nonReentrant
    {
        uint256 _tokenAmount = previewRedeem(tokenOut_, vusdIn_);
        if (_tokenAmount < minAmountOut_) revert RedeemableIsLessThanMinimum(_tokenAmount, minAmountOut_);
        _withdraw(tokenOut_, _tokenAmount, vusdIn_, receiver_);
    }

    /// @inheritdoc IGateway
    function withdraw(address tokenOut_, uint256 amountOut_, uint256 maxVusdIn_, address receiver_)
        external
        nonReentrant
    {
        uint256 _vusdToBurn = previewWithdraw(tokenOut_, amountOut_);
        if (_vusdToBurn > maxVusdIn_) revert VusdToBurnIsHigherThanMax(_vusdToBurn, maxVusdIn_);
        _withdraw(tokenOut_, amountOut_, _vusdToBurn, receiver_);
    }

    /*/////////////////////////////////////////////////////////////
                        View Functions
    /////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGateway
    function maxDeposit() external pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @inheritdoc IGateway
     * @dev Returns difference between mint limit and current supply
     */
    function maxMint() public view returns (uint256) {
        uint256 _totalSupply = VUSD.totalSupply();
        uint256 _mintableLimit = mintLimit;
        return _mintableLimit > _totalSupply ? _mintableLimit - _totalSupply : 0;
    }

    /// @inheritdoc IGateway
    function maxRedeem(address owner_) external view returns (uint256) {
        return VUSD.balanceOf(owner_);
    }

    /// @inheritdoc IGateway
    function maxWithdraw(address tokenOut_) public view returns (uint256) {
        return ITreasury(treasury()).withdrawable(tokenOut_);
    }

    /// @inheritdoc IGateway
    function owner() public view returns (address) {
        return VUSD.owner();
    }

    /// @inheritdoc IGateway
    function previewDeposit(address tokenIn_, uint256 amountIn_) public view returns (uint256) {
        // Calculate mintable based on given amountIn_, price of given token and mint fee.
        return _calculateVusdOutput(tokenIn_, amountIn_);
    }

    /// @inheritdoc IGateway
    function previewMint(address tokenIn_, uint256 vusdOut_) public view returns (uint256) {
        uint256 _oneToken = 10 ** IERC20Metadata(tokenIn_).decimals();
        uint256 _vusdForOneToken = _calculateVusdOutput(tokenIn_, _oneToken);
        return vusdOut_.mulDiv(_oneToken, _vusdForOneToken, Math.Rounding.Ceil);
    }

    /// @inheritdoc IGateway
    function previewRedeem(address tokenOut_, uint256 vusdIn_) public view returns (uint256) {
        // Calculate redeemable based on given vusdAmount_, price of given token and redeem fee.
        return _calculateTokenOutput(tokenOut_, vusdIn_);
    }

    /// @inheritdoc IGateway
    function previewWithdraw(address tokenOut_, uint256 amountOut) public view returns (uint256) {
        uint256 _oneVusd = 10 ** VUSD_DECIMALS;
        uint256 _tokensForOneVusd = _calculateTokenOutput(tokenOut_, _oneVusd);
        return amountOut.mulDiv(_oneVusd, _tokensForOneVusd, Math.Rounding.Ceil);
    }

    /// @inheritdoc IGateway
    function treasury() public view returns (address) {
        return VUSD.treasury();
    }

    /*/////////////////////////////////////////////////////////////
                        Internal Functions
    /////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculate VUSD output for a given token amount considering price and fees
     * @param tokenIn_ Input token address
     * @param amountIn_ Input token amount
     * @return _vusdOut Amount of VUSD to mint after applying price and fees
     * @custom:formula if price >= 1: vusdOut = amountIn * (1 - mintFee)
     *                if price < 1:  vusdOut = amountIn * price * (1 - mintFee)
     */
    function _calculateVusdOutput(address tokenIn_, uint256 amountIn_) private view returns (uint256) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenIn_);
        uint256 _amountInAfterFee = mintFee > 0 ? amountIn_.mulDiv((MAX_BPS - mintFee), MAX_BPS) : amountIn_;
        uint256 _rawVusdAmount =
            _latestPrice >= _unitPrice ? _amountInAfterFee : _amountInAfterFee.mulDiv(_latestPrice, _unitPrice);
        // convert _rawVusdAmount into vusd decimal
        return _rawVusdAmount * 10 ** (VUSD_DECIMALS - IERC20Metadata(tokenIn_).decimals());
    }

    /**
     * @dev Calculate token output for a given VUSD input considering price and fees
     * @param tokenOut_ Output token address
     * @param vusdIn_ Input VUSD amount
     * @return _tokenOut Token amount after price and fee adjustments
     * @custom:formula if price <= 1: tokenOut = vusdIn * (1 - redeemFee)
     *                if price > 1:  tokenOut = vusdIn / price * (1 - redeemFee)
     */
    function _calculateTokenOutput(address tokenOut_, uint256 vusdIn_) private view returns (uint256) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenOut_);
        uint256 _vusdInAfterFee = redeemFee > 0 ? vusdIn_.mulDiv((MAX_BPS - redeemFee), MAX_BPS) : vusdIn_;
        uint256 _rawTokenAmount =
            _latestPrice <= _unitPrice ? _vusdInAfterFee : _vusdInAfterFee.mulDiv(_unitPrice, _latestPrice);
        // convert _rawTokenAmount to token_ decimal
        return _rawTokenAmount / 10 ** (VUSD_DECIMALS - IERC20Metadata(tokenOut_).decimals());
    }

    /**
     * @dev Handle token deposit and VUSD minting
     * @custom:validation Checks mint limit and rejects fee-on-transfer tokens
     */
    function _deposit(address tokenIn_, uint256 amountIn_, uint256 vusdOut_, address receiver_) private {
        uint256 _maxMintable = maxMint();
        if (vusdOut_ > _maxMintable) revert ExceededMaxMint(vusdOut_, _maxMintable);

        address _treasury = treasury();

        uint256 _balanceBefore = IERC20(tokenIn_).balanceOf(_treasury);
        IERC20(tokenIn_).safeTransferFrom(msg.sender, _treasury, amountIn_);
        uint256 _balanceAfter = IERC20(tokenIn_).balanceOf(_treasury);
        if ((_balanceAfter - _balanceBefore) != amountIn_) revert FeeOnTransferToken(tokenIn_);

        ITreasury(_treasury).deposit(tokenIn_, amountIn_);
        VUSD.mint(receiver_, vusdOut_);

        emit Deposit(tokenIn_, amountIn_, vusdOut_, receiver_);
    }

    /**
     * @dev Handle VUSD burning and token withdrawal
     * @custom:validation Checks maximum withdrawable amount from treasury
     */
    function _withdraw(address tokenOut_, uint256 amountOut_, uint256 vusdIn_, address receiver_) private {
        uint256 _maxWithdraw = maxWithdraw(tokenOut_);
        if (amountOut_ > _maxWithdraw) revert ExceededMaxWithdraw(amountOut_, _maxWithdraw);
        VUSD.burnFrom(msg.sender, vusdIn_);
        ITreasury(treasury()).withdraw(tokenOut_, amountOut_, receiver_);

        emit Withdraw(tokenOut_, amountOut_, vusdIn_, receiver_);
    }
}
