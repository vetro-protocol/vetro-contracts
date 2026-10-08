// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Gateway} from "src/Gateway.sol";
import {PeggedToken} from "src/PeggedToken.sol";
import {StakingVault} from "src/StakingVault.sol";
import {Treasury} from "src/Treasury.sol";
import {YieldDistributor} from "src/YieldDistributor.sol";
import {
    VETRO_GOVERNOR,
    VUSD,
    VUSD_TREASURY,
    VUSD_GATEWAY,
    SVUSD,
    VUSD_YIELD_DISTRIBUTOR,
    VUSD_YIELD_MANAGER,
    VETBTC,
    VETBTC_TREASURY,
    VETBTC_GATEWAY,
    SVETBTC,
    VETBTC_YIELD_DISTRIBUTOR,
    VETBTC_YIELD_MANAGER
} from "test/helpers/Address.ethereum.sol";

/// @dev Forks mainnet and loads the deployed VUSD and vetBTC stacks. Pin the fork with ETHEREUM_FORK_BLOCK_NUMBER.
abstract contract VetroForkBase is Test {
    using SafeERC20 for IERC20;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Accounts that hold or held a role or whitelist entry but are not discoverable on-chain (membership mappings
    // are not enumerable). Collected from RoleGranted / InstantWithdrawWhitelistUpdated events; keep in sync with
    // KNOWN_ACCOUNTS in tasks/upgrade-snapshot.ts.
    address internal constant SVETBTC_INSTANT_WITHDRAWER = 0xF5F5195cF6998c57C651f9f0bBFA7cFC72a6FaC1;
    address internal constant VETBTC_DEPLOYER = 0x26D4333E2E5572A5609ddEDd65748F8F237042D9; // still a Treasury keeper
    address internal constant VUSD_DEPLOYER = 0xE173b056eF552c7322040703dDfC1e0638A575d3;
    address internal constant VETBTC_TREASURY_GRANTEE = 0xAF27289D8612574A2bF58f30aD1835bA9D56Bfc2;
    address internal constant TREASURY_GRANTEE = 0x421382cf4e6eB73663ABb6d011d60Be66F126553; // both stacks

    struct Stack {
        string name;
        PeggedToken token;
        Treasury treasury;
        Gateway gateway;
        StakingVault vault;
        YieldDistributor distributor;
        // Collateral amount used per flow, as a fraction of one whole token
        uint256 unitsNumerator;
        uint256 unitsDenominator;
    }

    Stack internal vusd;
    Stack internal vetbtc;

    function setUp() public virtual {
        uint256 _block = vm.envOr("ETHEREUM_FORK_BLOCK_NUMBER", uint256(0));
        if (_block == 0) vm.createSelectFork("ethereum");
        else vm.createSelectFork("ethereum", _block);

        vusd = Stack({
            name: "VUSD",
            token: PeggedToken(VUSD),
            treasury: Treasury(VUSD_TREASURY),
            gateway: Gateway(VUSD_GATEWAY),
            vault: StakingVault(SVUSD),
            distributor: YieldDistributor(VUSD_YIELD_DISTRIBUTOR),
            unitsNumerator: 1_000,
            unitsDenominator: 1
        });
        vetbtc = Stack({
            name: "vetBTC",
            token: PeggedToken(VETBTC),
            treasury: Treasury(VETBTC_TREASURY),
            gateway: Gateway(VETBTC_GATEWAY),
            vault: StakingVault(SVETBTC),
            distributor: YieldDistributor(VETBTC_YIELD_DISTRIBUTOR),
            unitsNumerator: 1,
            unitsDenominator: 100
        });
    }

    function _stacks() internal view returns (Stack[2] memory) {
        return [vusd, vetbtc];
    }

    /// @dev Upgrades all six proxies to this repo's implementations, the way the Safe batch does
    function _upgradeAll() internal {
        address _gateway = address(new Gateway());
        address _vault = address(new StakingVault());
        address _distributor = address(new YieldDistributor());
        Stack[2] memory _s = _stacks();
        for (uint256 i; i < _s.length; ++i) {
            _upgrade(address(_s[i].gateway), _gateway);
            _upgrade(address(_s[i].vault), _vault);
            _upgrade(address(_s[i].distributor), _distributor);
        }
    }

    function _upgrade(address proxy_, address implementation_) private {
        ProxyAdmin _admin = ProxyAdmin(_slotAddress(proxy_, ADMIN_SLOT));
        vm.prank(_admin.owner());
        _admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy_), implementation_, "");
        assertEq(_slotAddress(proxy_, IMPLEMENTATION_SLOT), implementation_, "implementation not upgraded");
    }

    function _slotAddress(address target_, bytes32 slot_) internal view returns (address) {
        return address(uint160(uint256(vm.load(target_, slot_))));
    }

    /// @dev Every account the protocol is known to grant a role or whitelist entry to
    function _knownAccounts() internal view returns (address[] memory accounts_) {
        address[] memory _vusdWhitelist = vusd.gateway.getInstantRedeemWhitelist();
        address[] memory _vetbtcWhitelist = vetbtc.gateway.getInstantRedeemWhitelist();
        address[8] memory _fixed = [
            VETRO_GOVERNOR,
            VUSD_YIELD_MANAGER,
            VETBTC_YIELD_MANAGER,
            SVETBTC_INSTANT_WITHDRAWER,
            VETBTC_DEPLOYER,
            VUSD_DEPLOYER,
            VETBTC_TREASURY_GRANTEE,
            TREASURY_GRANTEE
        ];

        accounts_ = new address[](_vusdWhitelist.length + _vetbtcWhitelist.length + _fixed.length);
        uint256 _n;
        for (uint256 i; i < _vusdWhitelist.length; ++i) {
            accounts_[_n++] = _vusdWhitelist[i];
        }
        for (uint256 i; i < _vetbtcWhitelist.length; ++i) {
            accounts_[_n++] = _vetbtcWhitelist[i];
        }
        for (uint256 i; i < _fixed.length; ++i) {
            accounts_[_n++] = _fixed[i];
        }
    }
}

