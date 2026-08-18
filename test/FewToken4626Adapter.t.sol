// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IFewFactory, IFewWrappedToken} from "../src/interfaces/IFew.sol";
import {FewToken4626Adapter} from "../src/adapters/FewToken4626Adapter.sol";

contract AdapterMockToken is ERC20 {
    uint8 internal immutable _mockDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _mockDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _mockDecimals;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function burn(address owner, uint256 amount) external {
        _burn(owner, amount);
    }
}

contract AdapterMockFewFactory {
    mapping(address origin => address wrapper) public getWrappedToken;
    bool public paused;

    function setWrappedToken(address origin, address wrapper) external {
        getWrappedToken[origin] = wrapper;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }
}

contract AdapterMockFewToken is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable factory;
    uint8 internal immutable _mockDecimals;
    bool public conversionPaused;
    bool public feeOnTransfer;
    bool public underMintWrap;

    constructor(address origin_, address factory_, uint8 decimals_) ERC20("Few Origin", "fwORG") {
        token = IERC20(origin_);
        factory = factory_;
        _mockDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _mockDecimals;
    }

    function setConversionPaused(bool paused_) external {
        conversionPaused = paused_;
    }

    function setFeeOnTransfer(bool enabled) external {
        feeOnTransfer = enabled;
    }

    function setUnderMintWrap(bool enabled) external {
        underMintWrap = enabled;
    }

    function wrapTo(uint256 amount, address to) external returns (uint256) {
        require(!conversionPaused, "conversion paused");
        require(amount != 0, "zero");
        token.safeTransferFrom(msg.sender, address(this), amount);
        _mint(to, underMintWrap ? amount - 1 : amount);
        return amount;
    }

    function unwrapTo(uint256 amount, address to) external returns (uint256) {
        require(!conversionPaused, "conversion paused");
        require(amount != 0, "zero");
        _burn(msg.sender, amount);
        token.safeTransfer(to, amount);
        return amount;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOnTransfer && from != address(0) && to != address(0) && value > 1) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, value);
        }
    }
}

contract AdapterMockOriginVault is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public depositCap = type(uint256).max;
    uint256 public withdrawCap = type(uint256).max;
    bool public depositsPaused;
    bool public withdrawalsPaused;
    bool public maxDepositReverts;
    bool public maxWithdrawReverts;
    bool public previewRedeemReverts;
    bool public entryFeeReported;
    bool public exitFeeReported;
    bool public withdrawFeeReported;
    bool public underMintDeposit;
    bool public underpayWithdraw;

    constructor(IERC20 asset_) ERC20("Origin Vault", "vORG") ERC4626(asset_) {}

    function setDepositCap(uint256 cap) external {
        depositCap = cap;
    }

    function setWithdrawCap(uint256 cap) external {
        withdrawCap = cap;
    }

    function setDepositsPaused(bool paused_) external {
        depositsPaused = paused_;
    }

    function setWithdrawalsPaused(bool paused_) external {
        withdrawalsPaused = paused_;
    }

    function setMaxDepositReverts(bool enabled) external {
        maxDepositReverts = enabled;
    }

    function setMaxWithdrawReverts(bool enabled) external {
        maxWithdrawReverts = enabled;
    }

    function setPreviewRedeemReverts(bool enabled) external {
        previewRedeemReverts = enabled;
    }

    function setEntryFeeReported(bool enabled) external {
        entryFeeReported = enabled;
    }

    function setExitFeeReported(bool enabled) external {
        exitFeeReported = enabled;
    }

    function setWithdrawFeeReported(bool enabled) external {
        withdrawFeeReported = enabled;
    }

    function setUnderMintDeposit(bool enabled) external {
        underMintDeposit = enabled;
    }

    function setUnderpayWithdraw(bool enabled) external {
        underpayWithdraw = enabled;
    }

    function addYield(uint256 amount) external {
        AdapterMockToken(asset()).mint(address(this), amount);
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (maxDepositReverts) revert("max deposit unavailable");
        return depositsPaused ? 0 : depositCap;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (maxWithdrawReverts) revert("max withdraw unavailable");
        if (withdrawalsPaused) return 0;
        uint256 claim = super.maxWithdraw(owner);
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        if (claim > liquid) claim = liquid;
        return claim < withdrawCap ? claim : withdrawCap;
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 shares = super.previewDeposit(assets);
        return entryFeeReported && shares != 0 ? shares - 1 : shares;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (previewRedeemReverts) revert("preview redeem unavailable");
        uint256 assets = super.previewRedeem(shares);
        return exitFeeReported && assets != 0 ? assets - 1 : assets;
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 shares = super.previewWithdraw(assets);
        return withdrawFeeReported && shares != 0 ? shares + 1 : shares;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (!underMintDeposit) return super.deposit(assets, receiver);

        uint256 previewedShares = previewDeposit(assets);
        require(previewedShares > 1, "insufficient shares");
        shares = previewedShares - 1;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (!underpayWithdraw) {
            super._withdraw(caller, receiver, owner, assets, shares);
            return;
        }
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets - 1);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}

