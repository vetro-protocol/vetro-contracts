// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title VUSD, A stablecoin pegged to the US Dollar, backed by interest-generating collateral.
contract VUSD is ERC20Permit, ERC20Burnable, Ownable2Step {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error AddressIsNull();
    error CallerIsNotGateway(address);
    error TreasuryIsNull();
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

    constructor(address owner_) ERC20Permit("VUSD") ERC20("VUSD", "VUSD") Ownable(owner_) {}

    /**
     * @notice Burn VUSD from account.
     * The caller must have allowance for accounts's tokens.
     * If Gateway is the caller then approval is not required.
     * @param account_ VUSD will be burnt from this address
     * @param amount_ VUSD amount to burn
     *
     * @inheritdoc ERC20Burnable
     */
    function burnFrom(address account_, uint256 amount_) public override {
        if (msg.sender != gateway) {
            _spendAllowance(account_, msg.sender, amount_);
        }
        _burn(account_, amount_);
    }

    /**
     * @notice onlyGateway:: Mint VUSD
     * @param account_ Address where VUSD will be minted
     * @param amount_ VUSD amount to mint
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
        if (account_ == address(0)) revert AddressIsNull();
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
     * @notice Update VUSD gateway address
     * @param newGateway_ new gateway address
     */
    function updateGateway(address newGateway_) external onlyOwner {
        // Must set treasury before setting gateway
        if (treasury == address(0)) revert TreasuryIsNull();
        if (newGateway_ == address(0)) revert AddressIsNull();
        emit UpdatedGateway(gateway, newGateway_);
        gateway = newGateway_;
    }

    /**
     * @notice Update VUSD treasury address
     * @param newTreasury_ new treasury address
     */
    function updateTreasury(address newTreasury_) external onlyOwner {
        if (newTreasury_ == address(0)) revert AddressIsNull();
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
