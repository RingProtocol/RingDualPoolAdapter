#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

actual_files="$(mktemp "${TMPDIR:-/tmp}/ring-public-files.XXXXXX")"
expected_files="$(mktemp "${TMPDIR:-/tmp}/ring-expected-files.XXXXXX")"
cleanup() {
  rm -f "${actual_files}" "${expected_files}"
}
trap cleanup EXIT

git ls-files | LC_ALL=C sort > "${actual_files}"
LC_ALL=C sort PUBLIC_FILES.txt > "${expected_files}"
diff -u "${expected_files}" "${actual_files}"

if git ls-files | grep -E '(^|/)(\.env($|\.)|broadcast/|cache/|out/|evidence/|config/)|\.(pem|key|p12|jks)$'; then
  echo "sensitive or generated path is tracked" >&2
  exit 1
fi

for forbidden in \
  '/Users/' \
  '/private/tmp' \
  'Few-Protocol' \
  'Few Protocol' \
  'ring-controller' \
  'CLAUDE.md' \
  'execution_allowed' \
  'Steakhouse' \
  'ABDK' \
  'Michael'; do
  if git grep -n -I -F "${forbidden}" -- . ':!scripts/check_public_release.sh'; then
    echo "private or internal reference found: ${forbidden}" >&2
    exit 1
  fi
done

if git grep -n -I -E \
  '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|github_pat_|ghp_[A-Za-z0-9]|sk_(live|test)_[A-Za-z0-9]|xox[baprs]-|AKIA[0-9A-Z]{16})' \
  -- . ':!scripts/check_public_release.sh'; then
  echo "possible credential material found" >&2
  exit 1
fi

if git grep -n -I -E \
  '(PRIVATE_KEY|MNEMONIC|API_KEY|RPC_URL|PASSWORD|CLIENT_SECRET)[[:space:]]*=[[:space:]]*[^$<{[:space:]]' \
  -- . ':!scripts/check_public_release.sh'; then
  echo "possible hard-coded secret assignment found" >&2
  exit 1
fi

expected_forge_std="1de6eecf821de7fe2c908cc48d3ab3dced20717f"
expected_openzeppelin="dbb6104ce834628e473d2173bbc9d47f81a9eec3"
expected_dualpool="ffd7f8a8d1f5df5deb6f41c8d2ba99d118244ed6"

[[ "$(git ls-files -s lib/forge-std | awk '{print $2}')" == "${expected_forge_std}" ]]
[[ "$(git ls-files -s lib/openzeppelin-contracts | awk '{print $2}')" == "${expected_openzeppelin}" ]]
[[ "$(git ls-files -s lib/v4-hooks-public | awk '{print $2}')" == "${expected_dualpool}" ]]

ring_owned_files=(
  src/adapters/FewToken4626Adapter.sol
  src/interfaces/IFew.sol
  test/FewToken4626Adapter.t.sol
  test/canonical/FewTokenDualPoolCanonical.t.sol.template
)

for file in "${ring_owned_files[@]}"; do
  head -n 1 "${file}" | grep -Fqx '// SPDX-License-Identifier: MIT'
done

head -n 1 LICENSE | grep -Fqx 'MIT License'

if git grep -n -I -E '(AGPL-3\.0|GNU Affero)' -- . ':!scripts/check_public_release.sh'; then
  echo "stale AGPL license reference found" >&2
  exit 1
fi

echo "public release surface verified"
