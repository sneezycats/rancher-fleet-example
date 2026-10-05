#!/bin/bash
# lh-roll-mode.sh — flip Longhorn's node-drain-policy for a maintenance window.
#
# on     : block-for-eviction-if-contains-last-replica — the vendor evicts any
#          replica that is a volume's last healthy replica off the node being
#          drained, and blocks the drain until eviction completes. Use ONLY
#          during planned maintenance: it fires on ANY cordon.
# off    : block-if-contains-last-replica — the chart default / daily posture.
# status : current live value, the chart-default posture, and every volume's
#          robustness (so you never start a roll blind).
#
# The setting is a Longhorn manager-owned CR; the chart's values keep the
# DEFAULT, so window-on state is a deliberate live drift that Fleet will not
# reconcile — but flip it back when the roll ends (this script exists so you
# actually do).
#
# Usage: CLUSTER_KUBECONFIG=<guest kubeconfig> ./lh-roll-mode.sh on|off|status
set -uo pipefail

KC=${CLUSTER_KUBECONFIG:?CLUSTER_KUBECONFIG=<guest kubeconfig> required}
export KUBECONFIG="$KC"
K="kubectl -n longhorn-system"

ROLL_VALUE="block-for-eviction-if-contains-last-replica"
DEFAULT_VALUE="block-if-contains-last-replica"

current=$($K get settings.longhorn.io node-drain-policy -o jsonpath={.value})
echo "node-drain-policy: $current"

case "${1:?on|off|status}" in
  status)
    $K get volumes.longhorn.io -o custom-columns=VOLUME:.metadata.name,STATE:.status.state,ROB:.status.robustness,REPLICAS:.spec.numberOfReplicas
    [ "$current" = "$ROLL_VALUE" ] && echo "ROLL WINDOW: ON (do not forget: lh-roll-mode.sh off when done)"
    [ "$current" = "$DEFAULT_VALUE" ] && echo "ROLL WINDOW: off (daily posture)"
    ;;
  on)
    BAD=$($K get volumes.longhorn.io -o json | python3 -c "
import json, sys
bad = [v['metadata']['name'] for v in json.load(sys.stdin)['items']
       if v.get('status', {}).get('robustness') in ('faulted',)]
print(len(bad))")
    if [ "$BAD" != "0" ]; then
      echo "REFUSING: $BAD volume(s) faulted — resolve before opening a roll window"
      exit 1
    fi
    $K patch settings.longhorn.io node-drain-policy --type merge -p "{\"value\":\"$ROLL_VALUE\"}" >/dev/null
    echo "ROLL WINDOW ON: node-drain-policy -> $ROLL_VALUE"
    echo "Vendor will now evict last-replicas off doomed nodes before allowing drains."
    echo "Close the window after the roll: $0 off"
    ;;
  off)
    $K patch settings.longhorn.io node-drain-policy --type merge -p "{\"value\":\"$DEFAULT_VALUE\"}" >/dev/null
    echo "ROLL WINDOW OFF: node-drain-policy -> $DEFAULT_VALUE (daily posture)"
    ;;
  *) echo "usage: $0 on|off|status" ; exit 1 ;;
esac