/// @dev Reads every stored value through the live implementations, upgrades in the same block and reads again.
///      Same block means even price/time dependent values (share price, reserve, previews) must be identical: an
///      upgrade that moves them is a discontinuity someone could arbitrage, so it must be deliberate.
contract UpgradeStateForkTest is VetroForkBase {
    struct Probe {
        address target;
        bytes data;
        string label;
    }

    struct Probes {
        Probe[] items;
        uint256 length;
        string stack;
    }

    function test_upgrade_preservesState() public {
        Probe[] memory _probes = _allProbes(_knownAccounts());
        bytes[] memory _before = _read(_probes);

        _upgradeAll();

        bytes[] memory _after = _read(_probes);
        for (uint256 i; i < _probes.length; ++i) {
            assertEq(_after[i], _before[i], _probes[i].label);
        }
    }

    function _read(Probe[] memory probes_) private view returns (bytes[] memory results_) {
        results_ = new bytes[](probes_.length);
        for (uint256 i; i < probes_.length; ++i) {
            // A probe reverting on both sides would compare equal and prove nothing, so every read must succeed
            (bool _success, bytes memory _result) = probes_[i].target.staticcall(probes_[i].data);
            assertTrue(_success, string.concat("reverted: ", probes_[i].label));
            results_[i] = _result;
        }
    }

    function _allProbes(address[] memory accounts_) private view returns (Probe[] memory probes_) {
        Stack[2] memory _s = _stacks();
        Probes memory _p = Probes({items: new Probe[](256), length: 0, stack: ""});
        for (uint256 i; i < _s.length; ++i) {
            _p.stack = _s[i].name;
            _gatewayProbes(_p, _s[i]);
            _vaultProbes(_p, _s[i]);
            _distributorProbes(_p, _s[i]);
            for (uint256 j; j < accounts_.length; ++j) {
                _accountProbes(_p, _s[i], accounts_[j]);
            }
        }
        probes_ = _p.items;
        uint256 _length = _p.length;
        assembly {
            mstore(probes_, _length)
        }
    }

    function _gatewayProbes(Probes memory p_, Stack memory s_) private view {
        address _g = address(s_.gateway);
        _add(p_, address(s_.token), abi.encodeCall(IERC20.totalSupply, ()), "token.totalSupply");
        _add(p_, _g, abi.encodeCall(Gateway.NAME, ()), "gateway.NAME");
        _add(p_, _g, abi.encodeCall(Gateway.owner, ()), "gateway.owner");
        _add(p_, _g, abi.encodeCall(Gateway.treasury, ()), "gateway.treasury");
        _add(p_, _g, abi.encodeCall(Gateway.mintLimit, ()), "gateway.mintLimit");
        _add(p_, _g, abi.encodeCall(Gateway.amoMintLimit, ()), "gateway.amoMintLimit");
        _add(p_, _g, abi.encodeCall(Gateway.amoSupply, ()), "gateway.amoSupply");
        _add(p_, _g, abi.encodeCall(Gateway.maxMint, ()), "gateway.maxMint");
        _add(p_, _g, abi.encodeCall(Gateway.maxAmoMint, ()), "gateway.maxAmoMint");
        _add(p_, _g, abi.encodeCall(Gateway.withdrawalDelay, ()), "gateway.withdrawalDelay");
        _add(p_, _g, abi.encodeCall(Gateway.withdrawalDelayEnabled, ()), "gateway.withdrawalDelayEnabled");
        _add(p_, _g, abi.encodeCall(Gateway.getInstantRedeemWhitelist, ()), "gateway.getInstantRedeemWhitelist");

        address[] memory _tokens = s_.treasury.whitelistedTokens();
        for (uint256 i; i < _tokens.length; ++i) {
            _collateralProbes(p_, _g, _tokens[i]);
        }
    }

    function _collateralProbes(Probes memory p_, address gateway_, address collateral_) private view {
        string memory _l = vm.toString(collateral_);
        uint256 _unit = 10 ** IERC20Metadata(collateral_).decimals();
        _add(p_, gateway_, abi.encodeCall(Gateway.mintFee, (collateral_)), string.concat("gateway.mintFee.", _l));
        _add(p_, gateway_, abi.encodeCall(Gateway.redeemFee, (collateral_)), string.concat("gateway.redeemFee.", _l));
        _add(p_, gateway_, abi.encodeCall(Gateway.pegBand, (collateral_)), string.concat("gateway.pegBand.", _l));
        _add(
            p_, gateway_, abi.encodeCall(Gateway.maxWithdraw, (collateral_)), string.concat("gateway.maxWithdraw.", _l)
        );
        _add(
            p_,
            gateway_,
            abi.encodeCall(Gateway.previewDeposit, (collateral_, _unit)),
            string.concat("gateway.previewDeposit.", _l)
        );
        _add(
            p_,
            gateway_,
            abi.encodeCall(Gateway.previewRedeem, (collateral_, 1e18)),
            string.concat("gateway.previewRedeem.", _l)
        );
    }

    function _vaultProbes(Probes memory p_, Stack memory s_) private view {
        address _v = address(s_.vault);
        _add(p_, _v, abi.encodeWithSignature("name()"), "vault.name");
        _add(p_, _v, abi.encodeWithSignature("symbol()"), "vault.symbol");
        _add(p_, _v, abi.encodeWithSignature("decimals()"), "vault.decimals");
        _add(p_, _v, abi.encodeWithSignature("asset()"), "vault.asset");
        _add(p_, _v, abi.encodeWithSignature("totalSupply()"), "vault.totalSupply");
        _add(p_, _v, abi.encodeWithSignature("totalAssets()"), "vault.totalAssets");
        _add(p_, _v, abi.encodeWithSignature("convertToAssets(uint256)", 1e18), "vault.sharePrice");
        _add(p_, _v, abi.encodeWithSignature("owner()"), "vault.owner");
        _add(p_, _v, abi.encodeWithSignature("pendingOwner()"), "vault.pendingOwner");
        _add(p_, _v, abi.encodeCall(StakingVault.yieldDistributor, ()), "vault.yieldDistributor");
        _add(p_, _v, abi.encodeCall(StakingVault.vaultRewards, ()), "vault.vaultRewards");
        _add(p_, _v, abi.encodeCall(StakingVault.cooldownDuration, ()), "vault.cooldownDuration");
        _add(p_, _v, abi.encodeCall(StakingVault.cooldownEnabled, ()), "vault.cooldownEnabled");
        _add(p_, _v, abi.encodeCall(StakingVault.totalAssetsInCooldown, ()), "vault.totalAssetsInCooldown");
        _add(p_, _v, abi.encodeCall(StakingVault.nextRequestId, ()), "vault.nextRequestId");

        // Cooldown requests live in a namespaced mapping: every one ever created must read back unchanged
        uint256 _nextRequestId = s_.vault.nextRequestId();
        for (uint256 _id; _id < _nextRequestId; ++_id) {
            _add(
                p_,
                _v,
                abi.encodeCall(StakingVault.getRequestDetails, (_id)),
                string.concat("vault.getRequestDetails.", vm.toString(_id))
            );
        }
    }

    function _distributorProbes(Probes memory p_, Stack memory s_) private pure {
        address _d = address(s_.distributor);
        _add(p_, _d, abi.encodeCall(YieldDistributor.asset, ()), "distributor.asset");
        _add(p_, _d, abi.encodeCall(YieldDistributor.vault, ()), "distributor.vault");
        _add(p_, _d, abi.encodeCall(YieldDistributor.yieldDuration, ()), "distributor.yieldDuration");
        _add(p_, _d, abi.encodeCall(YieldDistributor.periodFinish, ()), "distributor.periodFinish");
        _add(p_, _d, abi.encodeCall(YieldDistributor.rewardRate, ()), "distributor.rewardRate");
        _add(p_, _d, abi.encodeCall(YieldDistributor.lastUpdateTime, ()), "distributor.lastUpdateTime");
        _add(p_, _d, abi.encodeCall(YieldDistributor.pendingYield, ()), "distributor.pendingYield");
        _add(p_, _d, abi.encodeWithSignature("defaultAdmin()"), "distributor.defaultAdmin");
        _add(p_, _d, abi.encodeWithSignature("defaultAdminDelay()"), "distributor.defaultAdminDelay");
        _add(p_, _d, abi.encodeWithSignature("pendingDefaultAdmin()"), "distributor.pendingDefaultAdmin");
    }

    function _accountProbes(Probes memory p_, Stack memory s_, address account_) private view {
        string memory _l = vm.toString(account_);
        address _g = address(s_.gateway);
        address _v = address(s_.vault);
        address _d = address(s_.distributor);
        bytes32 _distributorRole = s_.distributor.DISTRIBUTOR_ROLE();

        _add(p_, address(s_.token), abi.encodeCall(IERC20.balanceOf, (account_)), string.concat("token.balanceOf.", _l));
        _add(
            p_, _g, abi.encodeCall(Gateway.getRedeemRequest, (account_)), string.concat("gateway.getRedeemRequest.", _l)
        );
        _add(
            p_,
            _g,
            abi.encodeCall(Gateway.isInstantRedeemWhitelisted, (account_)),
            string.concat("gateway.isInstantRedeemWhitelisted.", _l)
        );
        _add(
            p_,
            _v,
            abi.encodeCall(StakingVault.instantWithdrawWhitelist, (account_)),
            string.concat("vault.instantWithdrawWhitelist.", _l)
        );
        _add(
            p_,
            _v,
            abi.encodeCall(StakingVault.getActiveRequestIds, (account_)),
            string.concat("vault.getActiveRequestIds.", _l)
        );
        _add(p_, _v, abi.encodeWithSignature("balanceOf(address)", account_), string.concat("vault.balanceOf.", _l));
        _add(p_, _v, abi.encodeWithSignature("maxRedeem(address)", account_), string.concat("vault.maxRedeem.", _l));
        _add(
            p_,
            _d,
            abi.encodeWithSignature("hasRole(bytes32,address)", _distributorRole, account_),
            string.concat("distributor.hasDistributorRole.", _l)
        );
        _add(
            p_,
            _d,
            abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), account_),
            string.concat("distributor.hasAdminRole.", _l)
        );
    }

    function _add(Probes memory p_, address target_, bytes memory data_, string memory label_) private pure {
        // Cooldown requests keep growing on-chain, so grow the list rather than guess its size
        if (p_.length == p_.items.length) {
            Probe[] memory _grown = new Probe[](p_.items.length * 2);
            for (uint256 i; i < p_.length; ++i) {
                _grown[i] = p_.items[i];
            }
            p_.items = _grown;
        }
        p_.items[p_.length++] = Probe({target: target_, data: data_, label: string.concat(p_.stack, ".", label_)});
    }
}

