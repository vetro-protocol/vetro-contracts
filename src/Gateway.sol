// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IVUSD} from "./interfaces/IVUSD.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @title Gateway - Handles both minting and redeeming of VUSD
contract Gateway is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsNull();
    error CallerIsNotOwner(address caller);
    error InvalidMintFee(uint256);
    error InvalidRedeemFee(uint256);
    error MintableIsLessThanMinimum(uint256 mintable, uint256 minVusdOut);
    error MintLimitReached(uint256 available, uint256 requested);
    error RedeemableIsLessThanMinimum(uint256 redeemable, uint256 minAmountOut);
    error UnsupportedToken(address);

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

    event Mint(
        address indexed tokenIn, uint256 amountIn, uint256 amountInAfterTransferFee, uint256 mintable, address receiver
    );
    event MintLimitUpdated(uint256 previousMintLimit, uint256 newMintLimit);
    event UpdatedMintFee(uint256 previousMintFee, uint256 newMintFee);
    event Redeem(address indexed token, uint256 vusdAmount, uint256 redeemable, address indexed tokenReceiver);
    event UpdatedRedeemFee(uint256 previousRedeemFee, uint256 newRedeemFee);

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
        uint256 _maxMintable = maxMintable();
        if (_maxMintable < amount_) revert MintLimitReached(_maxMintable, amount_);
        vusd.mint(receiver_, amount_);
    }

    /// @notice OnlyOwner: Update mint fee
    function updateMintFee(uint256 newMintFee_) external onlyOwner {
        if (newMintFee_ > MAX_BPS) revert InvalidMintFee(newMintFee_);
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
        if (newRedeemFee_ > MAX_BPS) revert InvalidRedeemFee(newRedeemFee_);
        emit UpdatedRedeemFee(redeemFee, newRedeemFee_);
        redeemFee = newRedeemFee_;
    }

    /*/////////////////////////////////////////////////////////////
                            Write Functions
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint VUSD by depositing a supported token
     * @param token_ Address of token being deposited
     * @param amountIn_ Amount of token_
     * @param minVusdOut_ Minimum amount of VUSD expected to mint
     * @param receiver_ Address of VUSD receiver
     */
    function mint(address token_, uint256 amountIn_, uint256 minVusdOut_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        address _treasury = treasury();
        if (!ITreasury(_treasury).isWhitelistedToken(token_)) revert UnsupportedToken(token_);

        uint256 _balanceBefore = IERC20(token_).balanceOf(_treasury);
        IERC20(token_).safeTransferFrom(msg.sender, _treasury, amountIn_);
        uint256 _balanceAfter = IERC20(token_).balanceOf(_treasury);

        uint256 _actualAmountIn = _balanceAfter - _balanceBefore;
        uint256 _mintable = _calculateMintable(token_, _actualAmountIn);
        if (_mintable < minVusdOut_) revert MintableIsLessThanMinimum(_mintable, minVusdOut_);

        uint256 _maxMintable = maxMintable();
        if (_mintable > _maxMintable) revert MintLimitReached(_maxMintable, _mintable);

        ITreasury(_treasury).deposit(token_, _actualAmountIn);

        vusd.mint(receiver_, _mintable);
        emit Mint(token_, amountIn_, _actualAmountIn, _mintable, receiver_);

        return _mintable;
    }

    /**
     * @notice Redeem token and burn VUSD amount less redeem fee, if any.
     * Note: VUSD will be burnt from caller and there is no need to approve this contract to burn VUSD.
     * @param token_ Token to redeem, it should be 1 of the supported tokens from treasury.
     * @param vusdAmount_ VUSD amount to burn.
     * @param minAmountOut_ Minimum amount of token expected to receive
     * @param tokenReceiver_ Address of token receiver
     */
    function redeem(address token_, uint256 vusdAmount_, uint256 minAmountOut_, address tokenReceiver_)
        external
        nonReentrant
    {
        address _treasury = treasury();
        if (!ITreasury(_treasury).isWhitelistedToken(token_)) revert UnsupportedToken(token_);

        // @dev We are not checking _redeemable against total redeemable of token as it can be
        // gas heavy computation. If treasury has less than requested then it will fail anyway.
        uint256 _redeemable = _calculateRedeemable(token_, vusdAmount_);
        if (_redeemable < minAmountOut_) revert RedeemableIsLessThanMinimum(_redeemable, minAmountOut_);

        vusd.burnFrom(msg.sender, vusdAmount_);
        ITreasury(_treasury).withdraw(token_, _redeemable, tokenReceiver_);

        emit Redeem(token_, vusdAmount_, _redeemable, tokenReceiver_);
    }

    /*/////////////////////////////////////////////////////////////
                            Read Functions
    /////////////////////////////////////////////////////////////*/

    /// @notice Mintable based on mint limit and VUSD totalSupply
    function maxMintable() public view returns (uint256 _mintable) {
        uint256 _totalSupply = vusd.totalSupply();
        uint256 _mintableLimit = mintLimit;
        if (_mintableLimit > _totalSupply) {
            _mintable = _mintableLimit - _totalSupply;
        }
    }

    /**
     * @notice Calculate VUSD amount to mint for given token_ and amountIn_.
     * If token_ is not supported by treasury then it will return 0.
     * @param token_ Address of token which will be deposited to mint VUSD.
     * @param amountIn_ Amount of token_
     * @return Mintable VUSD amount
     */
    function mintable(address token_, uint256 amountIn_) external view returns (uint256) {
        if (ITreasury(treasury()).isWhitelistedToken(token_)) {
            // Calculate mintable based on given amount, price of given token and mint fee.
            uint256 _mintable = _calculateMintable(token_, amountIn_);
            // compare it against max mintable.
            return _mintable > maxMintable() ? 0 : _mintable;
        }
        return 0;
    }

    /// @dev Owner is defined in VUSD token contract only
    function owner() public view returns (address) {
        return vusd.owner();
    }

    /// @dev Current redeemable amount for given token
    function redeemableOf(address token_) public view returns (uint256) {
        return ITreasury(treasury()).withdrawable(token_);
    }

    /**
     * @notice Current redeemable amount for given token and vusdAmount.
     * If token is not supported by treasury then it will return 0.
     * If redeemable is higher than current total redeemable of given token then it will return 0.
     * @param token_ Token to redeem
     * @param vusdAmount_ VUSD amount to burn
     * @return Redeemable token amount
     */
    function redeemable(address token_, uint256 vusdAmount_) external view returns (uint256) {
        ITreasury _treasury = ITreasury(treasury());
        if (_treasury.isWhitelistedToken(token_)) {
            // Calculate redeemable based on given amount, price of given token and redeem fee.
            uint256 _redeemable = _calculateRedeemable(token_, vusdAmount_);
            // compare it against total redeemable for given token.
            return _redeemable > redeemableOf(token_) ? 0 : _redeemable;
        }
        return 0;
    }

    /// @dev Treasury is defined in VUSD token contract only
    function treasury() public view returns (address) {
        return vusd.treasury();
    }

    /*/////////////////////////////////////////////////////////////
                        Internal Functions
    /////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculate mintable based on mintFee, token price and available mintable.
     * Note: Mintable should be in VUSD decimal
     * @return _mintable VUSD amount to mint
     */
    function _calculateMintable(address token_, uint256 amountIn_) internal view returns (uint256 _mintable) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(token_);
        uint256 _amountInAfterFee = mintFee > 0 ? (amountIn_ * (MAX_BPS - mintFee)) / MAX_BPS : amountIn_;
        _mintable = _latestPrice >= _unitPrice ? _amountInAfterFee : (_amountInAfterFee * _latestPrice) / _unitPrice;
        // convert redeemable into vusd decimal
        return _mintable * 10 ** (vusdDecimals - IERC20Metadata(token_).decimals());
    }

    /**
     * @notice Calculate redeemable amount based on oracle price and redeemFee, if any.
     * Also covert 18 decimal VUSD amount to token_ defined decimal amount.
     * @return Token amount that user will get after burning vusdAmount
     */
    function _calculateRedeemable(address token_, uint256 vusdAmount_) internal view returns (uint256) {
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(token_);
        uint256 _vusdAfterFee = redeemFee > 0 ? (vusdAmount_ * (MAX_BPS - redeemFee)) / MAX_BPS : vusdAmount_;
        uint256 _redeemable = _latestPrice <= _unitPrice ? _vusdAfterFee : (_vusdAfterFee * _unitPrice) / _latestPrice;
        // convert redeemable to token_ defined decimal
        return _redeemable / 10 ** (vusdDecimals - IERC20Metadata(token_).decimals());
    }
}
