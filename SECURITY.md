# Security policy

## Reporting a vulnerability

Do not open a public GitHub issue for a suspected vulnerability.

Send reports to `contact@ring.exchange`. Include the affected contract and commit, expected impact, reproduction steps, and a Foundry proof of concept when possible. Avoid including secrets or personal data that are not necessary to reproduce the issue.

Ring Protocol will acknowledge a report as soon as practical and coordinate disclosure after the issue has been assessed and fixed. No public bug bounty is attached to this repository unless Ring Protocol announces one separately.

## Scope

In scope:

- `src/adapters/FewToken4626Adapter.sol`;
- integration failures that can cause loss, theft, unbacked shares, incorrect capacity reporting, or unsafe canonical DualPool execution;
- constructor and runtime checks for FewToken, FewFactory, and the immutable origin vault.

Report vulnerabilities in Uniswap, OpenZeppelin, Foundry, or an origin vault to the relevant upstream project unless the issue is caused by this adapter's integration logic.

## Safe testing

Use local tests or a fork. Testing against a live deployment in a way that risks third-party funds, disrupts service, or accesses data without permission is not authorized.
