#!/usr/bin/env bash
set -euo pipefail

EXPECTED_COMMIT="ffd7f8a8d1f5df5deb6f41c8d2ba99d118244ed6"
RING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_ROOT="${CANONICAL_DUALPOOL_ROOT:-${RING_ROOT}/lib/v4-hooks-public}"
ADAPTER_PATH="src/adapters/FewToken4626Adapter.sol"

git -C "${CANONICAL_ROOT}" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "canonical checkout not found: ${CANONICAL_ROOT}" >&2
  exit 1
}

actual_commit="$(git -C "${CANONICAL_ROOT}" rev-parse HEAD)"
[[ "${actual_commit}" == "${EXPECTED_COMMIT}" ]] || {
  echo "canonical source drift: expected ${EXPECTED_COMMIT}, got ${actual_commit}" >&2
  exit 1
}

# Do not suppress submodule state here. A broken or dirty dependency invalidates the
# canonical-bytecode and compatibility proof just as much as a dirty Solidity source file.
[[ -z "$(git -C "${CANONICAL_ROOT}" status --porcelain)" ]] || {
  echo "canonical source or submodule checkout is dirty" >&2
  git -C "${CANONICAL_ROOT}" status --short >&2
  exit 1
}
git -C "${CANONICAL_ROOT}" diff --submodule=log --exit-code >/dev/null
git -C "${CANONICAL_ROOT}" diff --cached --submodule=log --exit-code >/dev/null

verify_submodule() {
  local repository="$1"
  local path="$2"
  local expected actual dirty url
  expected="$(git -C "${repository}" ls-tree HEAD "${path}" | awk '$1 == "160000" {print $3}')"
  [[ -n "${expected}" && -e "${repository}/${path}/.git" ]] || {
    echo "required canonical submodule is not initialized: ${path}" >&2
    exit 1
  }
  actual="$(git -C "${repository}/${path}" rev-parse HEAD)"
  dirty="$(git -C "${repository}/${path}" status --porcelain)"
  url="$(git -C "${repository}" config -f .gitmodules --get "submodule.${path}.url")"
  [[ "${actual}" == "${expected}" && -z "${dirty}" && -n "${url}" ]] || {
    echo "canonical submodule mismatch: ${path} expected=${expected} actual=${actual}" >&2
    exit 1
  }
  printf 'canonical_submodule=%s expected=%s actual=%s dirty=no url=%s\n' \
    "${path}" "${expected}" "${actual}" "${url}"
}

verify_submodule "${CANONICAL_ROOT}" "lib/blocknumberish"
verify_submodule "${CANONICAL_ROOT}" "lib/forge-std"
verify_submodule "${CANONICAL_ROOT}" "lib/openzeppelin-contracts"
verify_submodule "${CANONICAL_ROOT}" "lib/solady"
verify_submodule "${CANONICAL_ROOT}" "lib/v4-core"
verify_submodule "${CANONICAL_ROOT}" "lib/v4-periphery"
verify_submodule "${CANONICAL_ROOT}/lib/v4-core" "lib/solmate"

required_remappings=(
  '@uniswap/v4-core/=lib/v4-core/'
  '@uniswap/v4-periphery/=lib/v4-periphery/'
  '@uniswap/blocknumberish/=lib/blocknumberish/'
  '@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/'
  'forge-std/=lib/forge-std/src/'
  'solmate/=lib/v4-core/lib/solmate/'
  'solady/=lib/solady/src/'
)
for remapping in "${required_remappings[@]}"; do
  grep -Fqx "${remapping}" "${CANONICAL_ROOT}/remappings.txt" || {
    echo "required canonical remapping missing: ${remapping}" >&2
    exit 1
  }
done

printf 'canonical_source_commit=%s\n' "${actual_commit}"
printf 'canonical_submodule_diff=clean\n'
printf 'canonical_remappings=verified\n'
printf 'ring_adapter_source_sha256=%s\n' \
  "$(shasum -a 256 "${RING_ROOT}/${ADAPTER_PATH}" | awk '{print $1}')"
if git -C "${RING_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1; then
  adapter_diff="$(git -C "${RING_ROOT}" diff --no-ext-diff --binary HEAD -- "${ADAPTER_PATH}")"
else
  adapter_diff="uncommitted-initial-tree"
fi
printf 'ring_adapter_diff_from_head_sha256=%s\n' \
  "$(printf '%s' "${adapter_diff}" | shasum -a 256 | awk '{print $1}')"
printf 'ring_adapter_git_status=%s\n' \
  "$(git -C "${RING_ROOT}" status --short -- "${ADAPTER_PATH}" | tr -d '\n')"
