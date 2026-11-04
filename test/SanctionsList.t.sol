// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SanctionsList} from "src/SanctionsList.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {MockSanctionsList} from "test/mocks/MockSanctionsList.sol";

contract SanctionsListTest is Test {
    PeggedToken token;
    MockSanctionsList oracle;
    SanctionsList list;

    address alice = makeAddr("alice");

    function setUp() public {
        token = new PeggedToken("VUSD", "VUSD", address(this));
        oracle = new MockSanctionsList();
        list = new SanctionsList(address(token), address(oracle));
    }

    function test_constructor() public view {
        assertEq(address(list.PEGGED_TOKEN()), address(token));
        assertEq(address(list.SANCTIONS_ORACLE()), address(oracle));
        assertEq(list.VERSION(), "1.0.0");
    }

    function test_constructor_revertIfTokenZero() public {
        vm.expectRevert(SanctionsList.AddressIsZero.selector);
        new SanctionsList(address(0), address(oracle));
    }

    function test_isSanctioned_blacklistOnlyWithoutOracle() public {
        SanctionsList _list = new SanctionsList(address(token), address(0));
        assertEq(address(_list.SANCTIONS_ORACLE()), address(0));

        oracle.setSanctioned(alice, true);
        assertFalse(_list.isSanctioned(alice));

        token.addToBlacklist(alice);
        assertTrue(_list.isSanctioned(alice));
    }

    function test_isSanctioned_cleanAccount() public view {
        assertFalse(list.isSanctioned(alice));
    }

    function test_isSanctioned_followsBlacklist() public {
        token.addToBlacklist(alice);
        assertTrue(list.isSanctioned(alice));
        token.removeFromBlacklist(alice);
        assertFalse(list.isSanctioned(alice));
    }

    function test_isSanctioned_followsOracle() public {
        oracle.setSanctioned(alice, true);
        assertTrue(list.isSanctioned(alice));
        oracle.setSanctioned(alice, false);
        assertFalse(list.isSanctioned(alice));
    }

    function test_isSanctioned_revertsWithOracle() public {
        address _broken = makeAddr("broken");
        vm.etch(_broken, hex"fe");
        SanctionsList _list = new SanctionsList(address(token), _broken);
        vm.expectRevert();
        _list.isSanctioned(alice);

        // A blacklisted account short-circuits before the oracle call
        token.addToBlacklist(alice);
        assertTrue(_list.isSanctioned(alice));
    }
}