/// @dev Exact local representation of the two canonical DualPool initialization vault checks
///      pinned at Uniswap/v4-hooks-public commit ffd7f8a8d1f5df5deb6f41c8d2ba99d118244ed6.
contract CanonicalDualPoolVaultValidationHarness {
    error VaultAssetMismatch();
    error VaultChargesEntryFee();
    error VaultChargesExitFee();

    function validate(IERC4626 vault, address currency) external view {
        if (vault.asset() != currency) revert VaultAssetMismatch();
        uint256 probe = 10 ** uint256(vault.decimals());
        if (vault.previewDeposit(probe) != vault.convertToShares(probe)) {
            revert VaultChargesEntryFee();
        }
        try vault.previewRedeem(probe) returns (uint256 redeemable) {
            if (redeemable != vault.convertToAssets(probe)) revert VaultChargesExitFee();
        } catch {}
    }
}

contract FewToken4626AdapterTest is Test {
    uint256 internal constant UNIT = 1e6;

    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal receiver = makeAddr("receiver");

    AdapterMockToken internal origin;
    AdapterMockFewFactory internal factory;
    AdapterMockFewToken internal fewToken;
    AdapterMockOriginVault internal originVault;
    FewToken4626Adapter internal adapter;
    CanonicalDualPoolVaultValidationHarness internal canonicalHarness;

    function setUp() public {
        origin = new AdapterMockToken("Origin", "ORG", 6);
        factory = new AdapterMockFewFactory();
        fewToken = new AdapterMockFewToken(address(origin), address(factory), 6);
        factory.setWrappedToken(address(origin), address(fewToken));
        originVault = new AdapterMockOriginVault(IERC20(address(origin)));
        adapter = _newAdapter(factory, fewToken, origin, originVault);
        canonicalHarness = new CanonicalDualPoolVaultValidationHarness();
    }

    function test_configuration_isCanonicalAndImmutable() public view {
        assertEq(adapter.asset(), address(fewToken));
        assertEq(address(adapter.fewFactory()), address(factory));
        assertEq(address(adapter.fewToken()), address(fewToken));
        assertEq(address(adapter.originToken()), address(origin));
        assertEq(address(adapter.originVault()), address(originVault));
        assertEq(adapter.decimals(), 12);
    }

    function test_constructor_rejectsCounterfeitWrapper() public {
        AdapterMockFewToken counterfeit =
            new AdapterMockFewToken(address(origin), address(factory), 6);
        vm.expectRevert(FewToken4626Adapter.InvalidConfiguration.selector);
        _newAdapter(factory, counterfeit, origin, originVault);
    }

    function test_constructor_rejectsWrapperOriginDecimalsMismatch() public {
        AdapterMockFewToken wrongDecimals =
            new AdapterMockFewToken(address(origin), address(factory), 18);
        factory.setWrappedToken(address(origin), address(wrongDecimals));
        vm.expectRevert(FewToken4626Adapter.InvalidConfiguration.selector);
        _newAdapter(factory, wrongDecimals, origin, originVault);
    }

    function test_constructor_rejectsDecimalsThatBreakCanonicalProbe() public {
        AdapterMockToken highDecimalsOrigin = new AdapterMockToken("High", "HIGH", 72);
        AdapterMockFewToken highDecimalsFew =
            new AdapterMockFewToken(address(highDecimalsOrigin), address(factory), 72);
        AdapterMockOriginVault highDecimalsVault =
            new AdapterMockOriginVault(IERC20(address(highDecimalsOrigin)));
        factory.setWrappedToken(address(highDecimalsOrigin), address(highDecimalsFew));

        vm.expectRevert(FewToken4626Adapter.InvalidConfiguration.selector);
        _newAdapter(factory, highDecimalsFew, highDecimalsOrigin, highDecimalsVault);
    }

    function test_constructor_rejectsOriginVaultAssetMismatch() public {
        AdapterMockToken wrongAsset = new AdapterMockToken("Wrong", "WRONG", 6);
        AdapterMockOriginVault wrongVault = new AdapterMockOriginVault(IERC20(address(wrongAsset)));
        vm.expectRevert(FewToken4626Adapter.InvalidConfiguration.selector);
        _newAdapter(factory, fewToken, origin, wrongVault);
    }

    function test_constructor_rejectsReportedEntryFee() public {
        originVault.setEntryFeeReported(true);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        _newAdapter(factory, fewToken, origin, originVault);
    }

    function test_constructor_rejectsReportedExitFee() public {
        originVault.setExitFeeReported(true);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        _newAdapter(factory, fewToken, origin, originVault);
    }

    function test_constructor_rejectsReportedWithdrawOnlyFee() public {
        originVault.setWithdrawFeeReported(true);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        _newAdapter(factory, fewToken, origin, originVault);
    }

    function test_constructor_failsClosedWhenExitPreviewUnavailable() public {
        originVault.setPreviewRedeemReverts(true);
        vm.expectRevert();
        _newAdapter(factory, fewToken, origin, originVault);
    }

    function test_canonicalDualPoolValidation_acceptsAdapterAndRejectsOriginVault() public {
        canonicalHarness.validate(IERC4626(address(adapter)), address(fewToken));

        vm.expectRevert(CanonicalDualPoolVaultValidationHarness.VaultAssetMismatch.selector);
        canonicalHarness.validate(IERC4626(address(originVault)), address(fewToken));
    }

    function test_previewFunctionsMeetCanonicalFeelessChecks() public {
        _deposit(user, 10 * UNIT);
        uint256 probe = 10 ** uint256(adapter.decimals());
        assertEq(adapter.previewDeposit(probe), adapter.convertToShares(probe));
        assertEq(adapter.previewRedeem(probe), adapter.convertToAssets(probe));
    }

    function test_depositAndSynchronousRedeem_roundTripOneToOne() public {
        uint256 assets = 100 * UNIT;
        _mintWrapped(user, assets);

        vm.startPrank(user);
        fewToken.approve(address(adapter), assets);
        uint256 shares = adapter.deposit(assets, user);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(adapter.totalAssets(), assets);
        assertEq(fewToken.balanceOf(address(adapter)), 0);
        assertEq(origin.balanceOf(address(adapter)), 0);
        assertEq(origin.balanceOf(address(originVault)), assets);
        assertEq(origin.allowance(address(adapter), address(originVault)), 0);

        vm.prank(user);
        uint256 redeemed = adapter.redeem(shares, receiver, user);

        assertEq(redeemed, assets);
        assertEq(fewToken.balanceOf(receiver), assets);
        assertEq(adapter.balanceOf(user), 0);
        assertEq(adapter.totalAssets(), 0);
        assertEq(origin.allowance(address(adapter), address(fewToken)), 0);
    }

    function test_yieldAccruesToAdapterShareholders() public {
        uint256 assets = 100 * UNIT;
        _deposit(user, assets);
        originVault.addYield(10 * UNIT);

        assertApproxEqAbs(adapter.totalAssets(), 110 * UNIT, 1);
        assertApproxEqAbs(adapter.maxWithdraw(user), 110 * UNIT, 2);
    }

    function test_shareInflationDonationDoesNotStealVictimDeposit() public {
        uint256 donation = 100 * UNIT;
        _mintWrapped(attacker, donation + 1);
        _mintWrapped(user, 100 * UNIT);

        vm.startPrank(attacker);
        fewToken.approve(address(adapter), 1);
        uint256 attackerShares = adapter.deposit(1, attacker);
        assertTrue(fewToken.transfer(address(adapter), donation));
        vm.stopPrank();

        vm.startPrank(user);
        fewToken.approve(address(adapter), 100 * UNIT);
        uint256 userShares = adapter.deposit(100 * UNIT, user);
        vm.stopPrank();

        assertGt(userShares, 0);
        assertLt(adapter.previewRedeem(attackerShares), donation + 1);
        assertGt(adapter.previewRedeem(userShares), 99 * UNIT);
    }

    function test_maxDepositAndDepositPauseFailClosed() public {
        assertEq(adapter.maxMint(user), type(uint256).max);
        originVault.setDepositCap(25 * UNIT);
        assertEq(adapter.maxDeposit(user), 25 * UNIT);
        assertEq(adapter.maxMint(user), 25 * UNIT * 1e6);

        _mintWrapped(user, 26 * UNIT);
        vm.startPrank(user);
        fewToken.approve(address(adapter), 26 * UNIT);
        vm.expectRevert();
        adapter.deposit(26 * UNIT, user);
        vm.stopPrank();

        originVault.setDepositsPaused(true);
        assertEq(adapter.maxDeposit(user), 0);
    }

    function test_maxDepositViewFailureReturnsZero() public {
        originVault.setMaxDepositReverts(true);
        assertEq(adapter.maxDeposit(user), 0);
        assertEq(adapter.maxMint(user), 0);
    }

    function test_runtimeEntryFeeViewsAndDepositFailClosedThenRecover() public {
        _deposit(user, 100 * UNIT);
        uint256 assets = 10 * UNIT;
        _mintWrapped(attacker, assets);
        originVault.setEntryFeeReported(true);

        assertEq(adapter.maxDeposit(attacker), 0);
        assertEq(adapter.maxMint(attacker), 0);
        assertEq(adapter.previewDeposit(assets), 0);
        uint256 shareProbe = 10 ** uint256(adapter.decimals());
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.previewMint(shareProbe);

        uint256 totalAssetsBefore = adapter.totalAssets();
        uint256 vaultSharesBefore = originVault.balanceOf(address(adapter));
        uint256 attackerWrappedBefore = fewToken.balanceOf(attacker);
        vm.startPrank(attacker);
        fewToken.approve(address(adapter), assets);
        vm.expectRevert();
        adapter.deposit(assets, attacker);
        vm.stopPrank();

        assertEq(adapter.balanceOf(attacker), 0);
        assertEq(adapter.totalAssets(), totalAssetsBefore);
        assertEq(originVault.balanceOf(address(adapter)), vaultSharesBefore);
        assertEq(fewToken.balanceOf(attacker), attackerWrappedBefore);
        assertEq(fewToken.balanceOf(address(adapter)), 0);
        assertEq(origin.balanceOf(address(adapter)), 0);
        assertEq(origin.allowance(address(adapter), address(originVault)), 0);

        originVault.setEntryFeeReported(false);
        assertGt(adapter.maxDeposit(attacker), 0);
        assertGt(adapter.maxMint(attacker), 0);
        assertGt(adapter.previewDeposit(assets), 0);
        assertGt(adapter.previewMint(10 ** uint256(adapter.decimals())), 0);

        vm.prank(attacker);
        uint256 shares = adapter.deposit(assets, attacker);
        assertGt(shares, 0);
        assertEq(fewToken.balanceOf(attacker), 0);
    }

    function test_firstDepositRejectsZeroSynchronousExitAtomically() public {
        uint256 assets = 100 * UNIT;
        originVault.setWithdrawCap(0);
        _mintWrapped(user, assets);

        vm.startPrank(user);
        fewToken.approve(address(adapter), assets);
        vm.expectRevert(FewToken4626Adapter.SynchronousLiquidityUnavailable.selector);
        adapter.deposit(assets, user);
        vm.stopPrank();

        assertEq(adapter.balanceOf(user), 0);
        assertEq(adapter.totalSupply(), 0);
        assertEq(adapter.totalAssets(), 0);
        assertEq(originVault.balanceOf(address(adapter)), 0);
        assertEq(fewToken.balanceOf(user), assets);
        assertEq(fewToken.balanceOf(address(adapter)), 0);
        assertEq(origin.balanceOf(address(adapter)), 0);
        assertEq(origin.allowance(address(adapter), address(originVault)), 0);
    }

    function test_withdrawCapAndIlliquidityLimitSynchronousExit() public {
        _deposit(user, 100 * UNIT);
        originVault.setWithdrawCap(20 * UNIT);
        assertEq(adapter.maxWithdraw(user), 20 * UNIT);

        vm.prank(user);
        adapter.withdraw(20 * UNIT, receiver, user);
        assertEq(fewToken.balanceOf(receiver), 20 * UNIT);

        originVault.setWithdrawalsPaused(true);
        uint256 sharesBefore = adapter.balanceOf(user);
        vm.expectRevert(FewToken4626Adapter.SynchronousLiquidityUnavailable.selector);
        adapter.maxWithdraw(user);
        vm.expectRevert(FewToken4626Adapter.SynchronousLiquidityUnavailable.selector);
        adapter.maxRedeem(user);
        vm.expectRevert(FewToken4626Adapter.SynchronousLiquidityUnavailable.selector);
        adapter.previewRedeem(sharesBefore);
        vm.prank(user);
        vm.expectRevert();
        adapter.redeem(sharesBefore, receiver, user);
        assertEq(adapter.balanceOf(user), sharesBefore);
    }

    function test_partialDirectBuffersReportAndDeliverOnlyRealizableAmount() public {
        _deposit(user, 100 * UNIT);
        originVault.setWithdrawCap(0);
        origin.mint(address(adapter), 5 * UNIT);
        _mintWrapped(address(adapter), 7 * UNIT);

        assertEq(adapter.maxWithdraw(user), 12 * UNIT);
        uint256 redeemable = adapter.maxRedeem(user);
        assertGt(redeemable, 0);
        assertLe(adapter.previewRedeem(redeemable), 12 * UNIT);

        vm.prank(user);
        adapter.withdraw(12 * UNIT, receiver, user);
        assertEq(fewToken.balanceOf(receiver), 12 * UNIT);
        assertEq(fewToken.balanceOf(address(adapter)), 0);
        assertEq(origin.balanceOf(address(adapter)), 0);

        vm.expectRevert(FewToken4626Adapter.SynchronousLiquidityUnavailable.selector);
        adapter.maxWithdraw(user);
        vm.expectRevert(FewToken4626Adapter.SynchronousLiquidityUnavailable.selector);
        adapter.maxRedeem(user);
    }

    function test_maxWithdrawViewFailureFailsClosed() public {
        _deposit(user, 100 * UNIT);
        originVault.setMaxWithdrawReverts(true);
        vm.expectRevert(FewToken4626Adapter.OriginVaultViewUnavailable.selector);
        adapter.maxWithdraw(user);
        vm.expectRevert(FewToken4626Adapter.OriginVaultViewUnavailable.selector);
        adapter.maxRedeem(user);
        uint256 userShares = adapter.balanceOf(user);
        vm.expectRevert(FewToken4626Adapter.OriginVaultViewUnavailable.selector);
        adapter.previewRedeem(userShares);
        vm.expectRevert(FewToken4626Adapter.OriginVaultViewUnavailable.selector);
        adapter.previewWithdraw(UNIT);
    }

    function test_underpayingOriginVaultRevertsAtomically() public {
        _deposit(user, 100 * UNIT);
        originVault.setUnderpayWithdraw(true);
        uint256 sharesBefore = adapter.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(FewToken4626Adapter.AssetMovementMismatch.selector);
        adapter.withdraw(10 * UNIT, receiver, user);

        assertEq(adapter.balanceOf(user), sharesBefore);
        assertEq(fewToken.balanceOf(receiver), 0);
    }

    function test_originVaultCannotIntroduceWithdrawOnlyFeeAfterDeposit() public {
        _deposit(user, 100 * UNIT);
        originVault.setWithdrawFeeReported(true);
        uint256 sharesBefore = adapter.balanceOf(user);

        assertEq(adapter.maxDeposit(user), 0);
        assertEq(adapter.maxMint(user), 0);
        assertEq(adapter.previewDeposit(UNIT), 0);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.maxWithdraw(user);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.maxRedeem(user);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.previewRedeem(sharesBefore);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.previewWithdraw(10 * UNIT);

        vm.prank(user);
        vm.expectRevert();
        adapter.withdraw(10 * UNIT, receiver, user);

        assertEq(adapter.balanceOf(user), sharesBefore);
        assertEq(fewToken.balanceOf(receiver), 0);
        assertEq(adapter.totalAssets(), 100 * UNIT);
        assertEq(origin.allowance(address(adapter), address(originVault)), 0);

        originVault.setWithdrawFeeReported(false);
        assertGt(adapter.maxWithdraw(user), 0);
        assertGt(adapter.maxRedeem(user), 0);
        assertGt(adapter.previewRedeem(sharesBefore), 0);
        assertGt(adapter.previewWithdraw(10 * UNIT), 0);
        vm.prank(user);
        adapter.withdraw(10 * UNIT, receiver, user);
        assertEq(fewToken.balanceOf(receiver), 10 * UNIT);
    }

    function test_feeOnTransferFewTokenCannotMintUnbackedAdapterShares() public {
        uint256 assets = 100 * UNIT;
        _mintWrapped(user, assets);
        fewToken.setFeeOnTransfer(true);

        vm.startPrank(user);
        fewToken.approve(address(adapter), assets);
        vm.expectRevert(FewToken4626Adapter.AssetMovementMismatch.selector);
        adapter.deposit(assets, user);
        vm.stopPrank();

        assertEq(adapter.balanceOf(user), 0);
        assertEq(fewToken.balanceOf(user), assets);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_underMintingOriginVaultDepositRevertsAtomically() public {
        uint256 assets = 100 * UNIT;
        _mintWrapped(user, assets);
        originVault.setUnderMintDeposit(true);

        vm.startPrank(user);
        fewToken.approve(address(adapter), assets);
        vm.expectRevert(FewToken4626Adapter.AssetMovementMismatch.selector);
        adapter.deposit(assets, user);
        vm.stopPrank();

        assertEq(adapter.balanceOf(user), 0);
        assertEq(fewToken.balanceOf(user), assets);
        assertEq(origin.balanceOf(address(originVault)), 0);
        assertEq(origin.allowance(address(adapter), address(originVault)), 0);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_underMintingFewTokenCannotHideWhenReceiverIsAdapter() public {
        uint256 shares = _deposit(user, 100 * UNIT);
        fewToken.setUnderMintWrap(true);

        vm.prank(user);
        vm.expectRevert(FewToken4626Adapter.AssetMovementMismatch.selector);
        adapter.redeem(shares, address(adapter), user);

        assertEq(adapter.balanceOf(user), shares);
        assertEq(adapter.totalAssets(), 100 * UNIT);
        assertEq(origin.allowance(address(adapter), address(fewToken)), 0);
    }

    function test_originVaultCannotIntroduceExitFeeAfterDeposit() public {
        _deposit(user, 100 * UNIT);
        originVault.setExitFeeReported(true);
        uint256 sharesBefore = adapter.balanceOf(user);

        assertEq(adapter.maxDeposit(user), 0);
        assertEq(adapter.maxMint(user), 0);
        assertEq(adapter.previewDeposit(UNIT), 0);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.maxWithdraw(user);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.maxRedeem(user);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.previewRedeem(sharesBefore);
        vm.expectRevert(FewToken4626Adapter.OriginVaultFeeDetected.selector);
        adapter.previewWithdraw(10 * UNIT);

        vm.prank(user);
        vm.expectRevert();
        adapter.withdraw(10 * UNIT, receiver, user);

        assertEq(adapter.balanceOf(user), sharesBefore);
        assertEq(fewToken.balanceOf(receiver), 0);
        assertEq(adapter.totalAssets(), 100 * UNIT);

        originVault.setExitFeeReported(false);
        assertGt(adapter.maxWithdraw(user), 0);
        assertGt(adapter.maxRedeem(user), 0);
        assertGt(adapter.previewRedeem(sharesBefore), 0);
        assertGt(adapter.previewWithdraw(10 * UNIT), 0);
        vm.prank(user);
        adapter.withdraw(10 * UNIT, receiver, user);
        assertEq(fewToken.balanceOf(receiver), 10 * UNIT);
    }

    function test_conversionPauseCannotLosePrincipalOrShares() public {
        _mintWrapped(user, 100 * UNIT);
        fewToken.setConversionPaused(true);

        vm.startPrank(user);
        fewToken.approve(address(adapter), 100 * UNIT);
        vm.expectRevert("conversion paused");
        adapter.deposit(100 * UNIT, user);
        vm.stopPrank();
        assertEq(fewToken.balanceOf(user), 100 * UNIT);
        assertEq(adapter.balanceOf(user), 0);

        fewToken.setConversionPaused(false);
        _deposit(user, 100 * UNIT);
        fewToken.setConversionPaused(true);
        uint256 sharesBefore = adapter.balanceOf(user);
        vm.prank(user);
        vm.expectRevert("conversion paused");
        adapter.redeem(sharesBefore, receiver, user);
        assertEq(adapter.balanceOf(user), sharesBefore);
        assertEq(fewToken.balanceOf(receiver), 0);
    }

    function test_factoryPauseDoesNotInventRestrictionOnPermissionlessConversions() public {
        factory.setPaused(true);
        uint256 shares = _deposit(user, 100 * UNIT);
        vm.prank(user);
        adapter.redeem(shares, receiver, user);
        assertEq(fewToken.balanceOf(receiver), 100 * UNIT);
    }

    function test_thirdPartyCannotWithdrawPrincipalWithoutShareAllowance() public {
        _deposit(user, 100 * UNIT);
        vm.prank(attacker);
        vm.expectRevert();
        adapter.withdraw(1 * UNIT, attacker, user);
        assertEq(fewToken.balanceOf(attacker), 0);
        assertGt(adapter.balanceOf(user), 0);
    }

    function test_noAdminRescueOrOwnershipSurface() public {
        _deposit(user, 100 * UNIT);

        vm.startPrank(attacker);
        (bool ownerOk,) = address(adapter).staticcall(abi.encodeWithSignature("owner()"));
        (bool rescueOk,) = address(adapter)
            .call(
                abi.encodeWithSignature(
                    "rescue(address,address,uint256)", address(fewToken), attacker, 100 * UNIT
                )
            );
        (bool sweepOk,) = address(adapter)
            .call(abi.encodeWithSignature("sweep(address,address)", address(fewToken), attacker));
        (bool transferOwnershipOk,) =
            address(adapter).call(abi.encodeWithSignature("transferOwnership(address)", attacker));
        vm.stopPrank();

        assertFalse(ownerOk);
        assertFalse(rescueOk);
        assertFalse(sweepOk);
        assertFalse(transferOwnershipOk);
        assertEq(fewToken.balanceOf(attacker), 0);
        assertEq(adapter.totalAssets(), 100 * UNIT);
    }

    function testFuzz_roundTripPreservesRawUnits(uint96 rawAmount) public {
        uint256 assets = bound(uint256(rawAmount), 1, 1_000_000_000 * UNIT);
        uint256 shares = _deposit(user, assets);
        vm.prank(user);
        uint256 redeemed = adapter.redeem(shares, receiver, user);
        assertEq(redeemed, assets);
        assertEq(fewToken.balanceOf(receiver), assets);
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        _mintWrapped(account, assets);
        vm.startPrank(account);
        fewToken.approve(address(adapter), assets);
        shares = adapter.deposit(assets, account);
        vm.stopPrank();
    }

    function _mintWrapped(address account, uint256 assets) internal {
        origin.mint(account, assets);
        vm.startPrank(account);
        origin.approve(address(fewToken), assets);
        fewToken.wrapTo(assets, account);
        vm.stopPrank();
    }

    function _newAdapter(
        AdapterMockFewFactory factory_,
        AdapterMockFewToken fewToken_,
        AdapterMockToken origin_,
        AdapterMockOriginVault vault_
    ) internal returns (FewToken4626Adapter created) {
        created = new FewToken4626Adapter(
            IFewFactory(address(factory_)),
            IFewWrappedToken(address(fewToken_)),
            IERC20(address(origin_)),
            IERC4626(address(vault_)),
            "DualPool FewToken Adapter",
            "dpFW"
        );
    }
}

contract FewToken4626AdapterInvariantHandler is Test {
    uint256 internal constant UNIT = 1e6;

    AdapterMockToken public immutable origin;
    AdapterMockFewToken public immutable fewToken;
    AdapterMockOriginVault public immutable originVault;
    FewToken4626Adapter public immutable adapter;

    address[3] internal actors;

    constructor(
        AdapterMockToken origin_,
        AdapterMockFewToken fewToken_,
        AdapterMockOriginVault originVault_,
        FewToken4626Adapter adapter_
    ) {
        origin = origin_;
        fewToken = fewToken_;
        originVault = originVault_;
        adapter = adapter_;
        actors[0] = makeAddr("invariant-alice");
        actors[1] = makeAddr("invariant-bob");
        actors[2] = makeAddr("invariant-carol");
    }

    function deposit(uint256 actorSeed, uint96 rawAssets) external {
        address actor = actors[actorSeed % actors.length];
        uint256 assets = uint256(rawAssets) % (1_000_000 * UNIT) + 1;
        uint256 capacity = adapter.maxDeposit(actor);
        if (capacity == 0 || assets > capacity || adapter.previewDeposit(assets) == 0) return;
        origin.mint(actor, assets);
        vm.startPrank(actor);
        origin.approve(address(fewToken), assets);
        fewToken.wrapTo(assets, actor);
        fewToken.approve(address(adapter), assets);
        adapter.deposit(assets, actor);
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint96 rawShares) external {
        address actor = actors[actorSeed % actors.length];
        uint256 redeemable = adapter.maxRedeem(actor);
        if (redeemable == 0) return;
        uint256 shares = uint256(rawShares) % redeemable + 1;
        if (adapter.previewRedeem(shares) == 0) return;
        vm.prank(actor);
        adapter.redeem(shares, actor, actor);
    }

    function addYield(uint96 rawAssets) external {
        if (originVault.totalSupply() == 0) return;
        uint256 assets = uint256(rawAssets) % (100_000 * UNIT) + 1;
        originVault.addYield(assets);
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }
}

contract FewToken4626AdapterInvariantTest is StdInvariant, Test {
    AdapterMockToken internal origin;
    AdapterMockFewFactory internal factory;
    AdapterMockFewToken internal fewToken;
    AdapterMockOriginVault internal originVault;
    FewToken4626Adapter internal adapter;
    FewToken4626AdapterInvariantHandler internal handler;

    function setUp() public {
        origin = new AdapterMockToken("Origin", "ORG", 6);
        factory = new AdapterMockFewFactory();
        fewToken = new AdapterMockFewToken(address(origin), address(factory), 6);
        factory.setWrappedToken(address(origin), address(fewToken));
        originVault = new AdapterMockOriginVault(IERC20(address(origin)));
        adapter = new FewToken4626Adapter(
            IFewFactory(address(factory)),
            IFewWrappedToken(address(fewToken)),
            IERC20(address(origin)),
            IERC4626(address(originVault)),
            "DualPool FewToken Adapter",
            "dpFW"
        );
        handler = new FewToken4626AdapterInvariantHandler(origin, fewToken, originVault, adapter);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = FewToken4626AdapterInvariantHandler.deposit.selector;
        selectors[1] = FewToken4626AdapterInvariantHandler.redeem.selector;
        selectors[2] = FewToken4626AdapterInvariantHandler.addYield.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_externalAllowancesReturnToZero() public view {
        assertEq(origin.allowance(address(adapter), address(originVault)), 0);
        assertEq(origin.allowance(address(adapter), address(fewToken)), 0);
    }

    function invariant_mockFewTokenRemainsFullyBacked() public view {
        assertEq(origin.balanceOf(address(fewToken)), fewToken.totalSupply());
    }

    function invariant_shareClaimsNeverExceedAccountedAssets() public view {
        uint256 supply = adapter.totalSupply();
        assertLe(adapter.convertToAssets(supply), adapter.totalAssets());
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actorAt(i);
            assertLe(adapter.maxRedeem(actor), adapter.balanceOf(actor));
            assertLe(adapter.maxWithdraw(actor), adapter.convertToAssets(adapter.balanceOf(actor)));
        }
    }
}
