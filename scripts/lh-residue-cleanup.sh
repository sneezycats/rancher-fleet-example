#!/bin/bash
# lh-residue-cleanup.sh - vendor-documented cleanup for Longhorn worker nodes
# that were deleted from the cluster while carrying replicas (KubernetesNodeGone).
#
# After a node-replacement roll, Longhorn keeps the dead nodes' CRs and their
# orphaned replicas (observed: indefinitely - they do NOT self-clean). The
# admission webhook enforces an ORDER for the cleanup:
#   1. every volume must be healthy and attached (safety gate), then
#   2. allowScheduling=false on the stranded node CR,
#   3. delete the replicas pinned to that node (spec.nodeID) - the webhook
#      refuses node deletion while ANY replica remains there ("N replica ...
#      running on it"), regardless of replica state,
#   4. only then delete the node CR. The webhook's replica count comes from an
#      informer cache that can lag seconds behind the replica deletes, so the
#      node delete retries with backoff.
#
# Usage: CLUSTER_KUBECONFIG=<guest kubeconfig> ./lh-residue-cleanup.sh
# Longhorn equivalent in the UI: Node -> Disable Scheduling -> remove.
set -uo pipefail

KC=${CLUSTER_KUBECONFIG:?CLUSTER_KUBECONFIG=<guest kubeconfig> required}
NS=longhorn-system
export KUBECONFIG="$KC"
K="kubectl -n $NS"

GONE=$($K get nodes.longhorn.io -o json | python3 -c "
import json, sys
out = []
for n in json.load(sys.stdin)['items']:
    cs = n.get('status', {}).get('conditions') or []
    if any(c.get('type') == 'Ready' and c.get('reason') == 'KubernetesNodeGone' for c in cs):
        out.append(n['metadata']['name'])
print('\n'.join(out))")

if [ -z "$GONE" ]; then
  echo "no stranded (KubernetesNodeGone) node CRs - nothing to do"
  exit 0
fi
echo "stranded node CRs:"
echo "$GONE"

BAD=$($K get volumes.longhorn.io -o json | python3 -c "
import json, sys
bad = 0
for v in json.load(sys.stdin)['items']:
    st = v.get('status', {})
    if st.get('robustness') != 'healthy' or st.get('state') != 'attached':
        bad += 1
print(bad)")
if [ "$BAD" != "0" ]; then
  echo "REFUSING: $BAD volume(s) not healthy/attached - resolve that first"
  exit 1
fi

for n in $GONE; do
  $K patch nodes.longhorn.io "$n" --type merge -p '{"spec":{"allowScheduling":false}}' >/dev/null
  echo "purging replicas pinned to $n (spec.nodeID)"
  REPS=$(KN="$n" $K get replicas.longhorn.io -o json | KN="$n" python3 -c "
import json, os, sys
n = os.environ['KN']
for r in json.load(sys.stdin)['items']:
    if r.get('spec', {}).get('nodeID') == n:
        print(r['metadata']['name'])")
  if [ -z "$REPS" ]; then
    echo "  (none)"
    continue
  fi
  for r in $REPS; do
    echo "  deleting replica $r"
    if ! out=$($K delete replicas.longhorn.io "$r" 2>&1); then
      echo "  WARNING: replica $r delete reported an error: $out"
    fi
  done
done

echo "deleting stranded node CRs (retrying past webhook cache lag)"
for n in $GONE; do
  ok=""
  for attempt in 1 2 3 4; do
    if out=$($K delete nodes.longhorn.io "$n" 2>&1); then
      echo "  OK: $n deleted"
      ok=1; break
    fi
    case "$out" in
      *NotFound*)
        echo "  OK: $n already gone (deleted elsewhere or self-cleaned) - counting as success"
        ok=1; break ;;
      *)
        echo "  attempt $attempt for $n: $out"
        sleep 20 ;;
    esac
  done
  if [ -z "$ok" ]; then
    echo "  FAILED: $n could not be deleted after retries - investigate manually"
  fi
done

sleep 15
echo "=== post-state ==="
$K get nodes.longhorn.io --no-headers || true
LEFT=$($K get replicas.longhorn.io -o json 2>/dev/null | python3 -c "
import json, sys
gone = set('''$GONE'''.split())
print(len([r for r in json.load(sys.stdin)['items'] if r.get('spec', {}).get('nodeID') in gone]))")
echo "replicas remaining on stranded nodes: $LEFT"
