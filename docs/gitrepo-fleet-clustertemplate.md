# GitRepo + Cluster Templates + Fleet: schema, creation, behaviors

(Anatomy from a 2.14-era Rancher; field names may evolve — validate against
your version, e.g. the GitRepo spec differs on newer Fleets.)

## The layers, in one paragraph

A **GitRepo** (fleet.cattle.io) tells **Fleet** which git repo, branch and
paths are chart roots ("bundles"). Fleet clones server-side and applies each
bundle with the Rancher Helm engine (revisioned releases). A **cluster
template** is a Helm chart that renders CRs — a provisioning `Cluster` + the
node-driver `HarvesterConfig` — and CAPI turns those CRs into VMs and machine
rolls. Longhorn is a second, ordinary chart, targeted at labeled clusters.

## GitRepo schema (2.14-era, verified)

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: <name>
  namespace: fleet-local        # template bundles; components use fleet-default
spec:
  branch: <branch>              # the promotion axis (development|production|…)
  paths:                        # each path = one bundle (chart root)
  - some/path/to/chart
  repo: https://<host>/<org>/<repo>.git
  targets:                      # component bundles only:
  - clusterSelector:            # deploy when the cluster label matches
      matchLabels:
        managed-by: fleet
```

## Workspace: where the GitRepo lives decides what it can reach (A/B-validated 2026-10-09, 2.14.3)

`metadata.namespace` selects the Fleet WORKSPACE, and the workspace is the
candidate pool a GitRepo can ever target:

- **fleet-local** = the management cluster itself (Fleet Cluster `local`). A
  GitRepo here is applied by the LOCAL fleet-agent onto the management API —
  the only path that can create `provisioning.cattle.io` Cluster CRs, because
  those CRDs exist only on the management cluster.
- **fleet-default** = downstream clusters that have REGISTERED (their Fleet
  Cluster objects appear here when clusters register; the object is created as
  soon as the provisioning Cluster CR lands, not only after nodes join).

Same template chart + values deployed four ways (only the GitRepo workspace/
targets differed) — single-node all-role instance, observed live:

1. **fleet-local, no targets** → bundledeployment in `cluster-fleet-local-
   local-*` → the local agent renders the Cluster CR onto the management API
   → CAPI builds the VM → cluster bootstraps. **This is the bootstrap path.**
2. **fleet-default, no targets** → implicit target is `clusterGroup: default`
   — which does NOT exist in fleet-default on 2.14.3 (only fleet-local gets
   one) → the bundle sits at `Ready=True, 0/0 clusters` and silently deploys
   NOTHING. A green-looking GitRepo that builds no cluster.
3. **fleet-default, `targets: [{clusterName: local}]`** → 0 targets (the
   local cluster is not in this workspace) → nothing.
4. **fleet-default, `targets: [{clusterName: <registered-cluster>}]`** → the
   bundledeployment runs on that DOWNSTREAM cluster's agent and fails:
   `unable to build kubernetes objects from release manifest: ... no matches
   for kind "Cluster" in version "provisioning.cattle.io/v1"` — the CRD does
   not exist downstream. `ErrApplied`.

Rule of thumb, restated as mechanics: **TEMPLATES (bootstrap) → fleet-local;
COMPONENTS (storage, apps) → fleet-default with label targets.** The cluster
a template creates registers INTO fleet-default, which is where component
GitRepos then reach it. Verify a template GitRepo by the rendered Cluster CR
(`kubectl get clusters.provisioning.cattle.io -n fleet-default`), never by
"the GitRepo shows Ready" — variant 2 above shows Ready with zero effect.

Bundle names truncate (~49 chars + hash suffix): long GitRepo names produce
bundle/BD names like `<gitrepo>-cluster-templat-46d85`.

**ClusterGroups do not change this.** A ClusterGroup only selects WITHIN its
own workspace — it cannot make a fleet-default GitRepo reach the management
API. Validated on 2.14.3: a ClusterGroup with NO selector matched NOTHING
(`clusterCount: 0` — do not assume k8s empty-selector match-all semantics),
and a label-selector group that resolved correctly still delivered the
template bundle to the DOWNSTREAM agent, which failed with the same
`no matches for kind "Cluster" in version "provisioning.cattle.io/v1"`.
Selector labels match labels on the workspace's `fleet.cattle.io` Cluster
objects. Also note: creating a populated `default` ClusterGroup in
fleet-default silently repoints every implicit-target (no `spec.targets`)
GitRepo in that workspace at all matched clusters — keep explicit targets on
component GitRepos.

## Cluster identity across rebuilds (validated live 2026-10-09)

The management cluster id (`management.cattle.io/cluster-name`, `c-m-...`) is
minted fresh EVERY time the provisioning Cluster CR is created: a same-name
rebuild (delete the CR; the template GitRepo re-renders it) regenerates the
id. Never pin component GitRepo targets to it — after any rebuild the target
matches a dead id and the bundle sits silently at 0/0 (no error, no deploy).

The stable identity is the **Fleet Cluster object's NAME**, which for
Rancher-provisioned clusters equals the provisioning cluster name (imported
clusters are named by their cluster id instead) and returns identically after
a same-name rebuild. Pin component repos with
`targets: [{clusterName: <cluster-name>}]`: it resolves the moment the
cluster registers (0/0 silent before that) and re-attaches across rebuilds
with ZERO repo changes — verified end-to-end with a canary bundle through a
full delete/rebuild cycle (~6 min rebuild, instant re-attach).

Related: a template GitRepo with `spec.correctDrift.enabled: true` re-creates
a deleted Cluster CR in seconds (no new commit needed). With correctDrift
disabled (the default), a deleted cluster stays deleted — the GitRepo only
reports `Modified ... missing` — until a NEW commit forces a re-apply.

## The branch-quotes pitfall

A GitRepo whose `spec.branch` contains quotes AS PART OF THE STRING (e.g.
created through the Rancher UI form, which stores the raw string — a YAML
manifest would have parsed them away) reports
`Commit not found for branch: "master"` — the quotes visible in the error are
literally in the branch name. Fix: remove them; UI form fields take raw
values, quoting belongs only in YAML files where the parser strips it.

## Creation process

1. Repo + pinned branch ready; charts + values committed.
2. `kubectl apply -f gitrepo.yaml` against the Rancher kubeconfig.
3. Verify the chain (~1 min steps):
   - `kubectl get gitrepos` — Sync condition + commit hash
   - `kubectl get bundles` — bundle appears (`<gitrepo>-<path>-…`)
   - `helm list -A` — release with a revision >= 1, status deployed
   - `kubectl get clusters.provisioning.cattle.io -n fleet-default` — rendered
     Cluster CR (templates)
4. Components: label the target — `kubectl label clusters.fleet.cattle.io -n
   fleet-default <cluster> managed-by=fleet`.

## Behaviors that will bite you (learned the hard way)

- **Bundle identity = GitRepo + path.** A second GitRepo with the SAME
  repo+path does not get a fresh bundle — it waits on the old one.
  Different GitRepos (e.g. per environment branch) ARE distinct — validated.
- **A gated GitRepo delete is NOT a delete.** If anything blocks the bundle
  (e.g. a cluster CR stuck "scheduled for deletion"), the delete sits
  unprocessed; when the blocker clears, Fleet deploys the bundle — building a
  full twin under the old name at HEAD. Always confirm `kubectl get gitrepos`
  shows it gone before assuming.
- **Cross-cluster template bundles deploy into ns `default`** — check there
  for unexpected releases.
- Cleanup order that works: `helm uninstall <name> -n default` first (live
  VMs = clean driver teardown), then delete the GitRepo.
- The sweep crawls: after a rancher-server restart, big deletions complete one
  object per many minutes. Patience before surgery; name iteration beats
  fighting.

## Clickops note

UI changes to a live cluster converge on the same mechanism (config content
hash -> machine roll). Whatever path you used, sync the chart values back and
commit: the repo is the canonical description of the cluster.

---

The change-day runbook — what each values edit does, the verification chain,
and the field-ownership pitfalls with resolutions — lives in `UPGRADE.md` at
the repo root.
