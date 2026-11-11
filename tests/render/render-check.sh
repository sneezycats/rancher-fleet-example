#!/usr/bin/env bash
# Render gate for the cluster template chart.
#
# WHY THIS EXISTS. The chart's output is not pods, it is machine config. When
# the rendered content of a pool's HarvesterConfig changes, Rancher re-clones
# that pool's machine template under a new hash and the pool's machines are
# REPLACED — new VMs, new root disks, nodes rejoined. So a chart edit that
# "only touches a template" is not a no-op: on the next Fleet sync it can roll
# every cluster the bundle targets, with no reviewable signal that it will.
# (A pool's *metadata* is not known-safe either — Rancher's clone-hash inputs
# are its own — so treat the whole rendered document as load-bearing.)
#
# This script pins the render so a diff is either absent or explicitly
# regenerated and reviewed:
#
#   tests/render/render-check.sh              # check (exit 1 on drift)
#   tests/render/render-check.sh --update     # re-pin goldens after review
#
# Checks:
#   1. base fixture          -> byte-identical to golden/base.render.yaml.
#      Any delta here means merging the change rolls live clusters.
#   2. derived per-pool case -> byte-identical to golden/pool-images.render.yaml,
#      AND confined to the pool that pins its own image: every other pool's
#      document must be byte-identical to the base render.
#
# WHY THE PER-POOL CASE IS DERIVED, NOT STORED. Helm replaces a list wholesale
# when a values file supplies it (and `--set nodepools[0].x` replaces the
# element, it does not merge into it), so a stored per-pool fixture must
# duplicate every pool's shape. That fixture then silently drifts from
# values.yaml the moment anyone retunes vCPU/RAM/disk for an environment, and
# the check fails with "3 differing lines; expected only diskInfo" — pointing
# at the image feature when the real cause is the pool shape. So the gate
# copies the nodepools block straight out of the chart's own values.yaml and
# rewrites ONLY each pool's imageName. The pool shape is then unconditionally
# shared between the two renders, which is exactly the assumption the
# "only that pool moved" assertion rests on.
#
# NOTES.txt is deliberately out of scope: Helm notes are not applied as
# resources, so notes text cannot roll anything.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="${here}/../../cluster-templates/chart"
golden="${here}/golden"
values="${here}/values"
release="render-check"
ns="fleet-default"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

die() { echo "FAIL: $*"; exit 1; }
[[ -d "${chart}" ]] || die "chart not found at ${chart}"
command -v helm >/dev/null || die "helm not on PATH"

render() { helm template "${release}" "${chart}" --namespace "${ns}" -f "${1}"; }

# Build the per-pool-image fixture from the chart's own values.yaml: take the
# nodepools block verbatim, then pin pool 0 to golden-image-v2 and pool 1 to
# golden-image-v1 (the same string the base fixture shares). Everything else —
# quantity, vcpu, memory, disk, drain options — is inherited byte-for-byte.
derive_pool_images() {
  local out="$1"
  {
    cat "${values}/base.yaml"
    awk '
      /^nodepools:/ { grab = 1 }
      grab && /^[^ ]/ && !/^nodepools:/ { grab = 0 }
      grab { print }
    ' "${chart}/values.yaml"
  } > "${out}.raw"
  python3 - "${out}.raw" "${out}" <<'PYGEN'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()
# pool order as rendered by the chart; index 0 = the pool that advances
# pool 0 advances to v2; every other pool holds at v1. Any pool count works.
out, pool, seen = [], -1, 0
for ln in lines:
    m = re.match(r"^  - name: (\S+)", ln)
    if m:
        pool = seen
        seen += 1
        out.append(ln)
        continue
    if pool >= 0 and re.match(r"^    imageName: ", ln):
        out.append('    imageName: "golden-image-%s"' % ("v2" if pool == 0 else "v1"))
        continue
    out.append(ln)
# every pool must have had an imageName key to rewrite, else the derivation
# silently missed a pool and the check would prove nothing
if seen < 2:
    raise SystemExit("FAIL: derived fixture saw %d pool(s); expected >= 2" % seen)
open(dst, "w").write("\n".join(out) + "\n")
PYGEN
  # every pool must have had its imageName key rewritten, else the derivation
  # silently missed a pool and the check would prove nothing
  local pinned pools
  pools=$(grep -c '^  - name: ' "${out}")
  pinned=$(grep -c '^    imageName: "golden-image-v' "${out}" || true)
  [[ "${pools}" -ge 2 ]] || die "derived fixture saw ${pools} pool(s); expected >= 2"
  [[ "${pinned}" == "${pools}" ]] || die "derived fixture pinned ${pinned} of ${pools} pool images"
}

