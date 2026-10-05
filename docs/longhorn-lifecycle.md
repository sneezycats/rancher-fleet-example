# Longhorn lifecycle: procedure and settings for safe node replacement

The operating contract for clusters built by the cluster template with
Longhorn volumes aboard: what makes replacement safe, what to run before and
after a change, and the settings that carry the guarantees.

*Provenance: validated in-lab on Rancher 2.14.3 + Longhorn 1.11.2 — a full
template-driven six-node roll (3 control-plane + 3 workers, serialized,
6.1 → 6.2 image hop) completed with zero stranded nodes and zero manual
intervention; the drain/replacement contract with volume data aboard has
held across the lab's rolling-upgrade rounds (>= 3 replicas, >= 3 workers,
data intact). Run the data-layer verification below on your first cluster —
it is the standard practice, not an optional extra.*

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
  data serves from the surviving replicas the whole time.
- Not normal: `state=detached`, `robustness=faulted`, or a volume stuck
  degraded after the roll passes it. Stop and investigate before proceeding.

**4. Post-flight** — the verification round proves data continuity:

    CLUSTER_KUBECONFIG=<guest-kubeconfig> scripts/verify.sh

Then check for residue — these two lists should match the current worker
set exactly, with zero stopped replicas:

    kubectl -n longhorn-system get nodes.longhorn.io
    kubectl -n longhorn-system get replicas.longhorn.io --no-headers | grep -c stopped   # expect 0

## What you should NOT need

No extra controller is required for data safety on this path — Longhorn's
own settings (contract item 4) plus drain-first deletion carried full
rolling upgrades in validation. The optional longhorn-capi-controller adds
value only for unattended pipelines and crash-path automation; its README
carries the "when you don't need this controller" decision table. Deploy it
deliberately or not at all.

## Shrinks and rollbacks

`git revert` the change; the roll unwinds the same way (drain-first). Etcd
shrink to 1 is not supported — reduce control-plane counts only knowingly.
Worker scale-down drains before delete; keep `drainBeforeDelete` on.
