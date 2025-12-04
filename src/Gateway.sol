// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IViat} from "./interfaces/IViat.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IGateway} from "./interfaces/IGateway.sol";

/// @title Gateway - Handles both minting and redeeming of VIAT
contract Gateway is IGateway, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsNull();
    error CallerIsNotOwner(address caller);
    error ExceededMaxMint(uint256 requested, uint256 available);
    error ExceededMaxWithdraw(uint256 requested, uint256 available);
    error ExceededExcessReserve(uint256 requested, uint256 available);
    error FeeOnTransferToken(address);
    error InvalidMintFee(uint256);
    error InvalidRedeemFee(uint256);
    error MintableIsLessThanMinimum(uint256 viatOut, uint256 minViatOut);
    error NoExcessReserve(uint256 reserve, uint256 supply);
    error RedeemableIsLessThanMinimum(uint256 tokenOut, uint256 minTokenOut);
    error TokenAmountIsHigherThanMax(uint256 tokenIn, uint256 maxTokenIn);
    error ViatToBurnIsHigherThanMax(uint256 viatIn, uint256 maxViatIn);

    /// forge-lint: disable-next-line(mixed-case-variable)
    string public NAME;
    string public constant VERSION = "2.0.0";
    uint256 public constant MAX_BPS = 10_000; // 10_000 = 100%

    IViat public immutable VIAT;
    uint8 internal immutable VIAT_DECIMALS;

    /// @dev by default there is no mint fee
    uint256 public mintFee;
    /// @dev by default there is 0.3% redeem fee
    uint256 public redeemFee = 30;
    uint256 public mintLimit; // VIAT mint limit

    event Deposit(address indexed token, uint256 tokenAmount, uint256 viatAmount, address indexed receiver);
    event MintLimitUpdated(uint256 previousMintLimit, uint256 newMintLimit);
    event UpdatedMintFee(uint256 previousMintFee, uint256 newMintFee);
    event UpdatedRedeemFee(uint256 previousRedeemFee, uint256 newRedeemFee);
    event Withdraw(address indexed token, uint256 tokenAmount, uint256 viatAmount, address indexed receiver);

    constructor(address viat_, uint256 mintLimit_) {
        if (viat_ == address(0)) revert AddressIsNull();
        VIAT = IViat(viat_);
        mintLimit = mintLimit_;
        VIAT_DECIMALS = IERC20Metadata(viat_).decimals();
        NAME = string.concat(IERC20Metadata(viat_).symbol(), "-Gateway");
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
        uint256 _supply = VIAT.totalSupply();
        uint256 _reserve = ITreasury(treasury()).reserve();
        if (_reserve <= _supply) revert NoExcessReserve(_reserve, _supply);
        uint256 _excess = _reserve - _supply;
        if (amount_ > _excess) revert ExceededExcessReserve(amount_, _excess);
        uint256 _maxMintable = maxMint();
        if (_maxMintable < amount_) revert ExceededMaxMint(amount_, _maxMintable);
        VIAT.mint(receiver_, amount_);
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
    function deposit(address tokenIn_, uint256 amountIn_, uint256 minViatOut_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _viatAmount = previewDeposit(tokenIn_, amountIn_);
        if (_viatAmount < minViatOut_) revert MintableIsLessThanMinimum(_viatAmount, minViatOut_);
        _deposit(tokenIn_, amountIn_, _viatAmount, receiver_);
        return _viatAmount;
    }

    /// @inheritdoc IGateway
    function mint(address tokenIn_, uint256 viatOut_, uint256 maxAmountIn_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _tokenAmount = previewMint(tokenIn_, viatOut_);
        if (_tokenAmount > maxAmountIn_) revert TokenAmountIsHigherThanMax(_tokenAmount, maxAmountIn_);
        _deposit(tokenIn_, _tokenAmount, viatOut_, receiver_);
        return _tokenAmount;
    }

    /// @inheritdoc IGateway
    function redeem(address tokenOut_, uint256 viatIn_, uint256 minAmountOut_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _tokenAmount = previewRedeem(tokenOut_, viatIn_);
        if (_tokenAmount < minAmountOut_) revert RedeemableIsLessThanMinimum(_tokenAmount, minAmountOut_);
        _withdraw(tokenOut_, _tokenAmount, viatIn_, receiver_);
        return _tokenAmount;
    }

    /// @inheritdoc IGateway
    function withdraw(address tokenOut_, uint256 amountOut_, uint256 maxViatIn_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _viatToBurn = previewWithdraw(tokenOut_, amountOut_);
        if (_viatToBurn > maxViatIn_) revert ViatToBurnIsHigherThanMax(_viatToBurn, maxViatIn_);
        _withdraw(tokenOut_, amountOut_, _viatToBurn, receiver_);
        return _viatToBurn;
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
        uint256 _totalSupply = VIAT.totalSupply();
        uint256 _mintableLimit = mintLimit;
        return _mintableLimit > _totalSupply ? _mintableLimit - _totalSupply : 0;
    }

    /// @inheritdoc IGateway
    function maxRedeem(address owner_) external view returns (uint256) {
        return VIAT.balanceOf(owner_);
    }

    /// @inheritdoc IGateway
    function maxWithdraw(address tokenOut_) public view returns (uint256) {
        return ITreasury(treasury()).withdrawable(tokenOut_);
    }

    /// @inheritdoc IGateway
    function owner() public view returns (address) {
        return VIAT.owner();
    }

    /// @inheritdoc IGateway
    function previewDeposit(address tokenIn_, uint256 amountIn_) public view returns (uint256) {
        // Calculate mintable based on given amountIn_, price of given token and mint fee.
        return _calculateViatOutput(tokenIn_, amountIn_);
    }

    /// @inheritdoc IGateway
    function previewMint(address tokenIn_, uint256 viatOut_) public view returns (uint256) {
        uint256 _oneToken = 10 ** IERC20Metadata(tokenIn_).decimals();
        uint256 _viatForOneToken = _calculateViatOutput(tokenIn_, _oneToken);
        return viatOut_.mulDiv(_oneToken, _viatForOneToken, Math.Rounding.Ceil);
    }

    /// @inheritdoc IGateway
    function previewRedeem(address tokenOut_, uint256 viatIn_) public view returns (uint256) {
        // Calculate redeemable based on given viatAmount_, price of given token and redeem fee.
        return _calculateTokenOutput(tokenOut_, viatIn_);
    }

    /// @inheritdoc IGateway
    function previewWithdraw(address tokenOut_, uint256 amountOut) public view returns (uint256) {
        uint256 _oneViat = 10 ** VIAT_DECIMALS;
        uint256 _tokensForOneViat = _calculateTokenOutput(tokenOut_, _oneViat);
        return amountOut.mulDiv(_oneViat, _tokensForOneViat, Math.Rounding.Ceil);
    }

    /// @inheritdoc IGateway
    function treasury() public view returns (address) {
        return VIAT.treasury();
    }

    /*/////////////////////////////////////////////////////////////
                        Internal Functions
    /////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculate VIAT output for a given token amount considering price and fees
     * @param tokenIn_ Input token address
     * @param amountIn_ Input token amount
     * @return _viatOut Amount of VIAT to mint after applying price and fees
     * @custom:formula if price >= 1: viatOut = amountIn * (1 - mintFee)
     *                if price < 1:  viatOut = amountIn * price * (1 - mintFee)
     */
    function _calculateViatOutput(address tokenIn_, uint256 amountIn_) private view returns (uint256) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenIn_);
        uint256 _amountInAfterFee = mintFee > 0 ? amountIn_.mulDiv((MAX_BPS - mintFee), MAX_BPS) : amountIn_;
        uint256 _rawViatAmount =
            _latestPrice >= _unitPrice ? _amountInAfterFee : _amountInAfterFee.mulDiv(_latestPrice, _unitPrice);
        // convert _rawViatAmount into viat decimal
        return _rawViatAmount * 10 ** (VIAT_DECIMALS - IERC20Metadata(tokenIn_).decimals());
    }

    /**
     * @dev Calculate token output for a given VIAT input considering price and fees
     * @param tokenOut_ Output token address
     * @param viatIn_ Input VIAT amount
     * @return _tokenOut Token amount after price and fee adjustments
     * @custom:formula if price <= 1: tokenOut = viatIn * (1 - redeemFee)
     *                if price > 1:  tokenOut = viatIn / price * (1 - redeemFee)
     */
    function _calculateTokenOutput(address tokenOut_, uint256 viatIn_) private view returns (uint256) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenOut_);
        uint256 _viatInAfterFee = redeemFee > 0 ? viatIn_.mulDiv((MAX_BPS - redeemFee), MAX_BPS) : viatIn_;
        uint256 _rawTokenAmount =
            _latestPrice <= _unitPrice ? _viatInAfterFee : _viatInAfterFee.mulDiv(_unitPrice, _latestPrice);
        // convert _rawTokenAmount to token_ decimal
        return _rawTokenAmount / 10 ** (VIAT_DECIMALS - IERC20Metadata(tokenOut_).decimals());
    }

    /**
     * @dev Handle token deposit and VIAT minting
     * @custom:validation Checks mint limit and rejects fee-on-transfer tokens
     */
    function _deposit(address tokenIn_, uint256 amountIn_, uint256 viatOut_, address receiver_) private {
        uint256 _maxMintable = maxMint();
        if (viatOut_ > _maxMintable) revert ExceededMaxMint(viatOut_, _maxMintable);

        address _treasury = treasury();

        uint256 _balanceBefore = IERC20(tokenIn_).balanceOf(_treasury);
        IERC20(tokenIn_).safeTransferFrom(msg.sender, _treasury, amountIn_);
        uint256 _balanceAfter = IERC20(tokenIn_).balanceOf(_treasury);
        if ((_balanceAfter - _balanceBefore) != amountIn_) revert FeeOnTransferToken(tokenIn_);

        ITreasury(_treasury).deposit(tokenIn_, amountIn_);
        VIAT.mint(receiver_, viatOut_);

        emit Deposit(tokenIn_, amountIn_, viatOut_, receiver_);
    }

    /**
     * @dev Handle VIAT burning and token withdrawal
     * @custom:validation Checks maximum withdrawable amount from treasury
     */
    function _withdraw(address tokenOut_, uint256 amountOut_, uint256 viatIn_, address receiver_) private {
        uint256 _maxWithdraw = maxWithdraw(tokenOut_);
        if (amountOut_ > _maxWithdraw) revert ExceededMaxWithdraw(amountOut_, _maxWithdraw);
        VIAT.burnFrom(msg.sender, viatIn_);
        ITreasury(treasury()).withdraw(tokenOut_, amountOut_, receiver_);

        emit Withdraw(tokenOut_, amountOut_, viatIn_, receiver_);
    }
}
