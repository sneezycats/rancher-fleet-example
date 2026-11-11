# Longhorn lifecycle: procedure and settings for safe node replacement

The operating contract for clusters built by the cluster template with
Longhorn volumes aboard: what makes replacement safe, what to run before and
after a change, and the settings that carry the guarantees.

*Provenance: the roll procedure below was exercised end-to-end — full
serial rolls of every machine with volume data aboard, verified by
created-at identity, uninterrupted writer counters, and rebuilt 3/3
replica placement — across three regimes: with the optional lhcc
controller present, with zero controller, and with the vendor eviction
policy enabled for the maintenance window. Data safety was vendor-native
in all regimes. One real gap: dead nodes' node CRs and replicas do NOT
self-clean (see the residue step below).*

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

**1b. Open the roll window** (recommended for automated upgrade pipelines):
the vendor can evict last-replicas off doomed nodes itself — flip the drain
policy for the window and flip it back after (SUSE guidance: not for
permanent use; it triggers on ANY cordon):

    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/lh-roll-mode.sh on   # before
    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/lh-roll-mode.sh off  # after

Validated: with the window open, a single-replica volume's last replica was
rebuilt onto a surviving worker before its node drained — the volume stayed
attached and healthy throughout (the default policy would have blocked that
drain until the timeout). Healthy 3/3 volumes behaved exactly as before: the
policy only moves replicas that lack a healthy counterpart.

**2. What the roll looks like**: Fleet replaces machines serially — new node
joins, Longhorn discovers it, old node drains (workload pods reschedule, the
volume detaches and re-attaches, replicas rebuild to 3/3), old machine is
deleted. Expect node Ready ~10 min per hop.

> **You cannot hold the roll from outside.** Setting
> `spec.paused: true` on the provisioner's `MachineDeployment` is accepted
> and then reverted: Rancher re-applies its own copy of the machine spec on
> its next reconcile, and the measured result was the roll continuing
> through all remaining nodes. There is no supported in-band brake on an
> in-flight machine replacement, so the control that matters is the one you
> set *before* the roll — replica count and replenishment interval above.

**3. What is normal during the roll** vs what is not:

- Normal: volumes `robustness=degraded` while a replica rebuilds — data
  serves from the surviving replicas the whole time. How long degraded
  lasts is a setting, not a race: Longhorn delays scheduling a
  replacement replica for `replica-replenishment-wait-interval`
  (default **600s**) after a node is lost, so it can reuse a replica on
  a node that merely restarted instead of rebuilding one. Expect
  roughly that interval per lost node, and read the engine log for
  `RequireNewReplica ... Replica replenishment is delayed until <ts>`
  to see the exact deadline.
- The consequence for pool rolls: when a pool replaces **every** node
  one at a time and each delete lands inside another node's replenishment
  window, a volume can lose a replica per node before any rebuild
  starts. With `numberOfReplicas` equal to the pool size the worst case
  is one healthy copy. Raise the replica count above the pool size, or
  lower the interval, so the roll cannot outrun repair.
- Not normal: `state=detached`, `robustness=faulted`, or a volume stuck
  degraded after the roll passes it. Stop and investigate before proceeding.

**4. Post-flight verification round** — proves data continuity:

    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/verify.sh

Do not judge the round while a replenishment window is still open — the
robustness checks will fail on volumes that are simply waiting for their
timer, which is a false negative, not an incident. Identity checks
(`created_at`, counters, `CONTINUITY`) are valid immediately and are the
part that actually proves data survived; run `verify.sh` once for that and
again after the last replenishment deadline passes for the robustness
verdict.

If a volume still reads `degraded` with a full set of `running` replicas,
check for a stale replica CR pinned to a deleted node: it is counted
against the desired count, so the volume can never report `healthy` until
the residue below is cleaned. Clean first, then re-run verify.

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

Data safety on this path needs NO controller — proven across three rolls
(with the optional controller, without it, and with the vendor eviction
policy for the window: continuous counters, no wedge, rebuilt 3/3, zero
manual data intervention each time). The vendor block-for-eviction-if-
contains-last-replica policy (1.11+) natively covers the pre-drain replica
eviction the optional controller implemented; flip it for the window per
step 1b. The one real residual gap is dead-node
residue cleanup, which the vendor documents as a manual procedure (codified
above). The optional longhorn-capi-controller automates exactly that
cleanup; its README carries the when-you-do-not-need-it decision table.
Deploy it for unattended pipelines where a post-roll script step is
unwanted; on an attended path, run the script as part of the post-flight.

## Shrinks and rollbacks

`git revert` the change; the roll unwinds the same way (drain-first). Etcd
shrink to 1 is not supported — reduce control-plane counts only knowingly.
Worker scale-down drains before delete; keep `drainBeforeDelete` on.
