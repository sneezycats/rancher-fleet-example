#!/usr/bin/env bash
# lh-graceful-remove.sh — Longhorn's documented graceful-removal handshake for
# ONE node: disable scheduling, request eviction, then block until the node
# holds no replicas at all.
#
# WHY THIS EXISTS
# A Rancher/CAPI machine replacement destroys the VM. A drain moves pods, not
# replicas: Kubernetes does not notify the CSI layer to migrate data before the
# node is destroyed, so replicas sitting on that node are lost with it and the
# volume rebuilds afterwards (a degraded window bounded by
# replica-replenishment-wait-interval). Eviction instead builds the replacement
# replica elsewhere FIRST and removes the source after, so the volume never
# drops below its replica count. Documented in Longhorn's "Graceful Node
# Removal"; this script is the CLI form of its steps 2 and 3.
#
# PRECONDITION (the one that bites)
# A replica can only be evicted to a node that may accept a second replica of
# that volume. With replica-soft-anti-affinity=false (this repo's bundle:
# replicas of one volume never share a node) and numberOfReplicas equal to the
# node count, no destination exists. Longhorn then accepts the request and
# reports "No disk candidates for evicting replica" indefinitely. This script
# refuses to start in that state — the node is only patched after the check
# proves a destination exists. Either run against a pool with more nodes than
# replicas per volume, or enable co-location for the window:
#   kubectl -n longhorn-system patch settings.longhorn.io \
#     replica-soft-anti-affinity --type merge -p '{"value":"true"}'
# and restore it afterwards.
#
# This script does not cordon, drain, or delete anything — node lifecycle
# belongs to Rancher/CAPI. It only moves data off the node.
#
# Usage: CLUSTER_KUBECONFIG=<guest kubeconfig> ./lh-graceful-remove.sh <node>
# Env:   TIMEOUT_SECONDS  total wait for eviction (default 3600)
#        STALL_SECONDS    give up if the count stops moving (default 300)
set -uo pipefail

KC=${CLUSTER_KUBECONFIG:?CLUSTER_KUBECONFIG=<guest kubeconfig> required}
export KUBECONFIG="$KC"
K="kubectl -n longhorn-system"
NODE=${1:?usage: lh-graceful-remove.sh <longhorn node name>}
TIMEOUT=${TIMEOUT_SECONDS:-3600}
STALL=${STALL_SECONDS:-300}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

die() { echo "REFUSING: $*" >&2; exit 1; }

$K get nodes.longhorn.io "$NODE" >/dev/null 2>&1 || {
  echo "no longhorn node '$NODE'. Known nodes:"
  $K get nodes.longhorn.io -o custom-columns=NAME:.metadata.name --no-headers
  exit 1
}

