# UPGRADE.md — changing a running cluster through this repo

The change-day runbook for the cluster template and its component bundles:
what to touch, what happens after you push, what to check, and the failure
modes that are invisible in the UI. Written for someone returning to this
repo after months of other work — every command is copy-pasteable with
placeholders.

*Provenance: mechanics validated in-lab on Rancher 2.14.3 + Harvester 1.7.x,
2026-10-04 (control-plane 1→3 and workers 1→2 in one change: 3 new VMs,
5/5 nodes Ready ~9 min after push). Field names move between Rancher
versions — re-validate against yours.*

## The 30-second version

- Every change is a `values.yaml` (or bundle `fleet.yaml`) edit → commit →
  push. No UI clicks, no imperative kubectl apply. Git is the control plane.
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
| `imageName` | full roll (golden image) | cluster-wide |
| `machineGlobalConfig` / `chartValues` | config-hash change → roll | cluster-wide |
| `name:` (cluster name) | NOT a rename — Fleet garbage-collects the old Cluster CR (teardown) and builds a twin | destructive; see below |

Rolling replacement = new VM + node join BEFORE the old machine is deleted;
the data layer (Longhorn) rebuilds replicas onto the new nodes — run the
verification round after (see `docs/promotion-model.md`).

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
- [ ] Touching `kubernetesVersion`? Check the SUSE Rancher↔Harvester↔RKE2
      support matrix first.
- [ ] Touching `imageName`? The VM image must exist on the target Harvester
      AND in the same namespace the VMs land in (the node driver resolves
      images in the VM namespace — an image in the wrong namespace churns
      "virtualmachineimages ... not found" with zero VMs created).
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
| Bundle 0/0 targets, no bundledeployment, GitRepo looks fine | target cluster labels | the `clusterSelector` matched nothing — label the FLEET cluster object, not the provisioning CR: `kubectl -n fleet-default label clusters.fleet.cattle.io <cluster> managed-by=fleet` |

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
