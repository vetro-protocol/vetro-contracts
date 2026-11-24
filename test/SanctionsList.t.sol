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

    function _listWithOracleCode(bytes memory code_) internal returns (SanctionsList) {
        address _oracle = makeAddr("rawOracle");
        vm.etch(_oracle, code_);
        return new SanctionsList(address(token), _oracle);
    }

    function test_isSanctioned_rawOracleReturnsTrue() public {
        // MSTORE(0, 1) RETURN(0, 32)
        assertTrue(_listWithOracleCode(hex"600160005260206000f3").isSanctioned(alice));
    }

    function test_isSanctioned_falseIfOracleReverts() public {
        assertFalse(_listWithOracleCode(hex"fe").isSanctioned(alice));
    }

    function test_isSanctioned_falseIfOracleReturnsEmpty() public {
        assertFalse(_listWithOracleCode(hex"00").isSanctioned(alice));
    }

    function test_isSanctioned_falseIfOracleHasNoCode() public {
        assertFalse(new SanctionsList(address(token), makeAddr("eoa")).isSanctioned(alice));
    }

    function test_isSanctioned_falseIfOracleReturnsShort() public {
        // MSTORE(0, 1) RETURN(0, 31)
        assertFalse(_listWithOracleCode(hex"6001600052601f6000f3").isSanctioned(alice));
    }

    function test_isSanctioned_falseIfOracleReturnsLong() public {
        // MSTORE(0, 1) RETURN(0, 64)
        assertFalse(_listWithOracleCode(hex"600160005260406000f3").isSanctioned(alice));
    }

    function test_isSanctioned_falseIfOracleReturnsLargeData() public {
        // MSTORE(0, 1) RETURN(0, 0x4000)
        assertFalse(_listWithOracleCode(hex"60016000526140006000f3").isSanctioned(alice));
    }

    function test_isSanctioned_falseIfOracleBurnsGas() public {
        // JUMPDEST PUSH1 0 JUMP
        SanctionsList _list = _listWithOracleCode(hex"5b600056");
        uint256 _gasBefore = gasleft();
        assertFalse(_list.isSanctioned{gas: 100_000}(alice));
        assertLt(_gasBefore - gasleft(), 100_000);
    }

    function test_isSanctioned_blacklistEnforcedIfOracleBroken() public {
        SanctionsList _list = _listWithOracleCode(hex"fe");
        token.addToBlacklist(alice);
        assertTrue(_list.isSanctioned(alice));
    }
}
