// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice ERC4626-style mock with a drifting price-per-share and an optional illiquid strategy.
/// @dev MockYieldVault is fixed 1:1 and always fully liquid, so it can never exercise reserve
///      accounting under share appreciation, nor the redeem-under-illiquidity path where
///      convertToAssets(shares) exceeds what withdraw() can actually deliver. This mock can.
/// forge-lint: disable-next-item(erc20-unchecked-transfer)
contract MockYieldVaultRealistic {
    using Math for uint256;

    /// forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable asset;
    uint8 private immutable _assetDecimals;

    mapping(address => uint256) public balances; // vault shares, 18 decimals
    uint256 public totalShares;
    uint256 public totalManagedAssets; // NAV in asset units; drifts with yield
    uint256 public liquidCap; // per-call withdraw ceiling; 0 leaves the vault fully liquid

    constructor(address asset_) {
        asset = asset_;
        _assetDecimals = IERC20Metadata(asset_).decimals();
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function totalAssets() external view returns (uint256) {
        return totalManagedAssets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalShares == 0 || totalManagedAssets == 0) {
            return assets.mulDiv(1e18, 10 ** _assetDecimals);
        }
        return assets.mulDiv(totalShares, totalManagedAssets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalShares == 0) {
            return shares.mulDiv(10 ** _assetDecimals, 1e18);
        }
        return shares.mulDiv(totalManagedAssets, totalShares);
    }

    function maxWithdraw(address owner_) external view returns (uint256) {
        uint256 _assets = convertToAssets(balances[owner_]);
        uint256 _available = _liquidAvailable();
        return _assets < _available ? _assets : _available;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        shares = convertToShares(assets);
        balances[receiver] += shares;
        totalShares += shares;
        totalManagedAssets += assets;
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        require(assets <= _liquidAvailable(), "MockYieldVaultRealistic: illiquid");
        shares = convertToShares(assets);
        require(balances[owner_] >= shares, "MockYieldVaultRealistic: insufficient shares");
        balances[owner_] -= shares;
        totalShares -= shares;
        totalManagedAssets -= assets;
        IERC20(asset).transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        require(assets <= _liquidAvailable(), "MockYieldVaultRealistic: illiquid");
        require(balances[owner_] >= shares, "MockYieldVaultRealistic: insufficient shares");
        balances[owner_] -= shares;
        totalShares -= shares;
        totalManagedAssets -= assets;
        IERC20(asset).transfer(receiver, assets);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "MockYieldVaultRealistic: insufficient shares");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    /// @notice Donate `amount` of asset into the vault, raising the price-per-share.
    function simulateYield(uint256 amount) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        totalManagedAssets += amount;
    }

    /// @notice Cap assets withdrawable per call to model an illiquid strategy; 0 restores full liquidity.
    function setLiquidCap(uint256 cap) external {
        liquidCap = cap;
    }

    function _liquidAvailable() private view returns (uint256) {
        uint256 _balance = IERC20(asset).balanceOf(address(this));
        if (liquidCap != 0 && liquidCap < _balance) return liquidCap;
        return _balance;
    }
}
