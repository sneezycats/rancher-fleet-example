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
#   1. shared-image shape    -> byte-identical to golden/base.render.yaml.
#      Any delta here means merging the change rolls live clusters.
#   2. pool-pin shape        -> byte-identical to golden/pool-pin.render.yaml.
#   3. one pool's pin changed -> exactly that pool's document moves, exactly one
#      line, and inside that line exactly the imageName field.
#
# WHY THE PER-POOL CASE IS DERIVED, NOT STORED. Helm replaces a list wholesale
# when a values file supplies it (and `--set nodepools[0].x` replaces the
# element, it does not merge into it), so a stored per-pool fixture must
# duplicate every pool's shape. That fixture then silently drifts from
# values.yaml the moment anyone retunes vCPU/RAM/disk for an environment, and
# the check fails with "3 differing lines; expected only diskInfo" — pointing
# at the image feature when the real cause is the pool shape. So the gate
# copies the nodepools block straight out of the chart's own values.yaml and
# rewrites ONE pool's imageName. The pool shapes are then unconditionally
# shared between the renders, which is exactly the assumption the
# "only that pool moved" assertion rests on.
#
# WHY CHECK 3 COMPARES TWO DERIVED RENDERS, NOT SHARED-VERSUS-PINNED. Comparing
# the shared-image render against a pinned one only isolates a single pool while
# every pool still inherits the shared image. The moment a cluster pins its own
# images - the normal day-2 state this feature exists to create - those two
# renders differ in every pool and the check reports a leak that does not exist.
# Two renders that differ in one pool's pin and nothing else hold whatever the
# environment pins.
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
pin_a="render-check-image-A"
pin_b="render-check-image-B"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

die() { echo "FAIL: $*"; exit 1; }
[[ -d "${chart}" ]] || die "chart not found at ${chart}"
command -v helm >/dev/null || die "helm not on PATH"

render() { helm template "${release}" "${chart}" --namespace "${ns}" -f "${1}"; }

# Fixture = base values + the chart's own nodepools block verbatim, with ONE
# pool's imageName rewritten. Everything else - quantity, vcpu, memory, disk,
# drain options, and the OTHER pools' image pins whatever they are - is
# inherited byte-for-byte.
#   derive_fixture <out-file> <pool-index> <image-name>
derive_fixture() {
  local out="$1" pool="$2" image="$3"
  {
    cat "${values}/base.yaml"
    awk '
      /^nodepools:/ { grab = 1 }
      grab && /^[^ ]/ && !/^nodepools:/ { grab = 0 }
      grab { print }
    ' "${chart}/values.yaml"
  } > "${out}.raw"
  python3 - "${out}.raw" "${out}" "${pool}" "${image}" <<'PYGEN'
import re, sys
src, dst, target_pool, image = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
out, pool, seen, rewritten = [], -1, 0, 0
for ln in open(src).read().splitlines():
    m = re.match(r"^  - name: (\S+)", ln)
    if m:
        pool = seen
        seen += 1
        out.append(ln)
        continue
    if pool == target_pool and re.match(r"^    imageName: ", ln):
        out.append('    imageName: "%s"' % image)
        rewritten += 1
        continue
    out.append(ln)
# A missed rewrite would make the two renders identical and let check 3 pass
# while proving nothing. Fail loudly instead.
if seen < 2:
    raise SystemExit("FAIL: derived fixture saw %d pool(s); expected >= 2" % seen)
if rewritten != 1:
    raise SystemExit("FAIL: rewrote pool %d imageName %d time(s); expected exactly 1"
                     % (target_pool, rewritten))
open(dst, "w").write("\n".join(out) + "\n")
PYGEN
  rm -f "${out}.raw"
}

# Base shape with the version-ordering block removed (the pre-feature shape).
# NOTE: null, not {} - Helm MERGES an empty map over the chart default, so {}
# would render the shipped block and the check would compare two identical
# documents and pass vacuously. null is Helm's documented way to unset a default.
strategy_fixture() {
  { cat "${values}/base.yaml"; echo "upgradeStrategy: null"; } > "$1"
}

# The advancing pool is whatever the chart lists first, not a hardcoded name.
first_pool=$(awk '/^nodepools:/{g=1;next} g && /^  - name: /{sub(/^  - name: /,"");print;exit}' "${chart}/values.yaml")
[[ -n "${first_pool}" ]] || die "could not read the first pool name from ${chart}/values.yaml"
moved_doc="${release}-${first_pool}"

if [[ "${1:-}" == "--update" ]]; then
  mkdir -p "${golden}"
  render "${values}/base.yaml" > "${golden}/base.render.yaml"
  derive_fixture "${tmp}/pin-a.yaml" 0 "${pin_a}"
  render "${tmp}/pin-a.yaml" > "${golden}/pool-pin.render.yaml"
  strategy_fixture "${tmp}/no-strategy.yaml"
  render "${tmp}/no-strategy.yaml" > "${golden}/no-strategy.render.yaml"
  echo "goldens re-pinned (review the diff before committing):"
  ( cd "${here}/../.." && git diff --stat -- tests/render/golden || true )
  exit 0
fi

# 1. the shared-image shape must not move at all
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

# 2. the pool-pin shape must not move either
[[ -f "${golden}/pool-pin.render.yaml" ]] || die "missing golden/pool-pin.render.yaml; run --update"
derive_fixture "${tmp}/pin-a.yaml" 0 "${pin_a}"
render "${tmp}/pin-a.yaml" > "${tmp}/pin-a.render.yaml"
if ! diff -u "${golden}/pool-pin.render.yaml" "${tmp}/pin-a.render.yaml" > "${tmp}/pin.diff"; then
  echo "FAIL: pool-pin render drifted from its golden:" >&2
  cat "${tmp}/pin.diff" >&2
  exit 1
