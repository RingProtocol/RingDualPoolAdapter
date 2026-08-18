#!/usr/bin/env bash
set -euo pipefail

RING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_ROOT="${CANONICAL_DUALPOOL_ROOT:-${RING_ROOT}/lib/v4-hooks-public}"
TEMPLATE="${RING_ROOT}/test/canonical/FewTokenDualPoolCanonical.t.sol.template"
HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ring-dualpool-canonical-harness.XXXXXX")"

cleanup() {
  rm -rf "${HARNESS_ROOT}"
}
trap cleanup EXIT

CANONICAL_DUALPOOL_ROOT="${CANONICAL_ROOT}" \
  "${RING_ROOT}/scripts/verify_canonical_dualpool_checkout.sh"

mkdir -p "${HARNESS_ROOT}/src" "${HARNESS_ROOT}/test/alf"
ln -s "${CANONICAL_ROOT}/src/alf" "${HARNESS_ROOT}/src/alf"
ln -s "${CANONICAL_ROOT}/src/base" "${HARNESS_ROOT}/src/base"
ln -s "${CANONICAL_ROOT}/src/interfaces" "${HARNESS_ROOT}/src/interfaces"
ln -s "${CANONICAL_ROOT}/src/utils" "${HARNESS_ROOT}/src/utils"
ln -s "${CANONICAL_ROOT}/src/AllowlistedFactory.sol" "${HARNESS_ROOT}/src/AllowlistedFactory.sol"
ln -s "${CANONICAL_ROOT}/lib" "${HARNESS_ROOT}/lib"
cp "${CANONICAL_ROOT}/foundry.toml" "${HARNESS_ROOT}/foundry.toml"
cp "${CANONICAL_ROOT}/remappings.txt" "${HARNESS_ROOT}/remappings.txt"
cp "${TEMPLATE}" "${HARNESS_ROOT}/test/alf/FewTokenDualPoolCanonical.t.sol"
printf 'ring-adapter/=%s/\n' "${RING_ROOT}" >> "${HARNESS_ROOT}/remappings.txt"

if ring_head="$(git -C "${RING_ROOT}" rev-parse --verify HEAD 2>/dev/null)"; then
  echo "ring_adapter_head=${ring_head}"
else
  echo "ring_adapter_head=uncommitted-initial-tree"
fi

FOUNDRY_PROFILE=alf forge test \
  --root "${HARNESS_ROOT}" \
  --offline \
  --force \
  --match-path test/alf/FewTokenDualPoolCanonical.t.sol \
  -vv \
  "$@"