if [[ "${1:-}" == "--update" ]]; then
  mkdir -p "${golden}"
  render "${values}/base.yaml"            > "${golden}/base.render.yaml"
  derive_pool_images "${tmp}/pool-images.yaml"
  render "${tmp}/pool-images.yaml"        > "${golden}/pool-images.render.yaml"
  echo "goldens re-pinned (review the diff before committing):"
  ( cd "${here}/../.." && git diff --stat -- tests/render/golden || true )
  exit 0
fi

# 1. the legacy shape must not move at all
render "${values}/base.yaml" > "${tmp}/base.render.yaml"
if ! diff -u "${golden}/base.render.yaml" "${tmp}/base.render.yaml" > "${tmp}/base.diff"; then
  echo "FAIL: the render for the shared-image shape changed. A delta in a" >&2
  echo "      pool's machine config = Rancher re-clones that pool's machine" >&2
  echo "      template = every machine in that pool is replaced on next sync." >&2
  echo      "---" >&2
  cat "${tmp}/base.diff" >&2
  echo   "---" >&2
  echo "      If this delta is intended, run: tests/render/render-check.sh --update" >&2
  echo "      and get the diff reviewed in the PR." >&2
  exit 1
fi
echo "PASS  shared-image render unchanged (no roll for clusters on one image)"

# 2. the per-pool shape must move ONLY the pool that pins its own image
derive_pool_images "${tmp}/pool-images.yaml"
render "${tmp}/pool-images.yaml" > "${tmp}/pool-images.render.yaml"
if ! diff -u "${golden}/pool-images.render.yaml" "${tmp}/pool-images.render.yaml" > "${tmp}/pool.diff"; then
  echo "FAIL: per-pool image render drifted from its golden:" >&2
  cat "${tmp}/pool.diff" >&2
  exit 1
fi

# the pool that advances is whatever the chart lists first, not a hardcoded name
first_pool=$(awk '/^nodepools:/{g=1;next} g && /^  - name: /{sub(/^  - name: /,"");print;exit}' "${chart}/values.yaml")
[[ -n "${first_pool}" ]] || die "could not read the first pool name from ${chart}/values.yaml"
FIRST_POOL="${release}-${first_pool}" python3 - "${tmp}/base.render.yaml" "${tmp}/pool-images.render.yaml" <<'PY'
import os, sys, re

def docs(path):
    out = {}
    for chunk in open(path).read().split("\n---\n"):
        m = re.search(r"^  name: (\S+)$", chunk, re.M)
        if m:
            out[m.group(1)] = chunk.rstrip() + "\n"
    return out

base, pool = docs(sys.argv[1]), docs(sys.argv[2])
assert base.keys() == pool.keys(), f"object set changed: {set(base) ^ set(pool)}"

def diskinfo(doc):
    m = re.search(r'^diskInfo: "(.*)"$', doc, re.M)
    return m.group(1) if m else None

moved, held = [], []
for name in base:
    if base[name] == pool[name]:
        held.append(name)
        continue
    moved.append(name)
    # a moved document may differ ONLY in diskInfo's image name
    a, b = base[name].splitlines(), pool[name].splitlines()
    assert len(a) == len(b), f"{name}: line count changed, not just an image"
    diffs = [(x, y) for x, y in zip(a, b) if x != y]
    assert len(diffs) == 1, f"{name}: {len(diffs)} differing lines; expected only diskInfo"
    x, y = diffs[0]
    assert x.startswith("diskInfo: ") and y.startswith("diskInfo: "), \
        f"{name}: non-diskInfo line changed:\n  -{x}\n  +{y}"
    # the ONLY allowed delta: the shared image name swapped for the pool's own
    assert diskinfo(x).replace("golden-image-v1", "golden-image-v2") == diskinfo(y), \
        f"{name}: image-name substitution does not explain the delta:\n  -{x}\n  +{y}"

assert len(moved) == 1, f"expected exactly 1 pool moved, got {moved}"
expected_moved = os.environ["FIRST_POOL"]
assert moved[0] == expected_moved, f"expected {expected_moved} to move, got {moved}"
print(f"PASS  per-pool image moves {moved[0]} only; untouched: {', '.join(sorted(held))}")
PY

echo "OK      render gate clean"
