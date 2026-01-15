// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPeggedToken} from "./interfaces/IPeggedToken.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IGateway} from "./interfaces/IGateway.sol";

/// @title Gateway - Handles both minting and redeeming of PeggedToken
/// @custom:storage-location erc7201:victor.storage.Gateway
contract Gateway is IGateway, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*/////////////////////////////////////////////////////////////
                        TYPE DECLARATIONS
    /////////////////////////////////////////////////////////////*/

    /// @notice User redeem request details
    struct RedeemRequest {
        uint256 amountLocked; // Amount of PeggedToken locked in Gateway contract
        uint256 claimableAt; // Timestamp when request can be claimed (0 = no active request)
    }

    // ERC-7201 namespace storage
    /// @custom:storage-location erc7201:victor.storage.Gateway
    struct GatewayStorage {
        string name;
        IPeggedToken peggedToken;
        uint8 peggedTokenDecimals;
        uint256 mintFee;
        uint256 redeemFee;
        uint256 mintLimit;
        bool withdrawalDelayEnabled;
        uint256 withdrawalDelay;
        EnumerableSet.AddressSet instantRedeemWhitelist;
        mapping(address user => mapping(address tokenOut => RedeemRequest)) redeemRequests;
        mapping(address tokenOut => uint256 totalRedeemRequested) redeemQueueByToken;
    }

    /*/////////////////////////////////////////////////////////////
                        STATE VARIABLES
    /////////////////////////////////////////////////////////////*/

    // keccak256(abi.encode(uint256(keccak256("victor.storage.Gateway")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _GATEWAY_STORAGE_LOCATION =
        0x776acce308c7c164a04fb34f4f55c1dfc0a572b40aacd748a96ecbbeebf67800;

    string public constant VERSION = "1.0.0";
    uint256 public constant MAX_BPS = 10_000; // 10_000 = 100%

    /*/////////////////////////////////////////////////////////////
                            EVENTS
    /////////////////////////////////////////////////////////////*/

    event AddedToInstantRedeemWhitelist(address indexed account);
    event Deposit(address indexed token, uint256 tokenAmount, uint256 peggedTokenAmount, address indexed receiver);
    event MintLimitUpdated(uint256 previousMintLimit, uint256 newMintLimit);
    event RedeemRequestCancelled(address indexed user, uint256 amount);
    event RedeemRequested(address indexed user, address indexed tokenOut, uint256 amount, uint256 claimableAt);
    event RemovedFromInstantRedeemWhitelist(address indexed account);
    event UpdatedMintFee(uint256 previousMintFee, uint256 newMintFee);
    event UpdatedRedeemFee(uint256 previousRedeemFee, uint256 newRedeemFee);
    event Withdraw(address indexed token, uint256 tokenAmount, uint256 peggedTokenAmount, address indexed receiver);
    event WithdrawalDelayToggled(bool enabled);
    event WithdrawalDelayUpdated(uint256 previousDelay, uint256 newDelay);

    /*/////////////////////////////////////////////////////////////
                            ERRORS
    /////////////////////////////////////////////////////////////*/

    error AccountAlreadyWhitelisted(address account);
    error AccountNotWhitelisted(address account);
    error AddressIsZero();
    error AccessControlUnauthorizedAccount(address account, bytes32 role);
    error CallerNotWhitelisted(address caller);
    error ExceededExcessReserve(uint256 requested, uint256 available);
    error ExceededMaxMint(uint256 requested, uint256 available);
    error ExceededMaxWithdraw(uint256 requested, uint256 available);
    error FeeOnTransferToken(address token);
    error InvalidMintFee(uint256 fee);
    error InvalidRedeemFee(uint256 fee);
    error InvalidWithdrawalDelay();
    error MintableIsLessThanMinimum(uint256 peggedTokenOut, uint256 minPeggedTokenOut);
    error NoActiveWithdrawalRequest();
    error NoExcessReserve(uint256 reserve, uint256 supply);
    error PeggedTokenToBurnIsHigherThanMax(uint256 peggedTokenIn, uint256 maxPeggedTokenIn);
    error RedeemableIsLessThanMinimum(uint256 tokenOut, uint256 minTokenOut);
    error TokenAmountIsHigherThanMax(uint256 tokenIn, uint256 maxTokenIn);
    error TokenNotSupported(address token);
    error WithdrawalAmountCannotBeZero();
    error WithdrawalDelayFeatureNotEnabled();

    /*/////////////////////////////////////////////////////////////
                            MODIFIERS
    /////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role_) {
        _requireRole(role_);
        _;
    }

    /*/////////////////////////////////////////////////////////////
                            FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Gateway contract
    /// @param peggedToken_ Address of the PeggedToken contract
    /// @param mintLimit_ Maximum mint limit for PeggedToken
    /// @param initialWithdrawalDelay_ Initial withdrawal delay period in seconds
    function initialize(address peggedToken_, uint256 mintLimit_, uint256 initialWithdrawalDelay_)
        external
        initializer
    {
        if (peggedToken_ == address(0)) revert AddressIsZero();

        GatewayStorage storage $ = _getGatewayStorage();
        $.peggedToken = IPeggedToken(peggedToken_);
        $.mintLimit = mintLimit_;
        $.peggedTokenDecimals = IERC20Metadata(peggedToken_).decimals();
        $.name = string.concat(IERC20Metadata(peggedToken_).symbol(), "-Gateway");

        // Initialize withdrawal delay settings
        $.withdrawalDelayEnabled = true; // Enabled by default
        if (initialWithdrawalDelay_ == 0) revert InvalidWithdrawalDelay();
        $.withdrawalDelay = initialWithdrawalDelay_; // e.g., 7 days (604800 seconds)

        // Initialize default redeem fee to 0.3%
        $.redeemFee = 30;
    }

    /// @inheritdoc IGateway
    function mint(uint256 amount_, address receiver_) external onlyRole(_ummRole()) {
        if (receiver_ == address(0)) revert AddressIsZero();
        IPeggedToken _token = _peggedToken();
        uint256 _supply = _token.totalSupply();
        uint256 _reserve = ITreasury(treasury()).reserve();
        if (_reserve <= _supply) revert NoExcessReserve(_reserve, _supply);
        uint256 _excess = _reserve - _supply;
        if (amount_ > _excess) revert ExceededExcessReserve(amount_, _excess);
        uint256 _maxMintable = maxMint();
        if (_maxMintable < amount_) revert ExceededMaxMint(amount_, _maxMintable);
        _token.mint(receiver_, amount_);
    }

    /// @inheritdoc IGateway
    function updateMintFee(uint256 newMintFee_) external onlyRole(_maintainerRole()) {
        if (newMintFee_ >= MAX_BPS) revert InvalidMintFee(newMintFee_);
        GatewayStorage storage $ = _getGatewayStorage();
        emit UpdatedMintFee($.mintFee, newMintFee_);
        $.mintFee = newMintFee_;
    }

    /// @inheritdoc IGateway
    function updateMintLimit(uint256 newMintLimit_) external onlyRole(_defaultAdminRole()) {
        GatewayStorage storage $ = _getGatewayStorage();
        emit MintLimitUpdated($.mintLimit, newMintLimit_);
        $.mintLimit = newMintLimit_;
    }

    /// @inheritdoc IGateway
    function updateRedeemFee(uint256 newRedeemFee_) external onlyRole(_maintainerRole()) {
        if (newRedeemFee_ >= MAX_BPS) revert InvalidRedeemFee(newRedeemFee_);
        GatewayStorage storage $ = _getGatewayStorage();
        emit UpdatedRedeemFee($.redeemFee, newRedeemFee_);
        $.redeemFee = newRedeemFee_;
    }

    /// @notice Toggle withdrawal delay feature on/off
    /// @dev When disabled, all users can instant redeem/withdraw
    function toggleWithdrawalDelay() external onlyRole(_maintainerRole()) {
        GatewayStorage storage $ = _getGatewayStorage();
        bool _withdrawalDelayEnabled = $.withdrawalDelayEnabled;
        $.withdrawalDelayEnabled = !_withdrawalDelayEnabled;
        emit WithdrawalDelayToggled(!_withdrawalDelayEnabled);
    }

    /// @notice Update the withdrawal delay period
    /// @param newDelay_ New delay period in seconds
    function updateWithdrawalDelay(uint256 newDelay_) external onlyRole(_maintainerRole()) {
        if (newDelay_ == 0) revert InvalidWithdrawalDelay();
        GatewayStorage storage $ = _getGatewayStorage();
        emit WithdrawalDelayUpdated($.withdrawalDelay, newDelay_);
        $.withdrawalDelay = newDelay_;
    }

    /// @notice Add address to instant redeem whitelist
    /// @param account_ Address to whitelist
    function addToInstantRedeemWhitelist(address account_) external onlyRole(_maintainerRole()) {
        if (account_ == address(0)) revert AddressIsZero();
        GatewayStorage storage $ = _getGatewayStorage();
        if (!$.instantRedeemWhitelist.add(account_)) revert AccountAlreadyWhitelisted(account_);
        emit AddedToInstantRedeemWhitelist(account_);
    }

    /// @notice Remove address from instant redeem whitelist
    /// @param account_ Address to remove from whitelist
    function removeFromInstantRedeemWhitelist(address account_) external onlyRole(_maintainerRole()) {
        GatewayStorage storage $ = _getGatewayStorage();
        if (!$.instantRedeemWhitelist.remove(account_)) revert AccountNotWhitelisted(account_);
        emit RemovedFromInstantRedeemWhitelist(account_);
    }

    /// @inheritdoc IGateway
    function deposit(address tokenIn_, uint256 amountIn_, uint256 minPeggedTokenOut_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _peggedTokenAmount = previewDeposit(tokenIn_, amountIn_);
        if (_peggedTokenAmount < minPeggedTokenOut_) {
            revert MintableIsLessThanMinimum(_peggedTokenAmount, minPeggedTokenOut_);
        }
        _executeDeposit(tokenIn_, amountIn_, _peggedTokenAmount, receiver_);
        return _peggedTokenAmount;
    }

    /// @inheritdoc IGateway
    function mint(address tokenIn_, uint256 peggedTokenOut_, uint256 maxAmountIn_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _tokenAmount = previewMint(tokenIn_, peggedTokenOut_);
        if (_tokenAmount > maxAmountIn_) revert TokenAmountIsHigherThanMax(_tokenAmount, maxAmountIn_);
        _executeDeposit(tokenIn_, _tokenAmount, peggedTokenOut_, receiver_);
        return _tokenAmount;
    }

    /// @inheritdoc IGateway
    function redeem(address tokenOut_, uint256 peggedTokenIn_, uint256 minAmountOut_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _tokenAmount = previewRedeem(tokenOut_, peggedTokenIn_);
        if (_tokenAmount < minAmountOut_) revert RedeemableIsLessThanMinimum(_tokenAmount, minAmountOut_);

        _handleRedeemOrWithdraw(tokenOut_, peggedTokenIn_, _tokenAmount, receiver_);
        return _tokenAmount;
    }

    /// @inheritdoc IGateway
    function withdraw(address tokenOut_, uint256 amountOut_, uint256 maxPeggedTokenIn_, address receiver_)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 _peggedTokenToBurn = previewWithdraw(tokenOut_, amountOut_);
        if (_peggedTokenToBurn > maxPeggedTokenIn_) {
            revert PeggedTokenToBurnIsHigherThanMax(_peggedTokenToBurn, maxPeggedTokenIn_);
        }

        _handleRedeemOrWithdraw(tokenOut_, _peggedTokenToBurn, amountOut_, receiver_);
        return _peggedTokenToBurn;
    }

    /// @notice Request a redeem with delay period (locks peggedToken in contract)
    /// @param tokenOut_ Token to redeem for
    /// @param peggedTokenAmount_ Amount of peggedToken to lock in request
    function requestRedeem(address tokenOut_, uint256 peggedTokenAmount_) external nonReentrant {
        // Validation
        if (peggedTokenAmount_ == 0) revert WithdrawalAmountCannotBeZero();
        if (!ITreasury(treasury()).isWhitelistedToken(tokenOut_)) {
            revert TokenNotSupported(tokenOut_);
        }

        GatewayStorage storage $ = _getGatewayStorage();
        if (!$.withdrawalDelayEnabled) revert WithdrawalDelayFeatureNotEnabled();

        RedeemRequest storage _request = $.redeemRequests[msg.sender][tokenOut_];

        // Transfer peggedToken from user to this contract (locks it)
        $.peggedToken.transferFrom(msg.sender, address(this), peggedTokenAmount_);

        // If existing request for this token, merge: add to amount and reset timer
        uint256 _newAmount = _request.amountLocked + peggedTokenAmount_;
        uint256 _newClaimableAt = block.timestamp + $.withdrawalDelay;

        // Update queue accounting for new/updated request
        $.redeemQueueByToken[tokenOut_] += peggedTokenAmount_;

        // Update request
        _request.amountLocked = _newAmount;
        _request.claimableAt = _newClaimableAt;

        emit RedeemRequested(msg.sender, tokenOut_, _newAmount, _newClaimableAt);
    }

    /// @notice Cancel redeem request and return locked peggedToken to user
    /// @param tokenOut_ Token address for the request to cancel
    function cancelRedeemRequest(address tokenOut_) external nonReentrant {
        GatewayStorage storage $ = _getGatewayStorage();
        RedeemRequest memory _request = $.redeemRequests[msg.sender][tokenOut_];

        // Validate redeem request exists
        if (_request.claimableAt == 0) revert NoActiveWithdrawalRequest();

        uint256 _peggedTokenAmount = _request.amountLocked;

        // Update queue accounting
        $.redeemQueueByToken[tokenOut_] -= _peggedTokenAmount;

        // Delete redeem request
        delete $.redeemRequests[msg.sender][tokenOut_];

        // Transfer locked peggedToken back to user
        $.peggedToken.transfer(msg.sender, _peggedTokenAmount);

        emit RedeemRequestCancelled(msg.sender, _peggedTokenAmount);
    }

    /// @notice Returns the name of the Gateway
    function NAME() external view returns (string memory) {
        return _getGatewayStorage().name;
    }

    /// @inheritdoc IGateway
    function PEGGED_TOKEN() external view returns (IPeggedToken) {
        return _peggedToken();
    }

    /// @inheritdoc IGateway
    function mintFee() external view returns (uint256) {
        return _getGatewayStorage().mintFee;
    }

    /// @inheritdoc IGateway
    function redeemFee() external view returns (uint256) {
        return _getGatewayStorage().redeemFee;
    }

    /// @inheritdoc IGateway
    function mintLimit() external view returns (uint256) {
        return _getGatewayStorage().mintLimit;
    }

    /// @inheritdoc IGateway
    function withdrawalDelayEnabled() external view returns (bool) {
        return _getGatewayStorage().withdrawalDelayEnabled;
    }

    /// @inheritdoc IGateway
    function withdrawalDelay() external view returns (uint256) {
        return _getGatewayStorage().withdrawalDelay;
    }

    /// @inheritdoc IGateway
    function maxDeposit() external pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @inheritdoc IGateway
     * @dev Returns difference between mint limit and current supply
     */
    function maxMint() public view returns (uint256) {
        IPeggedToken _token = _peggedToken();
        GatewayStorage storage $ = _getGatewayStorage();
        uint256 _totalSupply = _token.totalSupply();
        uint256 _mintableLimit = $.mintLimit;
        return _mintableLimit > _totalSupply ? _mintableLimit - _totalSupply : 0;
    }

    /// @inheritdoc IGateway
    function maxRedeem(address owner_) external view returns (uint256) {
        return _peggedToken().balanceOf(owner_);
    }

    /// @inheritdoc IGateway
    function maxWithdraw(address tokenOut_) public view returns (uint256) {
        return ITreasury(treasury()).withdrawable(tokenOut_);
    }

    /// @inheritdoc IGateway
    function owner() public view returns (address) {
        return ITreasury(treasury()).owner();
    }

    /// @inheritdoc IGateway
    function previewDeposit(address tokenIn_, uint256 amountIn_) public view returns (uint256) {
        // Calculate mintable based on given amountIn_, price of given token and mint fee.
        return _calculatePeggedTokenOutput(tokenIn_, amountIn_);
    }

    /// @inheritdoc IGateway
    function previewMint(address tokenIn_, uint256 peggedTokenOut_) public view returns (uint256) {
        uint256 _oneToken = 10 ** IERC20Metadata(tokenIn_).decimals();
        uint256 _peggedTokenForOneToken = _calculatePeggedTokenOutput(tokenIn_, _oneToken);
        return peggedTokenOut_.mulDiv(_oneToken, _peggedTokenForOneToken, Math.Rounding.Ceil);
    }

    /// @inheritdoc IGateway
    function previewRedeem(address tokenOut_, uint256 peggedTokenIn_) public view returns (uint256) {
        // Calculate redeemable based on given peggedTokenAmount_, price of given token and redeem fee.
        return _calculateTokenOutput(tokenOut_, peggedTokenIn_);
    }

    /// @inheritdoc IGateway
    function previewWithdraw(address tokenOut_, uint256 amountOut_) public view returns (uint256) {
        uint256 _onePeggedToken = 10 ** _peggedTokenDecimals();
        uint256 _tokensForOnePeggedToken = _calculateTokenOutput(tokenOut_, _onePeggedToken);
        return amountOut_.mulDiv(_onePeggedToken, _tokensForOnePeggedToken, Math.Rounding.Ceil);
    }

    /// @inheritdoc IGateway
    function treasury() public view returns (address) {
        return _peggedToken().treasury();
    }

    /// @notice Get redeem request details for a user and specific token
    /// @param user_ User address
    /// @param tokenOut_ Token address
    /// @return amountLocked Amount of peggedToken locked in Gateway contract
    /// @return claimableAt Timestamp when request can be claimed
    function getRedeemRequest(address user_, address tokenOut_)
        external
        view
        returns (uint256 amountLocked, uint256 claimableAt)
    {
        GatewayStorage storage $ = _getGatewayStorage();
        RedeemRequest memory _request = $.redeemRequests[user_][tokenOut_];
        return (_request.amountLocked, _request.claimableAt);
    }

    /// @notice Check if address is whitelisted for instant redeem/withdraw
    /// @param account_ Address to check
    /// @return True if whitelisted
    function isInstantRedeemWhitelisted(address account_) external view returns (bool) {
        GatewayStorage storage $ = _getGatewayStorage();
        return $.instantRedeemWhitelist.contains(account_);
    }

    /// @notice Get all whitelisted addresses
    /// @return Array of whitelisted addresses
    function getInstantRedeemWhitelist() external view returns (address[] memory) {
        GatewayStorage storage $ = _getGatewayStorage();
        return $.instantRedeemWhitelist.values();
    }

    /// @notice Get total peggedToken requested for redemption for a specific token
    /// @param tokenOut_ Token address to check queue for
    /// @return Total peggedToken amount in redemption queue for the token
    function getRedeemQueueForToken(address tokenOut_) external view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
        return $.redeemQueueByToken[tokenOut_];
    }

    /*/////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    function _requireRole(bytes32 role_) private view {
        if (!ITreasury(treasury()).hasRole(role_, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, role_);
        }
    }

    function _defaultAdminRole() private view returns (bytes32) {
        return ITreasury(treasury()).DEFAULT_ADMIN_ROLE();
    }

    function _maintainerRole() private view returns (bytes32) {
        return ITreasury(treasury()).MAINTAINER_ROLE();
    }

    function _ummRole() private view returns (bytes32) {
        return ITreasury(treasury()).UMM_ROLE();
    }

    /**
     * @dev Calculate PeggedToken output for a given token amount considering price and fees
     * @param tokenIn_ Input token address
     * @param amountIn_ Input token amount
     * @return _peggedTokenOut Amount of PeggedToken to mint after applying price and fees
     * @custom:formula if price >= 1: peggedTokenOut = amountIn * (1 - mintFee)
     *                if price < 1:  peggedTokenOut = amountIn * price * (1 - mintFee)
     */
    function _calculatePeggedTokenOutput(address tokenIn_, uint256 amountIn_) private view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenIn_);
        uint256 _amountInAfterFee = $.mintFee > 0 ? amountIn_.mulDiv((MAX_BPS - $.mintFee), MAX_BPS) : amountIn_;
        uint256 _rawPeggedTokenAmount =
            _latestPrice >= _unitPrice ? _amountInAfterFee : _amountInAfterFee.mulDiv(_latestPrice, _unitPrice);
        // convert _rawPeggedTokenAmount into peggedToken decimal
        uint8 _decimals = _peggedTokenDecimals();
        return _rawPeggedTokenAmount * 10 ** (_decimals - IERC20Metadata(tokenIn_).decimals());
    }

    /**
     * @dev Calculate token output for a given PeggedToken input considering price and fees
     * @param tokenOut_ Output token address
     * @param peggedTokenIn_ Input PeggedToken amount
     * @return _tokenOut Token amount after price and fee adjustments
     * @custom:formula if price <= 1: tokenOut = peggedTokenIn * (1 - redeemFee)
     *                if price > 1:  tokenOut = peggedTokenIn / price * (1 - redeemFee)
     */
    function _calculateTokenOutput(address tokenOut_, uint256 peggedTokenIn_) private view returns (uint256) {
        GatewayStorage storage $ = _getGatewayStorage();
        (uint256 _latestPrice, uint256 _unitPrice) = ITreasury(treasury()).getPrice(tokenOut_);
        uint256 _peggedTokenInAfterFee =
            $.redeemFee > 0 ? peggedTokenIn_.mulDiv((MAX_BPS - $.redeemFee), MAX_BPS) : peggedTokenIn_;
        uint256 _rawTokenAmount = _latestPrice <= _unitPrice
            ? _peggedTokenInAfterFee
            : _peggedTokenInAfterFee.mulDiv(_unitPrice, _latestPrice);
        // convert _rawTokenAmount to token_ decimal
        uint8 _decimals = _peggedTokenDecimals();
        return _rawTokenAmount / 10 ** (_decimals - IERC20Metadata(tokenOut_).decimals());
    }

    /**
     * @dev Check if instant redeem is allowed for the caller
     * @dev Reverts if delay is enabled and caller is not whitelisted
     */
    function _checkInstantRedeemAllowed() private view {
        GatewayStorage storage $ = _getGatewayStorage();
        if ($.withdrawalDelayEnabled && !$.instantRedeemWhitelist.contains(msg.sender)) {
            revert CallerNotWhitelisted(msg.sender);
        }
    }

    /**
     * @dev Handle token deposit and PeggedToken minting
     * @custom:validation Checks mint limit and rejects fee-on-transfer tokens
     */
    function _executeDeposit(address tokenIn_, uint256 amountIn_, uint256 peggedTokenOut_, address receiver_) private {
        uint256 _maxMintable = maxMint();
        if (peggedTokenOut_ > _maxMintable) revert ExceededMaxMint(peggedTokenOut_, _maxMintable);

        address _treasury = treasury();

        uint256 _balanceBefore = IERC20(tokenIn_).balanceOf(_treasury);
        IERC20(tokenIn_).safeTransferFrom(msg.sender, _treasury, amountIn_);
        uint256 _balanceAfter = IERC20(tokenIn_).balanceOf(_treasury);
        if ((_balanceAfter - _balanceBefore) != amountIn_) revert FeeOnTransferToken(tokenIn_);

        ITreasury(_treasury).deposit(tokenIn_, amountIn_);
        IPeggedToken _token = _peggedToken();
        _token.mint(receiver_, peggedTokenOut_);

        emit Deposit(tokenIn_, amountIn_, peggedTokenOut_, receiver_);
    }

    /**
     * @dev Handle PeggedToken burning and token withdrawal
     * @custom:validation Checks maximum withdrawable amount from treasury
     */
    function _executeWithdraw(address tokenOut_, uint256 amountOut_, uint256 peggedTokenIn_, address receiver_)
        private
    {
        uint256 _maxWithdraw = maxWithdraw(tokenOut_);
        if (amountOut_ > _maxWithdraw) revert ExceededMaxWithdraw(amountOut_, _maxWithdraw);
        IPeggedToken _token = _peggedToken();
        _token.burnFrom(msg.sender, peggedTokenIn_);
        ITreasury(treasury()).withdraw(tokenOut_, amountOut_, receiver_);

        emit Withdraw(tokenOut_, amountOut_, peggedTokenIn_, receiver_);
    }

    function _getGatewayStorage() private pure returns (GatewayStorage storage $) {
        assembly {
            $.slot := _GATEWAY_STORAGE_LOCATION
        }
    }

    /**
     * @dev Handle redeem or withdraw operation with claimable request check
     * @param tokenOut_ Token to receive
     * @param peggedTokenAmount_ Amount of peggedToken to burn
     * @param tokenAmount_ Amount of token to receive
     * @param receiver_ Address to receive tokens
     */
    function _handleRedeemOrWithdraw(
        address tokenOut_,
        uint256 peggedTokenAmount_,
        uint256 tokenAmount_,
        address receiver_
    ) private {
        GatewayStorage storage $ = _getGatewayStorage();
        RedeemRequest storage _request = $.redeemRequests[msg.sender][tokenOut_];

        // Check if user has a claimable request for this token
        if (_request.claimableAt > 0 && block.timestamp >= _request.claimableAt) {
            // Use locked balance (handles both partial and full+excess cases)
            _processLockedRedeem(tokenOut_, peggedTokenAmount_, tokenAmount_, receiver_);
            return;
        }

        // No claimable request - instant redeem/withdraw
        _checkInstantRedeemAllowed();
        _executeWithdraw(tokenOut_, tokenAmount_, peggedTokenAmount_, receiver_);
    }

    /// @dev Helper function to get peggedToken from storage
    function _peggedToken() private view returns (IPeggedToken) {
        return _getGatewayStorage().peggedToken;
    }

    /// @dev Helper function to get peggedTokenDecimals from storage
    function _peggedTokenDecimals() private view returns (uint8) {
        return _getGatewayStorage().peggedTokenDecimals;
    }

    /**
     * @dev Process redeem using locked balance (handles both partial and full+excess cases)
     * @param tokenOut_ Token to redeem for
     * @param peggedTokenToBurn_ Total amount of peggedToken to burn
     * @param tokenAmountOut_ Token amount to receive
     * @param receiver_ Address to receive tokens
     */
    function _processLockedRedeem(
        address tokenOut_,
        uint256 peggedTokenToBurn_,
        uint256 tokenAmountOut_,
        address receiver_
    ) private {
        // Validate treasury has sufficient withdrawable amount
        uint256 _maxWithdraw = maxWithdraw(tokenOut_);
        if (tokenAmountOut_ > _maxWithdraw) revert ExceededMaxWithdraw(tokenAmountOut_, _maxWithdraw);

        GatewayStorage storage $ = _getGatewayStorage();
        RedeemRequest storage _request = $.redeemRequests[msg.sender][tokenOut_];
        uint256 _lockedAmount = _request.amountLocked;
        IPeggedToken _token = $.peggedToken;

        if (peggedTokenToBurn_ <= _lockedAmount) {
            // Case 1: Use only locked balance
            _lockedAmount = _lockedAmount - peggedTokenToBurn_;

            // Update queue accounting
            $.redeemQueueByToken[tokenOut_] -= peggedTokenToBurn_;

            if (_lockedAmount == 0) {
                delete $.redeemRequests[msg.sender][tokenOut_];
            } else {
                _request.amountLocked = _lockedAmount;
            }

            _token.burnFrom(address(this), peggedTokenToBurn_);
        } else {
            // Case 2: Use locked + wallet (excess requires instant redeem permission)
            _checkInstantRedeemAllowed();

            uint256 _excessAmount = peggedTokenToBurn_ - _lockedAmount;

            // Update queue accounting (only for locked portion)
            $.redeemQueueByToken[tokenOut_] -= _lockedAmount;

            delete $.redeemRequests[msg.sender][tokenOut_];

            // Burn from both sources
            _token.burnFrom(address(this), _lockedAmount);
            _token.burnFrom(msg.sender, _excessAmount);
        }

        // Withdraw tokens from treasury
        ITreasury(treasury()).withdraw(tokenOut_, tokenAmountOut_, receiver_);
        emit Withdraw(tokenOut_, tokenAmountOut_, peggedTokenToBurn_, receiver_);
    }
}
