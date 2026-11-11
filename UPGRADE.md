# UPGRADE.md — changing a running cluster through this repo

The change-day runbook for the cluster template and its component bundles:
what to touch, what happens after you push, what to check, and the failure
modes that are invisible in the UI. Written for someone returning to this
repo after months of other work — every command is copy-pasteable with
placeholders.

*Provenance: mechanics validated on Rancher 2.14.x-era installs (RKE2 1.33
line, Harvester-provisioned clusters). Field names move between Rancher
versions — re-validate against yours.*

## The 30-second version

- Every change is a `values.yaml` (or bundle `fleet.yaml`) edit → commit →
  push. No UI clicks, no imperative kubectl apply. Git is the control plane.
- Some edits scale, some roll one pool, some roll the cluster — § "What each
  edit does". The distinction that bites: a pool's `imageName` rolls that
  pool; the top-level `imageName` rolls everything.
- Editing the chart's `templates/`? Run `tests/render/render-check.sh`
  before you push: a rendered byte that moves is a machine that gets
  replaced.
- Push → Fleet polls (~15 s) → agent runs `helm upgrade` with server-side
  apply → rendered CRs update → CAPI scales/rolls machines → nodes join.
- If a bundle sits at **0/1 WaitApplied** for more than a couple of minutes,
  the apply is FAILING, not pending — and the UI will not tell you why.
  The error is only in the fleet-agent logs (§ Silent failure).
- `cluster-templates/chart/fleet.yaml` with `helm: takeOwnership: true` is
  LOAD-BEARING. Do not delete it (§ Field ownership).

## What each edit does (scale vs roll vs replace)

| Edit (`cluster-templates/chart/values.yaml`) | Mechanism | Blast radius |
|---|---|---|
| `nodepools[].quantity` | MachineDeployment scale | none — no existing machine touched |
| `nodepools[].vcpu` / `memory` / `disk` | HarvesterConfig change → machine roll | every machine in the pool, one at a time |
| `kubernetesVersion` | full roll of ALL machines | cluster-wide |
| `imageName` (top level — pools inherit) | every pool's machine config changes → every pool rolls | cluster-wide |
| `nodepools[].imageName` (pool override) | that pool's machine config alone → only that pool rolls | **one pool**; other pools byte-identical, no roll |
| `machineGlobalConfig` / `chartValues` | config-hash change → roll | cluster-wide |
| `name:` (cluster name) | NOT a rename — Fleet garbage-collects the old Cluster CR (teardown) and builds a twin | destructive; see below |

Two edits that look identical in `values.yaml` sit at opposite ends of that
table: changing the top-level `imageName` rolls the whole cluster, changing a
pool's `imageName` rolls that pool and nothing else. The axis is *which
pool's rendered machine config changes* — see § Per-pool image hops.

Rolling replacement = new VM + node join BEFORE the old machine is deleted;
the data layer (Longhorn) rebuilds replicas onto the new nodes — run the
verification round after (see `docs/promotion-model.md`).

## Per-pool image hops (day-2 OS patching)

The golden image is the patch mechanism (immutable OS root — see
`docs/image-bake.md`), so on day 2 the question is not *whether* to change an
image but *which pool pays for it*. A pool's `imageName` is a scoped knob:
control plane can move to a new image generation while the workers hold on
the old one, or the other way round, in either order, one pool per commit.

