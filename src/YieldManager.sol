// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPeggedToken} from "./interfaces/IPeggedToken.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IYieldDistributor} from "./interfaces/IYieldDistributor.sol";

/// @title YieldManager: One-shot yield operations for keepers
/// @notice Chains `Treasury.harvest` -> `Gateway.deposit` (backed mint) -> `YieldDistributor.distribute`
/// so a keeper turns treasury excess into staker yield in a single call.
/// @dev Grant this contract UMM_ROLE (Treasury) and DISTRIBUTOR_ROLE (YieldDistributor) to enable it.
contract YieldManager is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IPeggedToken;

    /*/////////////////////////////////////////////////////////////
                        STATE VARIABLES
    /////////////////////////////////////////////////////////////*/

    string public constant VERSION = "1.0.0";

    // Inlined role IDs matching Treasury's definitions to avoid chained external calls
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Pegged token
    IPeggedToken public immutable PEGGED_TOKEN;

    /// @notice Yield distributor
    IYieldDistributor public immutable YIELD_DISTRIBUTOR;

    /*/////////////////////////////////////////////////////////////
                            EVENTS
    /////////////////////////////////////////////////////////////*/

    event HarvestedAndDistributed(address indexed token, uint256 tokenAmount, uint256 peggedTokenAmount);
    event Swept(address indexed token, uint256 amount, address indexed receiver);

    /*/////////////////////////////////////////////////////////////
                            ERRORS
    /////////////////////////////////////////////////////////////*/

    error AccessControlUnauthorizedAccount(address account, bytes32 role);
    error AddressIsZero();
    error AssetMismatch();
    error NothingHarvested();

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

    /// @param peggedToken_ Pegged token
    /// @param yieldDistributor_ Yield distributor (its asset must be `peggedToken_`)
    constructor(IPeggedToken peggedToken_, IYieldDistributor yieldDistributor_) {
        if (address(peggedToken_) == address(0) || address(yieldDistributor_) == address(0)) revert AddressIsZero();
        if (address(yieldDistributor_.asset()) != address(peggedToken_)) revert AssetMismatch();

        PEGGED_TOKEN = peggedToken_;
        YIELD_DISTRIBUTOR = yieldDistributor_;
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /**
     * @notice KEEPER_ROLE: Harvest treasury excess payable in `token_`, mint pegged tokens by re-depositing
     * it through the Gateway, and distribute the minted amount as staker yield.
     * @dev Compute `minPeggedTokenOut_` off-chain (e.g. eth_call-simulate this function); deriving it
     * on-chain from `previewDeposit` is circular and never reverts. Keeper-gated for timing: each
     * `distribute` re-spreads remaining yield over a fresh period, so an open call could stretch the drip.
     * @param token_ Whitelisted collateral token to harvest the excess in
     * @param minPeggedTokenOut_ Minimum pegged tokens the Gateway mint must produce
     * @return _distributed Amount of pegged tokens sent to the YieldDistributor
     */
    function harvestAndDistribute(address token_, uint256 minPeggedTokenOut_)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 _distributed)
    {
        uint256 _harvested = treasury().harvest(token_, address(this));
        if (_harvested == 0) revert NothingHarvested();

        IGateway _gateway = gateway();
        IERC20(token_).forceApprove(address(_gateway), _harvested);
        _gateway.deposit(token_, _harvested, minPeggedTokenOut_, address(this));

        _distributed = PEGGED_TOKEN.balanceOf(address(this));
        if (_distributed == 0) revert NothingHarvested();

        PEGGED_TOKEN.forceApprove(address(YIELD_DISTRIBUTOR), _distributed);
        YIELD_DISTRIBUTOR.distribute(_distributed);

        emit HarvestedAndDistributed(token_, _harvested, _distributed);
    }

    /**
     * @notice DEFAULT_ADMIN_ROLE: Sweep tokens accidentally sent to this contract.
     * @param token_ Token to sweep
     * @param receiver_ Address to receive the swept tokens
     */
    function sweep(address token_, address receiver_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (receiver_ == address(0)) revert AddressIsZero();
        uint256 _amount = IERC20(token_).balanceOf(address(this));
        IERC20(token_).safeTransfer(receiver_, _amount);
        emit Swept(token_, _amount, receiver_);
    }

    /*/////////////////////////////////////////////////////////////
                    EXTERNAL/PUBLIC VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @notice Returns the name of the YieldManager
    function NAME() external view returns (string memory) {
        return string.concat(IERC20Metadata(address(PEGGED_TOKEN)).symbol(), "-YieldManager");
    }

    /// @notice Returns the gateway
    function gateway() public view returns (IGateway) {
        return IGateway(PEGGED_TOKEN.gateway());
    }

    /**
     * @notice The yield available to harvest, i.e. the excess of the treasury reserve over
     *  the pegged token's backed supply: `reserve - (totalSupply - amoSupply)`.
     * @dev Reverts if any whitelisted token's oracle is stale or out of tolerance.
     * @return _excessPegged Harvestable excess in pegged token units, or 0 if none.
     */
    function harvestable() public view returns (uint256 _excessPegged) {
        uint256 _backedSupply = PEGGED_TOKEN.totalSupply() - gateway().amoSupply();
        uint256 _reserve = treasury().reserve();
        return _reserve > _backedSupply ? _reserve - _backedSupply : 0;
    }

    /// @notice Returns the treasury
    function treasury() public view returns (ITreasury) {
        return ITreasury(PEGGED_TOKEN.treasury());
    }

    /*/////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    /// @dev Reverts unless `msg.sender` holds `role_` on the Treasury
    function _requireRole(bytes32 role_) private view {
        if (!treasury().hasRole(role_, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, role_);
        }
    }
}
