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
#   2. pool-images fixture   -> byte-identical to golden/pool-images.render.yaml,
#      AND confined to the pool that pins its own image: every other pool's
#      document must be byte-identical to the base render.
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

die() { echo "FAIL: $*" >&2; exit 1; }
[[ -d "${chart}" ]] || die "chart not found at ${chart}"
command -v helm >/dev/null || die "helm not on PATH"

render() { helm template "${release}" "${chart}" --namespace "${ns}" -f "${values}/$1"; }

if [[ "${1:-}" == "--update" ]]; then
  mkdir -p "${golden}"
  render base.yaml         > "${golden}/base.render.yaml"
  render pool-images.yaml  > "${golden}/pool-images.render.yaml"
  echo "goldens re-pinned (review the diff before committing):"
  ( cd "${here}/../.." && git diff --stat -- tests/render/golden || true )
  exit 0
fi

# 1. the legacy shape must not move at all
render base.yaml > "${tmp}/base.render.yaml"
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
render pool-images.yaml > "${tmp}/pool-images.render.yaml"
if ! diff -u "${golden}/pool-images.render.yaml" "${tmp}/pool-images.render.yaml" > "${tmp}/pool.diff"; then
  echo "FAIL: per-pool image render drifted from its golden:" >&2
  cat "${tmp}/pool.diff" >&2
  exit 1
fi

python3 - "${tmp}/base.render.yaml" "${tmp}/pool-images.render.yaml" <<'PY'
import sys, re

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
assert moved[0].endswith("control-plane"), f"unexpected pool moved: {moved}"
print(f"PASS  per-pool image moves {moved[0]} only; untouched: {', '.join(sorted(held))}")
PY

echo "OK      render gate clean"
