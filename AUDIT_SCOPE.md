# Audit scope

## Ring Protocol code in scope

The only Ring Protocol production contract in scope is:

```text
src/adapters/FewToken4626Adapter.sol
```

`audit-scope.txt` is the machine-readable scope file. An audit report should bind its findings to the reviewed commit, Solidity compiler settings, OpenZeppelin commit, FewFactory and FewToken implementations, selected origin vault, and canonical DualPool commit.

`src/interfaces/IFew.sol`, tests, and scripts support the review but do not add deployed Ring Protocol bytecode beyond the adapter.

## External integration boundary

The review should validate the adapter's assumptions about:

- `Uniswap/v4-hooks-public` canonical DualPool at `ffd7f8a8d1f5df5deb6f41c8d2ba99d118244ed6`;
- Uniswap v4 PoolManager and the canonical AllowlistedFactory;
- OpenZeppelin ERC-4626 behavior at the pinned repository commit;
- the canonical Ring Protocol FewFactory and FewToken implementation;
- each immutable origin-token ERC-4626 vault selected for deployment.

The upstream DualPool audit does not cover the Ring Protocol adapter or the behavior of a selected origin vault.

## Required properties

1. `asset()` is the canonical FewToken, and `originVault.asset()` is its origin token.
2. The contract has no owner, upgrade, rescue, arbitrary call, or mutable vault path.
3. A deposit completes an exact 1:1 FewToken unwrap, deposits the expected origin assets, and receives exactly the previewed origin-vault shares.
4. A withdrawal synchronously returns the exact FewToken amount or reverts atomically.
5. Entry fees, exit fees, inconsistent views, underpayment, and unsupported token behavior fail closed.
6. The adapter never advertises more synchronous withdrawal capacity than it can realize.
7. No caller can redeem another account's shares without sufficient allowance.
8. Rounding, donation, virtual-share behavior, and share inflation cannot create free assets or principal loss.
9. Canonical DualPool vault validation and JIT execution remain safe when the origin vault is paused or illiquid.
10. Failed operations do not leave token allowances or partial asset movement behind.

## Out of scope

- modifications to canonical DualPool or Uniswap v4 core;
- deployment keys, Safe policy, routing inclusion, vault selection, or economic performance;
- unselected ERC-4626 vaults;
- offchain routing and order selection;
- third-party dependency code except where its behavior is an explicit adapter assumption.

Passing this scope does not approve a deployment. Every production vault and deployed bytecode instance needs separate identity, liquidity, governance, and operational review.