# ---- gate 1: nothing already broken ----------------------------------------
$K get volumes.longhorn.io -o json > "$TMP/vols.json" || die "cannot read volumes"
BAD=$(VOL="$TMP/vols.json" python3 -c "
import json, os
print(sum(1 for v in json.load(open(os.environ['VOL']))['items']
          if v.get('status', {}).get('robustness') != 'healthy'
          or v.get('status', {}).get('state') not in ('attached', 'detached')))") \
  || die "cannot evaluate volume health"
[ "$BAD" != "0" ] && die "$BAD volume(s) not healthy - resolve that before evicting"

# ---- gate 2: does a destination exist? (fail-closed) ------------------------
# Both documents go through files, never a pipeline: in `a | b | python`, b's
# stdout replaces a's, so python silently sees one document and computes
# garbage. A gate that cannot compute must NOT proceed to the patch.
$K get replicas.longhorn.io -o json > "$TMP/reps.json" || die "cannot read replicas"
$K get nodes.longhorn.io  -o json > "$TMP/nodes.json" || die "cannot read longhorn nodes"
SOFT=$($K get settings.longhorn.io replica-soft-anti-affinity -o jsonpath='{.value}' 2>/dev/null)
[ -n "$SOFT" ] || die "cannot read replica-soft-anti-affinity"

GATE=$(REPS="$TMP/reps.json" NODES="$TMP/nodes.json" VOL="$TMP/vols.json" \
       NODE="$NODE" SOFT="$SOFT" python3 -c '
import json, os, sys
from collections import defaultdict
try:
    node = os.environ["NODE"]
    soft = os.environ["SOFT"] == "true"
    reps  = json.load(open(os.environ["REPS"]))["items"]
    nodes = json.load(open(os.environ["NODES"]))["items"]
except Exception as e:
    sys.stderr.write("destination check failed: %s\n" % e)
    sys.exit(2)

def volume(name):                       # replica names are <volume>-r-<id>
    return name.rsplit("-r-", 1)[0]

def ready(n):
    return any(c["type"] == "Ready" and c["status"] == "True"
               for c in n.get("status", {}).get("conditions", []))

# nodes that could receive anything at all
cand = {n["metadata"]["name"] for n in nodes
        if n["spec"].get("allowScheduling") and n["metadata"]["name"] != node and ready(n)}

hosts = defaultdict(set)                # volume -> nodes already hosting a replica
for r in reps:
    hosts[volume(r["metadata"]["name"])].add(r["spec"].get("nodeID", ""))

# only volumes with replicas on the doomed node matter
on_node = {volume(r["metadata"]["name"]) for r in reps if r["spec"].get("nodeID") == node}
if not on_node:
    print("NOTHING")                    # node holds no data; nothing to evict
    sys.exit(0)

blocked = [v for v in sorted(on_node) if not (cand if soft else cand - hosts[v])]
print("BLOCKED " + " ".join(blocked) if blocked else "GO %d volumes" % len(on_node))
') || die "destination check failed - refusing to touch the node"

case "$GATE" in
  NOTHING) echo "$NODE already holds no replicas; nothing to evict"; exit 0 ;;
  GO*)     echo "destination check passed: ${GATE#GO }" ;;
  BLOCKED*)
    die "no node may receive a replica of: ${GATE#BLOCKED }
  replica-soft-anti-affinity=$SOFT, and every schedulable node already hosts a
  replica of those volumes. Longhorn would accept the eviction and then report
  \"No disk candidates for evicting replica\" indefinitely. Pick one:
    * run against a pool with MORE nodes than replicas per volume, or
    * enable co-location for this window:
        kubectl -n longhorn-system patch settings.longhorn.io \\
          replica-soft-anti-affinity --type merge -p '{\"value\":\"true\"}'
      (restore it to \"false\" when the roll is done)" ;;
  *)       die "unexpected destination-check result: $GATE" ;;
esac

# ---- the handshake ----------------------------------------------------------
$K patch nodes.longhorn.io "$NODE" --type merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null \
  || die "patch failed"
echo "requested eviction on $NODE (scheduling disabled); waiting for scheduledReplicas = 0"

count() {
  NODE="$NODE" python3 -c '
import json, os, subprocess
r = subprocess.run(["kubectl", "-n", "longhorn-system", "get", "nodes.longhorn.io",
                    os.environ["NODE"], "-o", "json"], capture_output=True, text=True)
try:
    n = json.loads(r.stdout)
except Exception:
    print(-1); raise SystemExit
tot = 0
for d in (n.get("status", {}).get("diskStatus") or {}).values():
    tot += len(d.get("scheduledReplica") or {})
    tot += len(d.get("scheduledBackingImage") or {})
print(tot)'
}

start=$(date +%s); last=$(count); lastchange=$start
while :; do
  now=$(date +%s); cur=$(count)
  if [ "$cur" != "$last" ]; then
    echo "  t+$((now-start))s replicas+images on node: ${cur:-?}"
    last=$cur; lastchange=$now
  fi
  [ "${cur:-1}" = "0" ] && { echo "eviction complete: $NODE holds no data"; break; }
  if [ "${cur:-1}" = "-1" ]; then echo "lost sight of $NODE"; exit 1; fi
  if [ $((now - lastchange)) -gt "$STALL" ]; then
    echo "STALL: no progress for ${STALL}s (${cur:-?} left)."
    echo "  why:   kubectl -n longhorn-system logs -l app=longhorn-manager --since=${STALL}s | grep -iE 'candidates|evict'"
    echo "  abort: kubectl -n longhorn-system patch nodes.longhorn.io $NODE \\"
    echo "           --type merge -p '{\"spec\":{\"evictionRequested\":false,\"allowScheduling\":true}}'"
    exit 1
  fi
  if [ $((now - start)) -gt "$TIMEOUT" ]; then echo "TIMEOUT after ${TIMEOUT}s, ${cur:-?} left"; exit 1; fi
  sleep 20
done

cat <<EOF

Next, only if the node is actually leaving: Longhorn requires the Kubernetes
node to be removed before the Longhorn node resource will delete.

    kubectl delete node <node>
    kubectl -n longhorn-system delete nodes.longhorn.io <node>

To put the node back instead:

    kubectl -n longhorn-system patch nodes.longhorn.io <node> --type merge \\
      -p '{"spec":{"evictionRequested":false,"allowScheduling":true}}'
EOF
