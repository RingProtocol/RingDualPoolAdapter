# Ring Protocol DualPool Adapter

`FewToken4626Adapter` connects a Ring Protocol FewToken to an origin-token ERC-4626 vault without modifying Uniswap's canonical DualPool hook.

The adapter presents the FewToken as its ERC-4626 asset. Deposits unwrap FewToken into the origin token and place that token in one immutable vault. Withdrawals complete the reverse path synchronously. Canonical DualPool remains unchanged and is pinned in this repository as an official upstream submodule.

## Status

This code is unaudited and has not been deployed by Ring Protocol. It is not approved for production funds. Local tests and canonical integration tests are engineering evidence, not a security audit or a guarantee that a selected ERC-4626 vault will remain liquid.

## Design

```text
canonical Uniswap DualPool
            |
            v
FewToken4626Adapter
      |           |
      v           v
  FewToken  <->  origin token  <->  immutable ERC-4626 vault
```

Ring Protocol owns one production contract in this repository:

```text
src/adapters/FewToken4626Adapter.sol
```

The adapter has no owner, upgrade, rescue, arbitrary call, or vault-switching function. Its FewFactory, FewToken, origin token, and origin vault are immutable.

The constructor rejects mismatched wrappers, factories, assets, decimals, and vaults that report entry or exit fees. Runtime checks fail closed when the origin vault changes its fee behavior, stops serving required views, or lacks synchronous withdrawal capacity. Asset transfers are checked by balance movement, exact wrap or unwrap return values, and exact origin-vault share issuance against the pre-deposit preview.

The adapter intentionally supports a narrow vault set:

- the FewToken must wrap and unwrap 1:1 with its origin token;
- the origin vault must use the origin token as `asset()`;
- deposits and withdrawals must be fee free;
- the vault must expose consistent ERC-4626 preview and conversion methods;
- deposited capital must have nonzero synchronous exit capacity.

`maxWithdraw` and exit previews may revert during an incompatible or illiquid vault incident. This deliberate deviation from the usual non-reverting ERC-4626 view convention prevents canonical DualPool from treating an unavailable vault as usable zero-liquidity JIT inventory and advancing the v4 pool price without a fill.

## Canonical DualPool pin

The official source is pinned at [`Uniswap/v4-hooks-public@ffd7f8a8`](https://github.com/Uniswap/v4-hooks-public/tree/ffd7f8a8d1f5df5deb6f41c8d2ba99d118244ed6/src/alf).

The repository tracks that commit at `lib/v4-hooks-public`. `scripts/verify_canonical_dualpool_checkout.sh` verifies the commit, required nested dependency pins, remappings, and clean submodule state before the integration suite runs. Ring Protocol does not modify or vendor the canonical DualPool production bytecode.

## Build and test

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then run:

```bash
git clone https://github.com/RingProtocol/RingDualPoolAdapter.git
cd RingDualPoolAdapter

# Initialize the adapter dependencies and only the upstream dependencies used by
# the canonical integration test.
git submodule update --init \
  lib/forge-std lib/openzeppelin-contracts lib/v4-hooks-public
git -C lib/v4-hooks-public submodule update --init \
  lib/blocknumberish lib/forge-std lib/openzeppelin-contracts \
  lib/solady lib/v4-core lib/v4-periphery
git -C lib/v4-hooks-public/lib/v4-core submodule update --init lib/solmate

./scripts/check_public_release.sh
forge fmt --check
forge build --sizes --skip test
forge lint src/adapters/FewToken4626Adapter.sol --severity high med
forge test --offline --match-path test/FewToken4626Adapter.t.sol --threads 1
./scripts/test_canonical_dualpool_adapter.sh
```

The unit suite includes fuzz and invariant tests. The canonical integration suite builds a temporary harness from the pinned official source and covers initialization, bootstrap, swaps in both directions, redeposit, fee incidents, withdrawal-capacity incidents, and atomic rejection of a zero-capacity bootstrap.

No RPC URL, private key, deployment script, production address, or live-funds configuration is required by these tests.

## Repository scope

| Path | Purpose |
|---|---|
| `src/` | Ring Protocol adapter and minimal FewToken interfaces |
| `test/FewToken4626Adapter.t.sol` | Unit, fuzz, adversarial, and invariant tests |
| `test/canonical/` | Compatibility tests against the pinned canonical DualPool |
| `scripts/` | Canonical source verification, test harness, and public-surface checks |
| `AUDIT_SCOPE.md` | Contract scope and integration assumptions for independent review |
| `SECURITY.md` | Responsible disclosure instructions |
| `THIRD_PARTY_NOTICES.md` | Fixed dependency versions and licenses |

## Security

Do not report suspected vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md) and include the affected commit plus a Foundry proof of concept when possible.

## License

Ring Protocol source in this repository is licensed under AGPL-3.0-or-later. The pinned Uniswap, OpenZeppelin, and Foundry dependencies retain their upstream licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