**The mechanism, pool by pool.** Each pool's `HarvesterConfig` is a source
object; Rancher clones it into an `rke-machine.cattle.io/v1
HarvesterMachineTemplate` named `<cluster>-<pool>-<hash>` (label
`rke.cattle.io/machine-template-hash`) and points *that pool's*
MachineDeployment at the clone. Change one pool's machine config and Rancher
clones a new template under a new hash and repoints only that pool's
MachineDeployment; CAPI then rolls only that pool's machines. Rancher's own
words for the underlying rule (Rancher v2.14, *Configuring Native CAPI
Infrastructure Providers to Provision RKE2 Clusters*, § "Changing machine
templates"): machine templates "are usually immutable … This causes all of
the machines in that pool to be recreated with the new configuration." The
node-driver path writes that new template for you.

**The shared value goes inert once every pool pins one.** Because resolution
happens per pool, bumping the top-level image while each pool sets its own
`imageName` changes nobody's machine config: no new clone, no revision bump, no
roll — confirmed, a shared-image bump with both pools pinned moved zero
machines. The pools that still *inherit* (its `imageName` omitted or `""`) are
precisely the ones that move. Read the top-level field as "what new clusters
and un-pinned pools get", not as a cluster-wide kill switch.

**The control plane is a pool.** On Rancher 2.14.x in this provisioning path
the control-plane pool is also driven by a MachineDeployment — there is no
separate control plane machine template to fight with (the `RKEControlPlane`
object carries plans/etcd; its `machineTemplate` is empty). So the same
per-pool hop applies to it, with the consequences below. Re-check this on a
Rancher version other than 2.14.x before relying on it: it is an observation
about how Rancher builds the object graph, not a documented contract.

**What a pool hop actually costs:**

- **Workers.** The gentle direction: `drainBeforeDelete: true` + bounded
  `drainBeforeDeleteTimeout` are already set in this chart, so each worker
  drains, leaves, and is replaced by a VM built from the new image. Measured
  on a worker pool in the reference lab via a root-disk `disk` bump — the
  same machine-config path an image hop takes — the pool round landed inside
  the ~10-minute per-machine window the pipeline section above documents.
  Surge-style: the replacement joins before the old VM is deleted, so
  capacity dips never stack.
- **Control plane / etcd.** Same mechanism, sharper edges. The roll surges an
  extra control-plane VM, so on a 3-node CP pool the cluster runs 4 CP+etcd
  members transiently: that is one extra VM of CPU/RAM/disk headroom on the
  hypervisor, plus etcd member join/remove churn. CP pools are never drained
  (Rancher convention — see Rancher v2.14, *Nodes and Machine Pools*), which
  is fine for pure CP nodes and *not* fine if the storage layer puts data on
  them (next bullet). Take an etcd snapshot before the hop.
- **The data layer.** A replaced VM means a replaced root disk. If the
  distributed storage schedules replicas on control-plane nodes, a CP hop
  destroys those replicas — with `replicaSoftAntiAffinity: false` (this
  repo's Longhorn bundle) volumes go degraded-but-honest rather than
  silently co-locating. Check before the hop, don't assume:
  `kubectl -n longhorn-system get nodes.longhorn.io -o
  custom-columns=NAME:.metadata.name,SCHED:.spec.allowScheduling,DISKS:.status.diskStatus`
  and see whether replicas are running on the CP nodes.
- **What a control-plane hop looks like on the wire** (observed on a scratch
  3-CP / 3-worker cluster, Rancher 2.14.x): machines are replaced one at a
  time; the surge CP VM joins and its etcd member syncs before the old VM is
  deleted, so etcd briefly runs 4 members, all `1/1 Running`, no restarts; the
  provisioning cluster's `Ready` condition never went false; the full 3-node
  round took ~14 minutes (~4-5 min per machine). While the CP pool rolled, the
  workers pool sat at its original revision on its original template — the
  blast-radius claim, observed rather than inferred. The opposite direction
  behaved the same way, and `drainBeforeDelete` was visible as a node parked
  at `Ready,SchedulingDisabled` before its VM went away.
- **Nobody orders pools for you.** Rancher sequences *Kubernetes version*
  upgrades via `spec.rkeConfig.upgradeStrategy` (control-plane concurrency,
  worker concurrency, per-role drain options — Rancher v2.14, *RKE2 Cluster
  Configuration Reference*, § "Upgrade Strategy"; note this chart does not
  expose that block yet). An image hop is not governed by it: two pools
  changed in one commit means two concurrent rolls and no attribution.
  Hence: **one pool per commit**, workers and CP as separate rounds, each
  with its own baseline/verify pair.

**Verify the OS, not the image name.** Two independent reasons, and they point
the same way. First, a `displayName` is free text someone typed when
registering the image; the OS does not know about it. Second, the product
names themselves are not stable signals: SLE Micro (also spelled SL-Micro, and
renamed more than once) is built from SUSE Linux Enterprise Linux and one can
reasonably call it a variant of it, so a Micro-branded golden image can report
`SUSE Linux Enterprise Server` in `osImage` without anything being mislabelled.
Observed on a real hop: the replacement node reported `SUSE Linux Enterprise
Server 16.0` on kernel 6.12 where the image it replaced reported `SUSE Linux
Micro 6.1` on kernel 6.4 — that may be a base-image change in the bake, a
rebranding in os-release, or both, and the node alone cannot tell you which.
Ask the nodes, and treat the *kernel* as the harder signal:

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion'
```

and inside one replaced VM: `grep -E '^(NAME|VERSION)=' /etc/os-release; uname -r`.
If the string disagrees with the image name and it matters, settle it at the
source: read `os-release` inside the qcow before it is baked into a pool
(`guestfish --ro -a image.qcow -i cat /etc/os-release`) — the image is the
authority, the displayName is a label, and the node string is only a report.
Whatever the names say, write down the *kernel* per generation: that is the
thing a skew policy actually has to cover.

**Skew is now yours to own.** `kubernetesVersion` is a single cluster-wide
field, so the Kubernetes version-skew policy is untouched by per-pool
images. What changes is that pools can sit on different OS generations —
different kernel, different baked-in units, different CVE coverage — and no
controller anywhere enforces a limit on that. Write the window down and hold
it (common shape: a pool may lead or lag by at most one image generation,
and no skew may survive a Kubernetes version bump). Note also that the
skew is only *visible* in git; `helm install`/`upgrade` prints the resolved
image per pool, and warns when any pool pins an image other than the cluster
default, so `helm get notes <release>` says which generation each pool is on.

**Rollback is another roll.** `git revert` the hop commit and the pool rolls
back onto the previous image — which means the previous image must still
exist on the Harvester *and in the pool's VM namespace*. Keep the superseded
VMImage registered until the round is accepted. Also expect the superseded
`HarvesterMachineTemplate` to linger after the roll (Rancher does not prune
it): a second template per pool is normal bookkeeping, not drift.

Longhorn itself is a separate bundle: `fleet/bundles/longhorn/fleet.yaml`
carries the chart pin AND the values — upgrading Longhorn means editing the
one `version:` field there (in-place helm upgrade, no machine roll, data
plane stays up), always as its own commit with its own verification round.

### Node-count specifics

- **Workers**: the routine knob. Scale-up joins; scale-down DRAINS first
  (`drainBeforeDelete: true` + bounded `drainBeforeDeleteTimeout` — already
  set in this chart), then deletes the VM.
- **Control plane / etcd**: scale-UP 1→3 validated (etcd member join). Etcd
  scale-DOWN to 1 is not supported; 3→2 only knowingly, with etcd alarms
  watched. Control-plane pools are never drained (Rancher convention).
- During a scale-up the EXISTING control-plane node may briefly show
  "waiting for plan to be applied" — plan re-delivery after the spec change;
  it self-heals. Not a wedge.

### Renaming a cluster is not an edit

`name:` is the Cluster CR name. Changing it does not rename anything: the
new render no longer contains the old Cluster CR, so Fleet garbage-collects
it — that is a cluster teardown, machines and all — while provisioning a
twin under the new name. To rename for real: build the new cluster from the
new values, verify it, migrate the data layer, then remove the old one
deliberately.

## Version upgrade ordering (`upgradeStrategy`)

`upgradeStrategy` orders **Kubernetes version** upgrades. It does **not** govern
image hops: an image hop changes a pool's machine config, Rancher re-clones that
pool's machine template, and CAPI rolls that pool through its MachineDeployment.
`upgradeStrategy` never enters that path — measured on Rancher 2.14.3, patching
the block onto a live 3-CP/3-worker cluster moved zero machines (no new template,
no revision bump, identical node names).

The chart ships it explicitly:

```yaml
upgradeStrategy:
  controlPlaneConcurrency: "1"
  workerConcurrency: "1"
```

Those values encode what Rancher does when the field is absent: one node at a
time **per role**, so a control-plane node and a worker node are normally in
flight simultaneously (two nodes total on a 3+3 cluster). Shipping the number
does not change behaviour; it stops the behaviour from being an observation
nobody recorded. Concurrency takes a count or a percentage string (`"10%"`) if a
large pool needs a wider rollout.

**Drain options are deliberately not shipped.** Rancher's own default is
`enabled: false` for both roles, and emitting false-valued booleans into this CR
has produced permanent "Modified" churn elsewhere (`machinePools`), because
Rancher's normalizer strips them — omitted means false, so leaving them out is
the safe shape. Add `controlPlaneDrainOptions` / `workerDrainOptions` only when
you actually want draining, and know they are a different knob from
`nodepools[].drainBeforeDelete`: that one drains on machine **replacement**
(image hops, scaling), this one drains on **version** plans.

Two consequences of the default, worth deciding about before a version bump:

- With draining off, pods are not evicted before the kubelet restarts. For
  Longhorn-attached or otherwise stateful workloads, that is a decision, not an
  accident waiting to happen.
- On **rollback** to a prior version the strategy is ignored entirely — worker
  nodes are not cordoned or drained. The emergency path has no drain either.

Per-pool image hops exist so a control plane can be patched while an
uncooperative worker pool waits. The render gate therefore asserts that
`upgradeStrategy` stays confined to the Cluster CR: were it ever to reach a
pool's machine config it would roll every pool that template targets.

## The pipeline, with expected timings

```
git push
  └─▶ GitRepo poll: status.commit follows repo HEAD          (~15 s)
       └─▶ bundle + bundledeployment deploymentID change
            └─▶ fleet-agent: "Upgrading helm release" (SSA)    (~1 min)
                 └─▶ provisioning Cluster CR updated
                      └─▶ CAPI MachineDeployments scale/roll
                           └─▶ VMs Running on the hypervisor   (~3 min)
                                └─▶ node joined + Ready         (~9-10 min)
                                     └─▶ gitrepo/bundle Ready 1/1
```

## The silent failure (the one that wastes the most time)

Symptom: the bundle shows `0/1 WaitApplied`, the GitRepo condition says
`Current`, the UI shows a pending diff — and nothing changes for hours.
The agent-side apply is ERRORING on every retry (~every 15-20 min), and the
Rancher UI does not surface the error anywhere.

Where the truth is:

    kubectl -n cattle-fleet-local-system logs deploy/fleet-agent --since=1h | grep -i conflict

Fleet applies are all-or-nothing per bundle: ONE conflicting field blocks the
ENTIRE change. A conflict on a field you never touched (e.g. a drain timeout)
will silently freeze your node-count change.

## Field ownership: two traps, one fix

Rancher's own controllers/UI write fields on the same Cluster CR your chart
renders — under server-side apply they become FIELD OWNERS:

1. **Ownership**: the `rancher` field manager was observed owning
   `drainBeforeDeleteTimeout`. Fleet setting a different value on a field
   another manager owns = conflict = the whole bundle blocked (§ above).
2. **String normalization**: Rancher round-trips duration fields through
   Go's `time.Duration` — `1200s` is rewritten `20m0s`. Same duration,
   different string, so the chart's value reads as a change Fleet is not
   allowed to make — on every apply, forever.

The fix — both already in this repo, keep them:

- `cluster-templates/chart/fleet.yaml`:

      helm:
        takeOwnership: true      # agent force-applies; git stays authoritative

- Durations in values written in canonical Go form (`20m0s`, `1h0m0s` —
  never `1200s`, `3600s`).

If a NEW conflict appears after a Rancher upgrade (on some other field), the
takeOwnership force-apply already covers it; use the error text plus the
managed-fields view to understand who owns what:

    kubectl -n fleet-default get clusters.provisioning.cattle.io <cluster> -o json --show-managed-fields

## The procedure

**0. Pre-flight** (irreversible steps gate here):

- [ ] Which row of the change table is this — scale, roll, or replace?
- [ ] Editing anything under `cluster-templates/chart/templates/` (not just
      values)? Run `tests/render/render-check.sh`. A render delta you did not
      intend is a roll you did not intend, on every cluster the bundle
      targets, with no signal in the PR.
- [ ] Touching `kubernetesVersion`? Check the SUSE Rancher↔Harvester↔RKE2
      support matrix first.
- [ ] Touching `imageName` — top level (rolls every pool that still *inherits*
      it; a pool with its own override does not move) or a pool override (rolls
      that pool only)? Either way the VM image must exist on the
      target Harvester AND in the same namespace the VMs land in (the node
      driver resolves images in the VM namespace — an image in the wrong
      namespace churns "virtualmachineimages ... not found" with zero VMs
      created).
- [ ] Pool image hop on the control plane? etcd snapshot taken, hypervisor
      headroom for the extra surged CP VM, replicas-on-CP checked, previous
      image still registered (§ Per-pool image hops). One pool per commit.
- [ ] The storage class the VMs land on exists and is the intended one (a
      missing SC surfaces later as machine-provision `BackoffLimitExceeded`
      churn that self-heals once applied).
- [ ] `git grep takeOwnership cluster-templates/chart/fleet.yaml` — still
      there?
- [ ] One component per commit: cluster change OR Longhorn change, never
      both (`docs/promotion-model.md`).

**1. Make the change** on the lowest environment branch, commit, push. One
logical change per commit.

**2. Confirm Fleet fetched it** — compare against the repo:

    git ls-remote <repo-url> <branch>
    kubectl -n fleet-local get gitrepo <gitrepo-name> -o jsonpath={.status.commit}

**3. Confirm the agent deployed it** — find the bundledeployment (its
namespace is the target-cluster envelope, `cluster-<workspace>-<cluster>-<hash>`):

    kubectl get bundledeployments.fleet.cattle.io -A | grep <bundle-name>
    kubectl -n <envelope-ns> get bundledeployment <bundle-name> -o jsonpath={.spec.deploymentID}
    # conditions should show Installed / Deployed (, Ready) with no conflict text

**4. Confirm the live Cluster CR took the spec** (FULL resource name —
`kubectl get cluster` resolves to the CAPI Cluster, a different object with
no `rkeConfig`):

    kubectl -n fleet-default get clusters.provisioning.cattle.io <cluster> -o jsonpath={.spec.rkeConfig.machinePools[*].quantity}

**5. Watch the machines:**

    kubectl -n fleet-default get machinedeployments.cluster.x-k8s.io
    kubectl -n fleet-default get machines.cluster.x-k8s.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,NODE:.status.nodeRef.name
    # VM side: kubectl -n <vm-namespace> get vm   (Harvester kubeconfig)

`nodeRef.name` empty = node not registered yet; machines created but no node
= still bootstrapping (image pulls dominate; ~10 min total is normal).

**6. Post-flight:** gitrepo Ready 1/1; run the data-layer verification round
(`scripts/baseline.sh` before, `scripts/verify.sh` after); the commit is now
the cluster's description of record.

## Rollback

`git revert` the change commit on that environment branch and push. Fleet
converges to the previous render; rolls and scales unwind the same way they
went in (scale-down drains workers first). The canonical-duration and
takeOwnership safeguards make re-renders converge in either direction.

## The optional lhcc-rbac bundle (Longhorn CAPI controller identity)

**Stands alone — nothing deploys it unless you wire it.** To exclude it from a
derived copy: delete `fleet/bundles/lhcc-rbac/`, this section, the `lhcc-rbac/`
line in the README tree, the closing sentence of the README *Longhorn bundle*
paragraph, and the commented `# - fleet/bundles/lhcc-rbac` path in
`resources/gitrepos/longhorn.yaml`. Nothing else in the repo references it.

`fleet/bundles/lhcc-rbac/` ships the **guest-cluster identity** for the
optional longhorn-capi-controller (lhcc). What it deploys INTO a cluster:
the `lhcc-eviction-agent` ServiceAccount (kube-system), its never-expiring
token Secret, a least-privilege ClusterRole, and the binding. Nothing else —
no controller, no workloads, and it is inert on its own.

**Do you need it?**

- Plain Longhorn: **NO**. With >= 3 replicas across >= 3 workers, Longhorn's
  native replication survives a node drain/replacement on its own: pods
  reschedule, volumes serve from the surviving replicas, the lost replica
  rebuilds itself. The bundle would sit unused.
- Running the controller on the management cluster (automated node
  replacement, drain gating, orphaned-replica cleanup): **YES**. Without the
  identity, a provisioned cluster gets Longhorn but no eviction agent —
  coverage silently absent exactly when a node is replaced.

**Wiring (when you run the controller):**

1. Ship the bundle with Longhorn: add `fleet/bundles/lhcc-rbac` to the
   Longhorn GitRepo `paths` (see the commented line in
   `resources/gitrepos/longhorn.yaml`) so every labeled cluster gets the
   identity alongside Longhorn.
2. Pair it on the management side once the bundle converges — the script
   ships with the controller repo:

       lhcc-setup-workload-identity.sh --workload-kubeconfig <admin-kc> --cluster <cluster-id>

   It creates the `<cluster>-lhcc-kubeconfig` Secret in `fleet-default`,
   which the controller (v0.11.0+) resolves per cluster. Prefer a stable
   LB/DNS `--server` endpoint — node IPs change when VMs are replaced.
3. Deploy the controller itself on the management cluster per its repo
   README (kustomize; pin the image tag; latest release: v0.11.1).

**Version discipline:** the templates here are copies of the upstream
`longhorn-capi-controller/config/rbac/workload_role.yaml` — on upstream
change, bump the chart version and re-copy (see
`fleet/bundles/lhcc-rbac/README.md`).

## Troubleshooting

| Symptom | Where the truth is | Cause → resolution |
|---|---|---|
| Bundle 0/1 WaitApplied, nothing changes, no UI error | fleet-agent logs (`grep -i conflict`) | SSA field-ownership conflict → `takeOwnership: true` + canonical durations (§ Field ownership) |
| gitrepo `status.commit` stuck behind repo HEAD | gitrepo conditions / gitjob logs | clone/auth failure — anonymous clone of a private repo, or a trailing slash in the repo URL → fix URL/credentials |
| machine-provision pods `BackoffLimitExceeded`, workers churn-loop | machine-provision pod events | missing storage class, or image in the wrong namespace (`virtualmachineimages ... not found`) → apply the SC / fix the image namespace; self-heals after |
| Delayed worker loops `401 ... connection information` | node's install log | registration token rotated before the delayed node joined → delete the Machine; CAPI recreates it with fresh bootstrap data |
| Existing CP "waiting for plan to be applied" during scale-up | provisioning cluster status | plan re-delivery → wait, self-heals |
| `kubectl get cluster` shows an object with no `machinePools` | — | short-name collision with the CAPI Cluster → spell out `clusters.provisioning.cattle.io` |
| Two `HarvesterMachineTemplate`s for one pool after a config/image change | `kubectl -n fleet-default get harvestermachinetemplates -l rke.cattle.io/machine-template-hash` … or just list them | normal: Rancher cloned a new template under a new hash and repointed the MachineDeployment; the old clone is left behind (not pruned). The live one is the one the pool's MachineDeployment points at: `kubectl -n fleet-default get machinedeployments -o custom-columns=NAME:.metadata.name,INFRA:.spec.template.spec.infrastructureRef.name` |
| A pool rolled when only the *other* pool's values changed | `tests/render/render-check.sh`, then the rendered `diskInfo` of each pool's `HarvesterConfig` | the shared top-level value was edited instead of the pool override — every pool inherited a new config, so every pool re-cloned. Fix forward: pin the pool's own `imageName` and revert the top-level one |
| `tests/render/render-check.sh` fails immediately after an image hop you *meant* to make | the diff the gate prints | not a regression: the hop changed machine config, which is exactly what the gate guards. Run `--update`, commit the re-pinned goldens in the same commit as the hop — the golden diff is then your evidence that exactly one pool's `diskInfo` moved |
| Nodes came up on an OS whose *name* does not match the image's name | `kubectl get nodes -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion`, then `/etc/os-release` on the VM; `guestfish --ro -a <qcow> -i cat /etc/os-release` for the image itself | usually not a bug: `displayName` is free text, and SLE Micro is built from SLES so a Micro image may report `SUSE Linux Enterprise Server`. Compare kernels across generations (the hard signal), then fix the image or the expectation — never the check (§ Per-pool image hops) |
| Bundle 0/0 targets, no bundledeployment, GitRepo looks fine | target cluster labels | the `clusterSelector` matched nothing — check labels on the FLEET cluster object, not the provisioning CR: `kubectl get clusters.fleet.cattle.io -n fleet-default -L management.cattle.io/cluster-name` (auto-populated; hand-rolled labels need a manual labeling step) |

## Where the deeper docs live

- `docs/gitrepo-fleet-clustertemplate.md` — the layers, GitRepo schema, and
  recorded Fleet behaviors.
- `docs/longhorn-lifecycle.md` — the Longhorn-with-data contract: settings,
  procedure, and verification rounds for cluster lifecycle with volumes
  aboard.
- `docs/promotion-model.md` — how a change reaches production (branches,
  PRs, verification gates, rollback).
- `fleet/bundles/longhorn/fleet.yaml` — Longhorn's single config file: the
  `version:` pin and the values together. Upgrading Longhorn = edit that one
  version field, commit, push — always its own commit, separate from
  cluster changes.
