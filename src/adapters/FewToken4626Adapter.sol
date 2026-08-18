// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFewFactory, IFewWrappedToken} from "../interfaces/IFew.sol";

/// @title FewToken4626Adapter
/// @notice Presents a canonical FewToken as the ERC-4626 asset while synchronously investing its
///         origin token in one immutable origin-token ERC-4626 vault.
/// @dev The adapter has no admin, rescue, upgrade, or arbitrary-transfer path. Losses and yield
///      from `originVault` flow through `totalAssets` to adapter shareholders.
contract FewToken4626Adapter is ERC4626, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error AssetMovementMismatch();
    error OriginVaultFeeDetected();
    error OriginVaultViewUnavailable();
    error SynchronousLiquidityUnavailable();
    error ZeroAmount();

    enum RuntimeViewState {
        Compatible,
        Unavailable,
        Inconsistent
    }

    uint8 internal constant _DECIMALS_OFFSET = 6;

    IFewFactory public immutable fewFactory;
    IFewWrappedToken public immutable fewToken;
    IERC20 public immutable originToken;
    IERC4626 public immutable originVault;

    constructor(
        IFewFactory fewFactory_,
        IFewWrappedToken fewToken_,
        IERC20 originToken_,
        IERC4626 originVault_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(IERC20(address(fewToken_))) {
        uint8 tokenDecimals = IERC20Metadata(address(fewToken_)).decimals();
        if (
            address(fewFactory_).code.length == 0 || address(fewToken_).code.length == 0
                || address(originToken_).code.length == 0 || address(originVault_).code.length == 0
                || fewToken_.token() != address(originToken_)
                || fewFactory_.getWrappedToken(address(originToken_)) != address(fewToken_)
                || originVault_.asset() != address(originToken_)
                || tokenDecimals != IERC20Metadata(address(originToken_)).decimals()
                || tokenDecimals > 71
        ) revert InvalidConfiguration();

        uint8 vaultDecimals = originVault_.decimals();
        if (vaultDecimals > 71) revert InvalidConfiguration();
        uint256 assetProbe = 10 ** uint256(tokenDecimals);
        _requireNoEntryFee(originVault_, assetProbe);
        _previewFeeFreeWithdraw(originVault_, assetProbe);
        _requireNoExitFee(originVault_, 10 ** uint256(vaultDecimals));

        fewFactory = fewFactory_;
        fewToken = fewToken_;
        originToken = originToken_;
        originVault = originVault_;
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        uint256 vaultShares = originVault.balanceOf(address(this));
        return IERC20(address(fewToken)).balanceOf(address(this))
            + originToken.balanceOf(address(this)) + originVault.convertToAssets(vaultShares);
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        uint256 probe = _assetProbe();
        if (_runtimeDepositViewState(probe) != RuntimeViewState.Compatible) return 0;

        try originVault.maxDeposit(address(this)) returns (uint256 assets) {
            if (
                assets != 0 && assets != type(uint256).max
                    && _entryViewState(assets) != RuntimeViewState.Compatible
            ) return 0;
            return assets;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc ERC4626
    function maxMint(address) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(address(this));
        return maxAssets == type(uint256).max
            ? type(uint256).max
            : _convertToShares(maxAssets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626
    /// @dev A zero quote is the only safe preview when the origin vault's runtime entry or exit
    ///      views no longer match its fee-free conversion math. `maxDeposit`/`maxMint` return the
    ///      same fail-closed signal and the state-changing path reverts before moving FewToken.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (_runtimeDepositViewState(assets) != RuntimeViewState.Compatible) return 0;
        return super.previewDeposit(assets);
    }

    /// @inheritdoc ERC4626
    function previewMint(uint256 shares) public view override returns (uint256 assets) {
        assets = super.previewMint(shares);
        _requireCompatible(_runtimeDepositViewState(assets));
    }

    /// @inheritdoc ERC4626
    /// @dev Runtime vault incompatibility deliberately reverts instead of returning zero. The
    ///      canonical DualPool first reads `maxWithdraw` and, on a revert, retries
    ///      `previewRedeem`; both calls then fail with the same explicit incident signal. This
    ///      makes `beforeSwap` revert before v4 core can advance its price through a pool with no
    ///      deployed JIT liquidity. Genuine zero capacity remains a non-reverting zero.
    function maxWithdraw(address owner) public view override returns (uint256) {
        (RuntimeViewState state, uint256 vaultCapacity) = _exitViewStateAndCapacity();
        _requireCompatible(state);

        // Compute the claim directly instead of delegating to `super.maxWithdraw`.
        // OpenZeppelin 5.x implements that method through `previewRedeem(maxRedeem(owner))`;
        // delegating would recurse through this adapter's liquidity-capped `maxRedeem`.
        uint256 claim = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 available = IERC20(address(fewToken)).balanceOf(address(this))
            + originToken.balanceOf(address(this)) + vaultCapacity;
        // Returning zero here is unsafe for canonical DualPool. Its vault inventory helper
        // interprets a zero maxWithdraw as an ambiguous ERC-4626 sentinel, catches a reverting
        // previewRedeem, and proceeds with zero JIT liquidity. A forced v4 swap can then advance
        // the empty core pool to its price limit without a fill. Bubble an explicit incident
        // whenever this owner still has an economic claim but none of it is synchronously
        // realizable. A non-zero partial capacity remains reportable and is clamped below.
        if (claim != 0 && available == 0) revert SynchronousLiquidityUnavailable();
        return claim < available ? claim : available;
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        if (ownerShares == 0) return 0;

        uint256 available = maxWithdraw(owner);
        if (_convertToAssets(ownerShares, Math.Rounding.Floor) <= available) return ownerShares;

        uint256 liquidShares = _convertToShares(available, Math.Rounding.Floor);
        return liquidShares < ownerShares ? liquidShares : ownerShares;
    }

    /// @inheritdoc ERC4626
    /// @dev Reverts when the origin vault's runtime exit views are inconsistent or it cannot
    ///      synchronously satisfy the economic claim.
    ///      Canonical DualPool explicitly treats a reverting exit preview as zero effective
    ///      liquidity. This avoids advertising an executable quote against paused/illiquid
    ///      origin capital.
    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        (RuntimeViewState state, uint256 vaultCapacity) = _exitViewStateAndCapacity();
        _requireCompatible(state);
        assets = super.previewRedeem(shares);
        uint256 available = IERC20(address(fewToken)).balanceOf(address(this))
            + originToken.balanceOf(address(this)) + vaultCapacity;
        if (assets > available) revert SynchronousLiquidityUnavailable();
    }

    /// @inheritdoc ERC4626
    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        (RuntimeViewState state, uint256 vaultCapacity) = _exitViewStateAndCapacity();
        _requireCompatible(state);
        uint256 available = IERC20(address(fewToken)).balanceOf(address(this))
            + originToken.balanceOf(address(this)) + vaultCapacity;
        if (assets > available) revert SynchronousLiquidityUnavailable();
        shares = super.previewWithdraw(assets);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (assets == 0 || shares == 0) revert ZeroAmount();
        _requireCompatible(_runtimeDepositViewState(assets));
        uint256 expectedVaultShares = originVault.previewDeposit(assets);

        IERC20 wrapped = IERC20(address(fewToken));
        uint256 wrappedBefore = wrapped.balanceOf(address(this));
        wrapped.safeTransferFrom(caller, address(this), assets);
        if (wrapped.balanceOf(address(this)) != wrappedBefore + assets) {
            revert AssetMovementMismatch();
        }

        uint256 originBefore = originToken.balanceOf(address(this));
        if (fewToken.unwrapTo(assets, address(this)) != assets) revert AssetMovementMismatch();
        if (
            wrapped.balanceOf(address(this)) != wrappedBefore
                || originToken.balanceOf(address(this)) != originBefore + assets
        ) revert AssetMovementMismatch();

        uint256 vaultSharesBefore = originVault.balanceOf(address(this));
        originToken.forceApprove(address(originVault), assets);
        uint256 vaultShares = originVault.deposit(assets, address(this));
        originToken.forceApprove(address(originVault), 0);
        if (
            vaultShares == 0 || vaultShares != expectedVaultShares
                || originVault.balanceOf(address(this)) != vaultSharesBefore + vaultShares
                || originToken.balanceOf(address(this)) != originBefore
        ) revert AssetMovementMismatch();

        // A view-only preflight cannot prove that a vault with no shares will let this adapter
        // withdraw a hypothetical deposit: ERC-4626 correctly reports maxWithdraw(this) == 0
        // before the adapter owns shares. Check again after the deposit, while the whole call is
        // still atomic, and reject a vault that immediately deploys or gates the new principal.
        // This keeps DualPool from accepting adapter shares that cannot fund any liquidity in the
        // next JIT cycle. A smaller non-zero capacity is valid: canonical DualPool reads and caps
        // against `maxWithdraw`, and ERC-4626 rounding can make it slightly lower than `assets`.
        (RuntimeViewState exitState, uint256 vaultCapacity) = _exitViewStateAndCapacity();
        _requireCompatible(exitState);
        if (vaultCapacity == 0) revert SynchronousLiquidityUnavailable();

        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        if (assets == 0 || shares == 0) revert ZeroAmount();
        (RuntimeViewState state,) = _exitViewStateAndCapacity();
        _requireCompatible(state);
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);

        IERC20 wrapped = IERC20(address(fewToken));
        uint256 receiverWrappedBefore = wrapped.balanceOf(receiver);
        uint256 wrappedAvailable = wrapped.balanceOf(address(this));
        uint256 wrappedToSend = assets < wrappedAvailable ? assets : wrappedAvailable;
        if (wrappedToSend != 0) wrapped.safeTransfer(receiver, wrappedToSend);

        uint256 originToWrap = assets - wrappedToSend;
        if (originToWrap != 0) {
            uint256 originAvailable = originToken.balanceOf(address(this));
            if (originAvailable < originToWrap) {
                uint256 shortfall = originToWrap - originAvailable;
                uint256 vaultSharesBefore = originVault.balanceOf(address(this));
                uint256 originBefore = originToken.balanceOf(address(this));
                uint256 expectedBurn = _previewFeeFreeWithdraw(originVault, shortfall);
                uint256 burned = originVault.withdraw(shortfall, address(this), address(this));
                if (
                    burned == 0 || burned != expectedBurn
                        || originVault.balanceOf(address(this)) + burned != vaultSharesBefore
                        || originToken.balanceOf(address(this)) != originBefore + shortfall
                ) revert AssetMovementMismatch();
            }

            uint256 originBeforeWrap = originToken.balanceOf(address(this));
            originToken.forceApprove(address(fewToken), originToWrap);
            uint256 wrappedAmount = fewToken.wrapTo(originToWrap, receiver);
            originToken.forceApprove(address(fewToken), 0);
            if (
                wrappedAmount != originToWrap
                    || originToken.balanceOf(address(this)) + originToWrap != originBeforeWrap
            ) revert AssetMovementMismatch();
        }

        uint256 expectedReceiverBalance = receiver == address(this)
            ? receiverWrappedBefore + originToWrap
            : receiverWrappedBefore + assets;
        if (wrapped.balanceOf(receiver) != expectedReceiverBalance) {
            revert AssetMovementMismatch();
        }

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _runtimeDepositViewState(uint256 assets) internal view returns (RuntimeViewState) {
        RuntimeViewState entryState = _entryViewState(assets == 0 ? _assetProbe() : assets);
        if (entryState != RuntimeViewState.Compatible) return entryState;
        (RuntimeViewState exitState,) = _exitViewStateAndCapacity();
        return exitState;
    }

    function _entryViewState(uint256 assets) internal view returns (RuntimeViewState) {
        try originVault.previewDeposit(assets) returns (uint256 previewShares) {
            try originVault.convertToShares(assets) returns (uint256 convertedShares) {
                if (previewShares == 0 || previewShares != convertedShares) {
                    return RuntimeViewState.Inconsistent;
                }
                return RuntimeViewState.Compatible;
            } catch {
                return RuntimeViewState.Unavailable;
            }
        } catch {
            return RuntimeViewState.Unavailable;
        }
    }

    function _exitViewStateAndCapacity()
        internal
        view
        returns (RuntimeViewState state, uint256 capacity)
    {
        uint256 shareProbe = 10 ** uint256(originVault.decimals());
        try originVault.previewRedeem(shareProbe) returns (uint256 previewAssets) {
            try originVault.convertToAssets(shareProbe) returns (uint256 convertedAssets) {
                if (previewAssets != convertedAssets) {
                    return (RuntimeViewState.Inconsistent, 0);
                }
            } catch {
                return (RuntimeViewState.Unavailable, 0);
            }
        } catch {
            return (RuntimeViewState.Unavailable, 0);
        }

        (state,) = _withdrawViewState(_assetProbe(), type(uint256).max);
        if (state != RuntimeViewState.Compatible) return (state, 0);

        uint256 vaultShares = originVault.balanceOf(address(this));
        if (vaultShares == 0) return (RuntimeViewState.Compatible, 0);

        uint256 grossAssets;
        try originVault.convertToAssets(vaultShares) returns (uint256 assets) {
            grossAssets = assets;
        } catch {
            return (RuntimeViewState.Unavailable, 0);
        }
        try originVault.previewRedeem(vaultShares) returns (uint256 previewAssets) {
            if (previewAssets != grossAssets) return (RuntimeViewState.Inconsistent, 0);
        } catch {
            return (RuntimeViewState.Unavailable, 0);
        }

        try originVault.maxWithdraw(address(this)) returns (uint256 cap) {
            capacity = cap < grossAssets ? cap : grossAssets;
        } catch {
            return (RuntimeViewState.Unavailable, 0);
        }
        if (capacity == 0) return (RuntimeViewState.Compatible, 0);

        uint256 sharesRequired;
        (state, sharesRequired) = _withdrawViewState(capacity, vaultShares);
        if (state != RuntimeViewState.Compatible) return (state, 0);
        if (sharesRequired > vaultShares) return (RuntimeViewState.Inconsistent, 0);
        return (RuntimeViewState.Compatible, capacity);
    }

    function _withdrawViewState(uint256 assets, uint256 maxShares)
        internal
        view
        returns (RuntimeViewState state, uint256 shares)
    {
        try originVault.previewWithdraw(assets) returns (uint256 previewShares) {
            shares = previewShares;
        } catch {
            return (RuntimeViewState.Unavailable, 0);
        }
        if (shares == 0 || shares > maxShares) return (RuntimeViewState.Inconsistent, 0);

        uint256 redeemAssets;
        try originVault.previewRedeem(shares) returns (uint256 previewAssets) {
            redeemAssets = previewAssets;
        } catch {
            return (RuntimeViewState.Unavailable, 0);
        }
        try originVault.convertToAssets(shares) returns (uint256 convertedAssets) {
            if (redeemAssets != convertedAssets || redeemAssets < assets) {
                return (RuntimeViewState.Inconsistent, 0);
            }
        } catch {
            return (RuntimeViewState.Unavailable, 0);
        }

        if (shares != 0) {
            try originVault.previewRedeem(shares - 1) returns (uint256 previousAssets) {
                if (previousAssets >= assets) return (RuntimeViewState.Inconsistent, 0);
            } catch {
                return (RuntimeViewState.Unavailable, 0);
            }
        }
        return (RuntimeViewState.Compatible, shares);
    }

    function _requireCompatible(RuntimeViewState state) internal pure {
        if (state == RuntimeViewState.Inconsistent) revert OriginVaultFeeDetected();
        if (state == RuntimeViewState.Unavailable) revert OriginVaultViewUnavailable();
    }

    function _assetProbe() internal view returns (uint256) {
        return 10 ** uint256(IERC20Metadata(address(fewToken)).decimals());
    }

    function _requireNoEntryFee(IERC4626 vault, uint256 assets) internal view {
        if (vault.previewDeposit(assets) != vault.convertToShares(assets)) {
            revert OriginVaultFeeDetected();
        }
    }

    function _requireNoExitFee(IERC4626 vault, uint256 shares) internal view {
        if (vault.previewRedeem(shares) != vault.convertToAssets(shares)) {
            revert OriginVaultFeeDetected();
        }
    }

    /// @dev `previewRedeem == convertToAssets` only rules out a redeem fee. An ERC-4626 vault
    ///      can still charge a withdraw-only fee by making `previewWithdraw` burn surplus shares.
    ///      A fee-free preview must be the smallest share count whose redeem preview covers the
    ///      requested assets. This also rejects non-monotonic or internally inconsistent previews.
    function _previewFeeFreeWithdraw(IERC4626 vault, uint256 assets)
        internal
        view
        returns (uint256 shares)
    {
        shares = vault.previewWithdraw(assets);
        _requireNoExitFee(vault, shares);
        if (
            vault.previewRedeem(shares) < assets
                || (shares != 0 && vault.previewRedeem(shares - 1) >= assets)
        ) revert OriginVaultFeeDetected();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return _DECIMALS_OFFSET;
    }
}