fi

# 3. same shape, one pool's pin swapped: exactly that pool moves, one field
derive_fixture "${tmp}/pin-b.yaml" 0 "${pin_b}"
render "${tmp}/pin-b.yaml" > "${tmp}/pin-b.render.yaml"

FIRST_POOL="${moved_doc}" PIN_A="${pin_a}" PIN_B="${pin_b}" \
  python3 - "${tmp}/pin-a.render.yaml" "${tmp}/pin-b.render.yaml" <<'PY'
import json, os, re, sys

def docs(path):
    out = {}
    for chunk in open(path).read().split("\n---\n"):
        m = re.search(r"^  name: (\S+)$", chunk, re.M)
        if m:
            out[m.group(1)] = chunk.rstrip() + "\n"
    return out

a_docs, b_docs = docs(sys.argv[1]), docs(sys.argv[2])
assert a_docs.keys() == b_docs.keys(), f"object set changed: {set(a_docs) ^ set(b_docs)}"

def disks(line):
    # diskInfo is JSON inside a YAML quoted scalar, so its quotes are escaped
    m = re.match(r'^diskInfo: "(.*)"$', line)
    assert m, f"not a diskInfo line: {line!r}"
    return json.loads(m.group(1).encode().decode("unicode_escape"))["disks"]

def shape(disk_list):
    return [{k: v for k, v in d.items() if k != "imageName"} for d in disk_list]

moved, held = [], []
for name in a_docs:
    if a_docs[name] == b_docs[name]:
        held.append(name)
        continue
    moved.append(name)
    a, b = a_docs[name].splitlines(), b_docs[name].splitlines()
    assert len(a) == len(b), f"{name}: line count changed, not just an image"
    diffs = [(x, y) for x, y in zip(a, b) if x != y]
    assert len(diffs) == 1, f"{name}: {len(diffs)} differing lines; expected only diskInfo"
    da, db = disks(diffs[0][0]), disks(diffs[0][1])
    assert len(da) == len(db), f"{name}: disk count changed"
    assert shape(da) == shape(db), \
        f"{name}: a disk field other than imageName changed:\n  -{da}\n  +{db}"
    images_a = [d.get("imageName") for d in da]
    images_b = [d.get("imageName") for d in db]
    assert os.environ["PIN_A"] in images_a and os.environ["PIN_B"] in images_b, \
        f"{name}: the pin swap is not what moved it: {images_a} -> {images_b}"

assert len(moved) == 1, \
    f"expected exactly 1 pool to move, got {moved} - a per-pool pin leaked"
assert moved[0] == os.environ["FIRST_POOL"], \
    f"expected {os.environ['FIRST_POOL']} to move, got {moved[0]}"
print(f"PASS  one pool's pin moves {moved[0]} only; untouched: {', '.join(sorted(held))}")
PY

# 4. version-ordering policy must never reach machine config. upgradeStrategy
#    governs Kubernetes version upgrades, not image hops; if it ever leaked into
#    a pool's machine config it would silently roll every pool it targeted.
[[ -f "${golden}/no-strategy.render.yaml" ]] || die "missing golden/no-strategy.render.yaml; run --update"
strategy_fixture "${tmp}/no-strategy.yaml"
render "${tmp}/no-strategy.yaml" > "${tmp}/no-strategy.render.yaml"
if ! diff -u "${golden}/no-strategy.render.yaml" "${tmp}/no-strategy.render.yaml" > "${tmp}/nostream.diff"; then
  echo "FAIL: the omitted-strategy render drifted from its golden:" >&2
  cat "${tmp}/nostream.diff" >&2
  exit 1
fi

python3 - "${tmp}/base.render.yaml" "${tmp}/no-strategy.render.yaml" <<'PY'
import re, sys

def docs(path):
    out = {}
    for chunk in open(path).read().split("\n---\n"):
        m = re.search(r"^  name: (\S+)$", chunk, re.M)
        if m:
            out[m.group(1)] = chunk.rstrip() + "\n"
    return out

with_s, without = docs(sys.argv[1]), docs(sys.argv[2])
assert with_s.keys() == without.keys(), f"object set changed: {set(with_s) ^ set(without)}"

# every machine-config document must be untouched, byte for byte
config_docs = [n for n in with_s if n != next(n for n in with_s if "apiVersion: provisioning.cattle.io" in with_s[n])]
for name in config_docs:
    assert with_s[name] == without[name], \
        f"{name}: upgradeStrategy changed machine config - that would roll every pool"

# absolute assertion: the policy string must exist ONLY inside the Cluster CR.
# A two-render diff cannot catch a leak that both renders share, so this does
# not depend on the fixture at all.
cluster = next(n for n in with_s if "apiVersion: provisioning.cattle.io" in with_s[n])
for name, doc in with_s.items():
    if name != cluster:
        assert "upgradeStrategy" not in doc, \
            f"{name}: upgradeStrategy leaked into machine config - it would roll every pool this template targets"
added = [l for l in with_s[cluster].splitlines() if l not in without[cluster].splitlines()]
removed = [l for l in without[cluster].splitlines() if l not in with_s[cluster].splitlines()]
assert not removed, f"{cluster}: defining the strategy also REMOVED lines: {removed}"
assert added and all("upgradeStrategy" in l or "Concurrency" in l for l in added), \
    f"{cluster}: delta is not confined to the strategy block: {added}"
print(f"PASS  upgradeStrategy confined to {cluster} (+{len(added)} policy lines); "
      f"{len(config_docs)} machine-config documents identical and free of the field")
PY

echo "OK      render gate clean"
