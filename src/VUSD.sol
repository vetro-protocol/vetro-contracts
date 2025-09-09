// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VUSD, A stablecoin pegged to the US Dollar, backed by interest-generating collateral.
contract VUSD is ERC20Permit, ERC20Burnable, Ownable2Step {
    using SafeERC20 for IERC20;

    error AddressIsNull();
    error CallerIsNotGateway(address);
    error TreasuryIsNull();

    address public gateway;
    address public treasury;

    event UpdatedGateway(address indexed previousGateway, address indexed newGateway);
    event UpdatedTreasury(address indexed previousTreasury, address indexed newTreasury);

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
}
