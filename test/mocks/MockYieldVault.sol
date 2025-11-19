// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// forge-lint: disable-next-item(erc20-unchecked-transfer)
contract MockYieldVault {
    /// forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable asset;
    mapping(address => uint256) public balances;

    constructor(address _asset) {
        asset = _asset;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * 10 ** IERC20Metadata(asset).decimals()) / (10 ** decimals());
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * 10 ** decimals()) / (10 ** IERC20Metadata(asset).decimals());
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        uint256 _shares = convertToShares(assets);
        balances[receiver] += _shares;
        return _shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(balances[owner] >= shares, "Insufficient share balance");
        uint256 _assets = convertToAssets(shares);
        require(IERC20(asset).balanceOf(address(this)) >= _assets, "Insufficient assets");

        balances[owner] -= shares;
        IERC20(asset).transfer(receiver, _assets);
        return _assets;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient share balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        require(IERC20(asset).balanceOf(address(this)) >= assets, "Insufficient assets");
        uint256 _shares = convertToShares(assets);
        require(balances[owner] >= _shares, "Insufficient share balance");

        balances[owner] -= _shares;
        IERC20(asset).transfer(receiver, assets);
        return assets;
    }
}
