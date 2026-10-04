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
