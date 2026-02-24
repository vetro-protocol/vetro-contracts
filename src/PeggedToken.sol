// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPeggedToken} from "./interfaces/IPeggedToken.sol";

/// @title PeggedToken, A token pegged to the USD/ETH/BTC, backed by yield-generating collateral.
contract PeggedToken is IPeggedToken, ERC20Permit, Ownable2Step {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsZero();
    error CallerIsNotGateway(address);
    error TreasuryCanNotBeZero();
    error AlreadyBlacklisted(address);
    error Blacklisted(address);
    error NotBlacklisted(address);

    address public gateway;
    address public treasury;

    EnumerableSet.AddressSet private _blacklistedAddresses;

    event UpdatedGateway(address indexed previousGateway, address indexed newGateway);
    event UpdatedTreasury(address indexed previousTreasury, address indexed newTreasury);
    event AddedToBlacklist(address indexed account);
    event RemovedFromBlacklist(address indexed account);

    constructor(string memory name_, string memory symbol_, address owner_)
        ERC20Permit(name_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {}

    /**
     * @notice Burn PeggedToken e.g. VUSD from account.
     * If Gateway is the caller then approval is not required.
     * Only Gateway can burn PeggedToken.
     * @param account_ PeggedToken will be burnt from this address
     * @param amount_ PeggedToken amount to burn
     */
    function burnFrom(address account_, uint256 amount_) public virtual {
        if (msg.sender != gateway) revert CallerIsNotGateway(msg.sender);
        _burn(account_, amount_);
    }

    /**
     * @notice onlyGateway:: Mint PeggedToken e.g. VUSD
     * @param account_ Address where PeggedToken will be minted
     * @param amount_ PeggedToken amount to mint
     */
    function mint(address account_, uint256 amount_) external {
        if (msg.sender != gateway) revert CallerIsNotGateway(msg.sender);
        _mint(account_, amount_);
    }

    /**
     * @notice Add address to blacklist
     * @param account_ address to blacklist
     */
    function addToBlacklist(address account_) external onlyOwner {
        if (account_ == address(0)) revert AddressIsZero();
        if (!_blacklistedAddresses.add(account_)) revert AlreadyBlacklisted(account_);
        emit AddedToBlacklist(account_);
    }

    /**
     * @notice Remove address from blacklist
     * @param account_ address to remove from blacklist
     */
    function removeFromBlacklist(address account_) external onlyOwner {
        if (!_blacklistedAddresses.remove(account_)) revert NotBlacklisted(account_);
        emit RemovedFromBlacklist(account_);
    }

    /**
     * @notice Update PeggedToken gateway address
     * @param newGateway_ new gateway address
     */
    function updateGateway(address newGateway_) external onlyOwner {
        // Must set treasury before setting gateway
        if (treasury == address(0)) revert TreasuryCanNotBeZero();
        if (newGateway_ == address(0)) revert AddressIsZero();
        emit UpdatedGateway(gateway, newGateway_);
        gateway = newGateway_;
    }

    /**
     * @notice Update PeggedToken treasury address
     * @param newTreasury_ new treasury address
     */
    function updateTreasury(address newTreasury_) external onlyOwner {
        if (newTreasury_ == address(0)) revert AddressIsZero();
        emit UpdatedTreasury(treasury, newTreasury_);
        treasury = newTreasury_;
    }

    /**
     * @notice Get all blacklisted addresses
     * @return array of blacklisted addresses
     */
    function getBlacklistedAddresses() external view returns (address[] memory) {
        return _blacklistedAddresses.values();
    }

    /**
     * @notice Check if address is blacklisted
     * @param account_ address to check
     * @return true if address is blacklisted
     */
    function isBlacklisted(address account_) external view returns (bool) {
        return _blacklistedAddresses.contains(account_);
    }

    /**
     * @notice Override _update to prevent transfers to/from blacklisted addresses
     * @param from_ sender address
     * @param to_ recipient address
     * @param value_ amount to transfer
     */
    function _update(address from_, address to_, uint256 value_) internal override {
        if (from_ != address(0) && _blacklistedAddresses.contains(from_)) {
            revert Blacklisted(from_);
        }
        if (to_ != address(0) && _blacklistedAddresses.contains(to_)) {
            revert Blacklisted(to_);
        }
        super._update(from_, to_, value_);
    }
}
