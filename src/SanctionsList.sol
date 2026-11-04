// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IPeggedToken} from "./interfaces/IPeggedToken.sol";
import {ISanctionsList} from "./interfaces/ISanctionsList.sol";

/// @title SanctionsList - The single place Gateway and StakingVault ask whether an account is sanctioned
/// @notice Flags accounts blacklisted on the PeggedToken or listed by an external sanctions oracle (e.g. RedStone).
///         One deployment per PeggedToken. Both sources are immutable: changing either is a new deployment set on the
///         Treasury. A zero oracle checks the blacklist only, e.g. to replace an oracle that is down.
contract SanctionsList is ISanctionsList {
    string public constant VERSION = "1.0.0";

    IPeggedToken public immutable PEGGED_TOKEN;
    /// @notice Chainalysis-compatible sanctions oracle, address(0) for blacklist only
    ISanctionsList public immutable SANCTIONS_ORACLE;

    error AddressIsZero();

    constructor(address peggedToken_, address sanctionsOracle_) {
        if (peggedToken_ == address(0)) revert AddressIsZero();
        PEGGED_TOKEN = IPeggedToken(peggedToken_);
        SANCTIONS_ORACLE = ISanctionsList(sanctionsOracle_);
    }

    /// @inheritdoc ISanctionsList
    /// @dev Reverts if the oracle reverts, which blocks the gated flows until governance points them at another list
    function isSanctioned(address account_) external view returns (bool) {
        if (PEGGED_TOKEN.isBlacklisted(account_)) return true;
        return address(SANCTIONS_ORACLE) != address(0) && SANCTIONS_ORACLE.isSanctioned(account_);
    }
}
