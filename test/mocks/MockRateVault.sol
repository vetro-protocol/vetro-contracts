// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC4626-shaped share token (6 decimals) whose share rate the test sets, like ctDefiUSDT. Like ctDefiUSDT's hook
/// manager, the test can install a pre-transfer hook on transfers between holders: block them, skim 1% of each, or
/// call a target first.
contract MockRateVault is ERC20 {
    enum Hook {
        None,
        Block,
        Skim,
        Call
    }

    error TransferBlocked();

    /// forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable asset;
    /// @dev Underlying per share, 18 decimals
    uint256 public rateWad = 1e18;

    Hook public hook;
    address public hookTarget;
    bytes public hookData;
    address public skimReceiver;

    constructor(address asset_) ERC20("Concrete DeFi USDT", "ctDefiUSDT") {
        asset = asset_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setRate(uint256 rateWad_) external {
        rateWad = rateWad_;
    }

    function setHook(Hook hook_, address target_, bytes calldata data_) external {
        hook = hook_;
        hookTarget = target_;
        hookData = data_;
        skimReceiver = target_;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return shares_ * rateWad / 1e18;
    }

    function convertToShares(uint256 assets_) external view returns (uint256) {
        return assets_ * 1e18 / rateWad;
    }

    function _update(address from_, address to_, uint256 value_) internal override {
        if (from_ != address(0) && to_ != address(0)) {
            Hook _hook = hook;
            if (_hook == Hook.Block) revert TransferBlocked();
            if (_hook == Hook.Skim) {
                uint256 _skim = value_ / 100;
                super._update(from_, skimReceiver, _skim);
                value_ -= _skim;
            } else if (_hook == Hook.Call) {
                // Pre-transfer: runs while `from_` still holds the shares
                (bool _ok, bytes memory _reason) = hookTarget.call(hookData);
                if (!_ok) {
                    assembly {
                        revert(add(_reason, 32), mload(_reason))
                    }
                }
            }
        }
        super._update(from_, to_, value_);
    }
}