/// @dev User, keeper and integrator flows against the deployed contracts. Run as-is by `LiveForkTest` and after the
///      upgrade by `UpgradedForkTest`, so a flow that breaks only after the upgrade fails only there.
abstract contract VetroFlowsForkTest is VetroForkBase {
    using SafeERC20 for IERC20;

    function test_vusd_depositAndRedeem() public {
        _depositAndRedeem(vusd);
    }

    function test_vetbtc_depositAndRedeem() public {
        _depositAndRedeem(vetbtc);
    }

    function test_vusd_stakeAndCooldown() public {
        _stakeAndCooldown(vusd);
    }

    function test_vetbtc_stakeAndCooldown() public {
        _stakeAndCooldown(vetbtc);
    }

    function test_vusd_distributeYield() public {
        _distributeYield(vusd);
    }

    function test_vetbtc_distributeYield() public {
        _distributeYield(vetbtc);
    }

    function test_vusd_integratorsRedeemInstantly() public {
        _integratorsRedeemInstantly(vusd);
    }

    function test_vetbtc_integratorsRedeemInstantly() public {
        _integratorsRedeemInstantly(vetbtc);
    }

    /// @dev Every active collateral can be deposited and, after the withdrawal delay, redeemed again
    function _depositAndRedeem(Stack memory s_) internal {
        _extendOracleStalePeriods(s_);
        address[] memory _tokens = _activeTokens(s_);
        assertGt(_tokens.length, 0, "no active collateral");

        for (uint256 i; i < _tokens.length; ++i) {
            address _collateral = _tokens[i];
            address _user = makeAddr(string.concat(s_.name, "-user-", vm.toString(_collateral)));
            uint256 _amountIn = _amount(s_, _collateral);
            uint256 _minted = _deposit(s_, _collateral, _user, _amountIn);

            vm.startPrank(_user);
            IERC20(address(s_.token)).forceApprove(address(s_.gateway), _minted);
            if (s_.gateway.withdrawalDelayEnabled()) {
                // Users outside the whitelist must wait out the delay
                vm.expectRevert();
                s_.gateway.redeem(_collateral, _minted, 0, _user);
                s_.gateway.requestRedeem(_minted);
                skip(s_.gateway.withdrawalDelay());
            }
            uint256 _expectedOut = s_.gateway.previewRedeem(_collateral, _minted);
            uint256 _out = s_.gateway.redeem(_collateral, _minted, _expectedOut, _user);
            vm.stopPrank();

            assertEq(_out, _expectedOut, "redeem != preview");
            assertEq(IERC20(_collateral).balanceOf(_user), _out, "collateral not received");
            assertEq(s_.token.balanceOf(_user), 0, "pegged token not burned");
            assertApproxEqRel(_out, _amountIn, 0.01e18, "round trip lost more than 1%");
        }
    }

    /// @dev Stake, request a cooldown withdrawal, and claim it once matured
    function _stakeAndCooldown(Stack memory s_) internal {
        _extendOracleStalePeriods(s_);
        address _user = makeAddr(string.concat(s_.name, "-staker"));
        (uint256 _shares, uint256 _staked) = _stake(s_, _user);

        vm.startPrank(_user);
        if (s_.vault.cooldownEnabled()) {
            vm.expectRevert();
            s_.vault.redeem(_shares, _user, _user);

            (uint256 _requestId, uint256 _assets) = s_.vault.requestRedeem(_shares, _user);
            assertApproxEqAbs(_assets, _staked, 1, "request assets != staked");
            assertEq(s_.vault.balanceOf(_user), 0, "shares not burned on request");

            vm.expectRevert();
            s_.vault.claimWithdraw(_requestId, _user);

            skip(s_.vault.cooldownDuration());
            uint256 _claimed = s_.vault.claimWithdraw(_requestId, _user);
            assertEq(_claimed, _assets, "claimed != requested");
        } else {
            s_.vault.redeem(_shares, _user, _user);
        }
        vm.stopPrank();

        assertApproxEqAbs(s_.token.balanceOf(_user), _staked, 1, "stake not returned");
    }

    /// @dev Distributed yield streams into the vault and raises the share price
    function _distributeYield(Stack memory s_) internal {
        _extendOracleStalePeriods(s_);
        address _staker = makeAddr(string.concat(s_.name, "-yield-staker"));
        (uint256 _shares,) = _stake(s_, _staker);

        address _distributor = makeAddr(string.concat(s_.name, "-distributor"));
        bytes32 _role = s_.distributor.DISTRIBUTOR_ROLE();
        vm.prank(s_.distributor.defaultAdmin());
        s_.distributor.grantRole(_role, _distributor);

        address _collateral = _activeTokens(s_)[0];
        uint256 _yield = _deposit(s_, _collateral, _distributor, _amount(s_, _collateral));
        uint256 _rewardRateBefore = s_.distributor.rewardRate();
        vm.startPrank(_distributor);
        IERC20(address(s_.token)).forceApprove(address(s_.distributor), _yield);
        s_.distributor.distribute(_yield);
        vm.stopPrank();
        assertGt(s_.distributor.rewardRate(), _rewardRateBefore, "reward rate did not increase");

        uint256 _assetsBefore = s_.vault.convertToAssets(_shares);
        uint256 _totalAssetsBefore = s_.vault.totalAssets();
        skip(1 days);
        assertGt(s_.distributor.pendingYield(), 0, "no yield accrued");
        assertGt(s_.vault.totalAssets(), _totalAssetsBefore, "total assets did not grow");
        assertGt(s_.vault.convertToAssets(_shares), _assetsBefore, "share price did not grow");

        // Any vault interaction pulls the streamed yield in
        vm.prank(_staker);
        s_.vault.requestRedeem(_shares / 2, _staker);
        assertEq(s_.distributor.pendingYield(), 0, "yield not pulled");
    }

    /// @dev Arbitrage bots and Hemi agents skip the Gateway delay and the vault cooldown
    function _integratorsRedeemInstantly(Stack memory s_) internal {
        _extendOracleStalePeriods(s_);
        address _collateral = _activeTokens(s_)[0];

        address[] memory _whitelist = s_.gateway.getInstantRedeemWhitelist();
        assertGt(_whitelist.length, 0, "gateway whitelist empty");
        for (uint256 i; i < _whitelist.length; ++i) {
            address _account = _whitelist[i];
            (, uint256 _claimableAt) = s_.gateway.getRedeemRequest(_account);
            // A pending request would route the redeem through it instead of the whitelist
            if (_claimableAt != 0) continue;

            uint256 _minted = _deposit(s_, _collateral, _account, _amount(s_, _collateral));
            uint256 _collateralBefore = IERC20(_collateral).balanceOf(_account);
            vm.startPrank(_account);
            IERC20(address(s_.token)).forceApprove(address(s_.gateway), _minted);
            uint256 _out = s_.gateway.redeem(_collateral, _minted, 0, _account);
            vm.stopPrank();
            assertEq(IERC20(_collateral).balanceOf(_account) - _collateralBefore, _out, "integrator redeem failed");
        }

        address[] memory _accounts = _knownAccounts();
        uint256 _instantWithdrawers;
        for (uint256 i; i < _accounts.length; ++i) {
            address _account = _accounts[i];
            if (!s_.vault.instantWithdrawWhitelist(_account)) continue;
            ++_instantWithdrawers;

            (uint256 _shares, uint256 _staked) = _stake(s_, _account);
            uint256 _tokenBefore = s_.token.balanceOf(_account);
            vm.prank(_account);
            uint256 _assets = s_.vault.redeem(_shares, _account, _account);
            assertApproxEqAbs(_assets, _staked, 1, "instant withdraw amount");
            assertEq(s_.token.balanceOf(_account) - _tokenBefore, _assets, "instant withdraw failed");
        }
        assertGt(_instantWithdrawers, 0, "vault whitelist empty");
    }

    function _deposit(Stack memory s_, address collateral_, address user_, uint256 amountIn_)
        internal
        returns (uint256 minted_)
    {
        deal(collateral_, user_, amountIn_);
        uint256 _expected = s_.gateway.previewDeposit(collateral_, amountIn_);
        uint256 _balanceBefore = s_.token.balanceOf(user_);

        vm.startPrank(user_);
        IERC20(collateral_).forceApprove(address(s_.gateway), amountIn_);
        minted_ = s_.gateway.deposit(collateral_, amountIn_, _expected, user_);
        vm.stopPrank();

        assertEq(minted_, _expected, "deposit != preview");
        assertEq(s_.token.balanceOf(user_) - _balanceBefore, minted_, "pegged token not minted");
    }

    function _stake(Stack memory s_, address user_) internal returns (uint256 shares_, uint256 staked_) {
        address _collateral = _activeTokens(s_)[0];
        staked_ = _deposit(s_, _collateral, user_, _amount(s_, _collateral));
        uint256 _expectedShares = s_.vault.previewDeposit(staked_);

        vm.startPrank(user_);
        IERC20(address(s_.token)).forceApprove(address(s_.vault), staked_);
        shares_ = s_.vault.deposit(staked_, user_);
        vm.stopPrank();
        assertEq(shares_, _expectedShares, "shares != preview");
    }

    function _activeTokens(Stack memory s_) internal view returns (address[] memory tokens_) {
        address[] memory _all = s_.treasury.whitelistedTokens();
        tokens_ = new address[](_all.length);
        uint256 _n;
        for (uint256 i; i < _all.length; ++i) {
            (,,, bool _depositActive, bool _withdrawActive,) = s_.treasury.tokenConfig(_all[i]);
            if (_depositActive && _withdrawActive) tokens_[_n++] = _all[i];
        }
        assembly {
            mstore(tokens_, _n)
        }
    }

    function _amount(Stack memory s_, address collateral_) internal view returns (uint256) {
        return 10 ** IERC20Metadata(collateral_).decimals() * s_.unitsNumerator / s_.unitsDenominator;
    }

    /// @dev Flows skip time forward, and some feeds update only daily, so avoid failing on oracle staleness
    function _extendOracleStalePeriods(Stack memory s_) internal {
        address[] memory _tokens = s_.treasury.whitelistedTokens();
        uint256 _maxStalePeriod = s_.treasury.MAX_STALE_PERIOD();
        for (uint256 i; i < _tokens.length; ++i) {
            (, address _oracle,,,,) = s_.treasury.tokenConfig(_tokens[i]);
            vm.prank(VETRO_GOVERNOR);
            s_.treasury.updateOracle(_tokens[i], _oracle, _maxStalePeriod);
        }
    }
}

contract LiveForkTest is VetroFlowsForkTest {}

contract UpgradedForkTest is VetroFlowsForkTest {
    function setUp() public override {
        super.setUp();
        _upgradeAll();
    }
}
