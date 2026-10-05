# Longhorn lifecycle: procedure and settings for safe node replacement

The operating contract for clusters built by the cluster template with
Longhorn volumes aboard: what makes replacement safe, what to run before and
after a change, and the settings that carry the guarantees.

*Provenance (2026-10-05, Rancher 2.14.3 + Longhorn 1.11.2, in-lab): full
serial rolls of all six machines with volume data aboard, verified by
created-at identity, uninterrupted writer counters, and rebuilt 3/3 replica
placement on the new workers. Two discriminating runs in one day: with the
optional lhcc controller present (6.1 -> 6.2) and with zero controller
present (6.2 -> 6.1). Data safety was vendor-native in BOTH runs - zero data
loss, zero stuck-pod wedges, no manual intervention. One real gap: dead
nodes' Longhorn node CRs and replicas do NOT self-clean (see the residue
step below).*

## The contract (what makes replacement safe)

1. **Replica shape**: >= 3 replicas across >= 3 worker nodes. Every volume
   must have at least two healthy replicas on nodes OTHER than the one being
   replaced. The chart defaults set this
   (`persistence.defaultClassReplicaCount: 3`,
   `defaultSettings.defaultReplicaCount: "3"`) — do not run production
   below it.
2. **Drain-first deletion**: the workers pool carries
   `drainBeforeDelete: true` with a bounded `drainBeforeDeleteTimeout`
   (durations in canonical Go form). Machine deletion never skips the drain.
3. **Serial rolls**: CAPI replaces machines one at a time. Never shrink a
   pool by more than one node while volumes are rebuilding; never force
   parallel machine deletes.
4. **Vendor gates stay on (chart defaults — leave them)**:

       node-drain-policy: block-if-contains-last-replica
       auto-delete-pod-when-volume-detached-unexpectedly: "true"
       auto-salvage: "true"

   The drain policy makes the drain itself refuse to evict a node holding a
   volume's last live replica. `auto-delete-pod-when-volume-detached-
   unexpectedly` clears pods that would otherwise wedge machine deletion
   after an unexpected detach.

## The procedure (image/version/values changes with volumes aboard)

**0. Pre-flight** — all volumes `robustness=healthy`, all replicas
scheduled, and the baseline captured:

    kubectl -n longhorn-system get volumes.longhorn.io
    kubectl -n longhorn-system get replicas.longhorn.io
    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/baseline.sh

**1. Make the change** (`imageName` / `kubernetesVersion` / pool size) in
`cluster-templates/chart/values.yaml` — one component per commit — and push.
The full pipeline behavior is in UPGRADE.md.

**2. What the roll looks like**: Fleet replaces machines serially — new node
joins, Longhorn discovers it, old node drains (workload pods reschedule, the
volume detaches and re-attaches, replicas rebuild to 3/3), old machine is
deleted. Expect node Ready ~10 min per hop.

**3. What is normal during the roll** vs what is not:

- Normal: volumes briefly `robustness=degraded` while a replica rebuilds —
  data serves from the surviving replicas the whole time. Both observed
  rolls spent well under ten minutes per volume in degraded-and-serving.
- Not normal: `state=detached`, `robustness=faulted`, or a volume stuck
  degraded after the roll passes it. Stop and investigate before proceeding.

**4. Post-flight verification round** — proves data continuity:

    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/verify.sh

Expect the verify's robustness check to pass once rebuilds complete (run it
after the last volume returns to healthy, a few minutes after the machines
settle). Identity checks (`created_at`, counters, CONTINUITY) are valid even
mid-rebuild.

**5. Residue cleanup (required step)** — the roll leaves the deleted workers
behind in Longhorn: their `nodes.longhorn.io` CRs and pinned replicas
persist indefinitely (observed 25+ minutes, no self-clean; the Longhorn UI
shows them as stranded nodes). Longhorn's admission webhook enforces an
order for the fix — it refuses to delete a node CR while any replica is
still pinned to it ("N replica ... running on it"), regardless of replica
state:

    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/lh-residue-cleanup.sh

The script (1) refuses to run unless every volume is healthy and attached,
(2) sets `allowScheduling=false` on each stranded node CR, (3) deletes the
replicas pinned to it by `spec.nodeID` (note: these replicas carry
`status.state` empty/None on current releases — filter by nodeID, not by
state), (4) deletes the node CR, retrying past the webhook's informer-cache
lag. End state to verify: exactly the current workers in
`nodes.longhorn.io`, zero replicas remaining on deleted nodes.

## What you should NOT need

Data safety on this path needs NO controller — proven with and without one
in the same session (both hops: continuous counters, no wedge, rebuilt 3/3,
zero manual data intervention). The one real residual gap is dead-node
residue cleanup, which the vendor documents as a manual procedure (codified
above). The optional longhorn-capi-controller automates exactly that
cleanup; its README carries the when-you-do-not-need-it decision table.
Deploy it for unattended pipelines where a post-roll script step is
unwanted; on an attended path, run the script as part of the post-flight.

## Shrinks and rollbacks

`git revert` the change; the roll unwinds the same way (drain-first). Etcd
shrink to 1 is not supported — reduce control-plane counts only knowingly.
Worker scale-down drains before delete; keep `drainBeforeDelete` on.
