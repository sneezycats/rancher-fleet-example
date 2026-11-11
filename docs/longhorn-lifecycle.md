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

## The documented standard we operate inside

Longhorn is engineered to keep volume data safe through node maintenance,
node loss, and replica loss. The premise of this document is that its
documented procedures are sufficient when executed as written: our job is to
know them, honor their preconditions, and operate inside them — not to
supervise the storage layer from outside. Upstream references (Longhorn v1.13
documentation):

- **Node Maintenance and Kubernetes Upgrade Guide** (`maintenance/`) —
  cordon → drain → maintain → uncordon, plus the in-place upgrade rules: drain
  before touching a node, a drain `--timeout` large enough for replica rebuilds
  to finish between nodes (or `0`), and *"the number of nodes upgrading at a
  time should be smaller than the number of Longhorn replicas for each
  volume"*, so a running volume always keeps at least one healthy replica.
- **Graceful Node Removal** (`nodes-and-volumes/nodes/`) — the handshake for a
  node that is *not* coming back: disable scheduling **and request eviction**
  on the Longhorn node, then wait until every disk reports
  `scheduledReplicas: 0` before the node is destroyed. Its stated reason:
  Kubernetes does not notify the CSI layer to migrate replicas before a node is
  destroyed, so removing a node without this step loses whatever replicas were
  on it.
- **Settings reference** (`references/settings.md`) — `node-drain-policy`,
  `replica-replenishment-wait-interval`, `replica-soft-anti-affinity`.

Those procedures map onto the two ways a Rancher/CAPI pool changes a machine,
and which of them happens automatically depends on one setting — the vendor
`node-drain-policy` — not on the type of change:

| Change | Node comes back? | Documented procedure | Who performs it |
| --- | --- | --- | --- |
| OS/runtime maintenance, Kubernetes version upgrade | yes | cordon, drain, maintain, uncordon | Rancher/CAPI does this |
| Machine replacement (image hop, pool resize, crash) | **no** | graceful node removal: evict the data, then destroy | **nobody under the shipped drain policy**; the vendor itself during the drain if the policy is set to a `block-for-eviction` variant for the window (step 1b); or you, per node (step 1c) |

The drain and the storage layer are **not** independent: the drain is already
coordinated with Longhorn through `node-drain-policy`, and the shipped default
`block-if-contains-last-replica` is a real brake — Longhorn refuses to let a
drain complete while that node holds a volume's last live replica. What it does
*not* do is evict. On a healthy 3-replica volume no node holds "the last live
replica", so the condition never fires and the drain proceeds and the replica
dies with the machine. That is the policy working as specified, not a hole.

Two of the five documented policies close it, and they are the ones a
replacement-style roll wants: `block-for-eviction-if-contains-last-replica` and
`block-for-eviction`. Per the vendor, each "takes action to automatically evict
replicas from the node" and blocks drain completion "until eviction is
complete" — the data moves *before* the machine goes, with no controller and no
external orchestration. The vendor scopes them to planned maintenance for two
reasons worth honoring: they "trigger on cordon, not on drain", so a casual
cordon rebuilds replicas for nothing, and "the drain operation is significantly
slower... Drain timeout must be adjusted as appropriate for the amount of data
that will move". Hence step 1b: open the window, roll, close the window. The
manual handshake is still worth knowing, and `scripts/lh-graceful-remove.sh`
performs it and blocks until the node holds no replicas — that is the documented
completion criterion, and it is the only option when the pool is being resized
down rather than replaced.

**The precondition people trip on: eviction needs a destination.** An evicted
replica is rebuilt elsewhere *before* its source is removed, so some node must
be allowed to accept a second replica of that volume. With
`replica-soft-anti-affinity: false` — this repo's Longhorn bundle, where
replicas of one volume never share a node — and `numberOfReplicas` equal to the
worker count, every other node already holds a replica and there is nowhere to
put the copy. Longhorn refuses to do something unsafe rather than doing it: the
request is accepted, the eviction controller then reports
`No disk candidates for evicting replica`, and the replica count sits unchanged
forever. That is the documented troubleshooting case, and it is a capacity
statement, not a fault. The fix is a shape decision: **size the pool above the
replica count** (four workers for three replicas is the smallest shape where
every volume has somewhere to go), or accept temporary co-location by enabling
`replica-soft-anti-affinity` for the maintenance window and restoring it after.

Measured contrast, same three volumes (3 replicas across 3 workers) with live
writers throughout:

| Method | Robustness during | Notes |
| --- | --- | --- |
| Replacement with no eviction requested | `degraded`; one volume ran on a single replica | recovered on its own after the replenishment interval |
| Documented eviction handshake (soft anti-affinity on) | **`healthy` throughout** | node reached 0 replicas; no single-copy window |

Why the first row behaved that way, checked afterwards rather than guessed: the
cluster was running `node-drain-policy = block-if-contains-last-replica`, the
chart default, verified on the live cluster after the roll. With three healthy
replicas per volume that policy has nothing to protect and stays silent.

Both preserved data. Only the second is predictable, and it is the documented
one — which is the standard this repo holds itself to.

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

**1c. Replacement-style changes only** (image hop, pool resize): the roll
destroys machines, so move the data off each node before its machine dies.
Run it per node and let it block until the node is empty — that is the
documented handshake, and it is what makes the roll predictable:

    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/lh-graceful-remove.sh <node>

Needs either more nodes than replicas per volume or
`replica-soft-anti-affinity: true` for the window (see the precondition
above). It refuses to start when no destination exists instead of hanging.

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
The absence of a pause switch on the deployment object is not the absence of a
brake. The supported brake is the drain itself: a `block-for-eviction` drain
policy holds the roll at the drain step until the vendor has relocated the data,
which is exactly the semantics an automated upgrade pipeline wants (step 1b).

> `spec.paused: true` on the provisioner's `MachineDeployment` is accepted
> and then reverted: Rancher re-applies its own copy of the machine spec on
> its next reconcile, and the measured result was the roll continuing
> through all remaining nodes. There is no supported way to pause an
> in-flight machine replacement from the deployment object, so pacing comes
> from preparation rather than obstruction: evict the data off the node the
> roll is about to retire, wait for `scheduledReplicas: 0`, and by the time
> Rancher's drain and delete arrive there is nothing left on that machine to
> destroy. `scripts/lh-graceful-remove.sh` is that wait.

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
- A replacement roll can run at that floor: each delete lands inside the
  previous node's replenishment window, so a volume may sit on a single
  healthy copy for a while. That is the invariant Longhorn's own upgrade
  guidance protects — at least one healthy replica at a time — so the roll
  was safe, not lucky. To keep the roll *above* the floor, evict per node
  (`scripts/lh-graceful-remove.sh`) rather than shortening the timer: the
  interval exists to reuse existing replica data instead of rebuilding, so
  lowering it trades a safety margin for speed.
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

Note the catch in that ordering: `scripts/lh-residue-cleanup.sh` refuses to
run unless every volume is already healthy and attached, so it cannot clean
the residue that is itself holding a volume degraded. In that state apply the
three steps from the residue section by hand, then use the script for the
rest of the sweep.

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
