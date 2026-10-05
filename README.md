# Rancher Fleet — Cluster + Component GitOps (example skeleton)

A teaching artifact and starting point: run **one Kubernetes cluster, its node
driver config, AND Longhorn entirely from one git repo** — auditable, branch-
promotable, access-controlled by git + Rancher RBAC.

Why: UI-driven installs drift — no audit trail, no review, and upgrades
happen only when someone remembers. Git is the memory: every change is a
reviewable commit, and promotion is a branch merge.

## The model (4 layers)

1. **Git** — one repo per cluster (or per environment): charts + values + docs
   + verification proofs. The single source of truth.
2. **GitRepo** (`fleet.cattle.io`) — the leash: *which repo, branch, and paths*
   are chart roots. One per environment: `development`, `production`, …
3. **Fleet** — the executor: syncs GitRepos, deploys each path as a Helm chart
   (revisioned `helm install`/`upgrade`), targets by label.
4. **Cluster templates + provisioning (CAPI)** — the cluster template *is* a
   Helm chart that renders **CRs** (a provisioning `Cluster` + the node driver
   `HarvesterConfig`) instead of pods; CAPI turns those into real VMs via the
   hypervisor's API, then rolls machines on config change.

**Upgrade flow:** change a value → commit → push → Fleet `helm upgrade` →
config hash changes → CAPI rolls machines (new nodes join before old are
deleted) → Longhorn rebuilds replicas onto the new nodes → `verify.sh` proves
data continuity. **No UI clicks, no imperative tooling.** Scale changes simply add/remove machines; config/image/version changes roll them — `UPGRADE.md` has the full taxonomy, the verification chain, and the pitfalls.

## Repository layout

```
├── cluster-templates/chart/        # the cluster template (Helm chart)
│   ├── Chart.yaml + templates/     # renders the Cluster + HarvesterConfig CRs
│   └── values.yaml                 # <REPLACE_ME> config: image, k8s, pools…
├── fleet/bundles/longhorn/         # Longhorn bundle - ONE fleet.yaml: version pin + values
├── fleet/bundles/lhcc-rbac/        # OPTIONAL: guest identity for the Longhorn CAPI controller (see UPGRADE.md)
├── resources/gitrepos/             # the GitRepo CRs (cluster + longhorn)
├── scripts/                        # data layer + verification (baseline/verify)
└── docs/                           # this approach, documented
```

## Quickstart (the checklist)

1. **Replace every `<REPLACE_ME_*>`** in `cluster-templates/chart/values.yaml`
   (cloud credential, VM namespace/network, image present on your Harvester,
   ssh user, cloud-init user data — never commit real keys). The GitRepo CRs
   in `resources/gitrepos/` carry the same placeholders (git host, branch,
   names) — set those when you apply them in step 3.
2. **Ensure the image + storage class exist** on your Harvester (see
   `docs/image-bake.md` for the change-set, and
   `docs/custom-sl-micro-longhorn-image.md` to bake one from scratch).
   Note: the example chart attaches one root disk per node, so the golden
   image's dedicated-data-disk unit skips safely in this shape — see §7 of
   the bake guide for when a dedicated data disk is (and is not) needed.
3. **Create the GitRepos** (`resources/gitrepos/*.yaml`, adjusted to your git
   host + branch strategy) and apply against your Rancher's kubeconfig.
4. **Deploy**: either let Fleet install the template bundle from the GitRepo,
   or bypass for the first build:
   `helm install <cluster> ./cluster-templates/chart`
5. **Label the cluster** once it is Ready:
   `kubectl label clusters.fleet.cattle.io -n fleet-default <cluster> managed-by=fleet`
   → Longhorn deploys from its bundle.
6. **Data layer + verification**: apply the data layer against the new
   cluster's kubeconfig (`kubectl apply -f scripts/01-pvcs.yaml -f
   scripts/02-data-deployments.yaml`), then capture a baseline with
   `scripts/baseline.sh` before every round and run `scripts/verify.sh`
   after — the audit artifact for every future round.

## Longhorn bundle: one file, one version field

`fleet/bundles/longhorn/fleet.yaml` carries everything: the chart source
(`helm.repo` + `chart`), **the version pin — `helm.version`, the only
version-carrying field in the bundle** — the release name, and the values
(`helm.values`). Upgrading Longhorn = edit that one `version:` line, commit,
push; Fleet adopts the existing release in place (validated on Rancher
2.14.1/2.14.3, no pod churn). Values live in the same file, so version and
values cannot drift apart.

(An air-gap vendored variant was retired from this repo: if you ever need
it, vendor the chart into the bundle dir, point `helm.chart` at it, drop
`repo`/`version`, and let the vendored `Chart.yaml` become the pin.)

Longhorn upgrades are always their own commit, separate from cluster
upgrades. The optional `lhcc-rbac` bundle rides the same GitRepo (one extra
path in `resources/gitrepos/longhorn.yaml`) and pairs a cluster with the
Longhorn CAPI controller — see UPGRADE.md before wiring it.

## Rules that make it safe (lab-enforced)

- One component per commit: cluster change and Longhorn change are separate
  commits, each verified before the next.
- Environment branches are release-only: `production` moves only by PR merge
  from the lower env; hotfixes flow down and up through PRs, never sideways.
- What the UI changes, the repo must reflect (sync values back, commit).
- Batch any golden-image work; test on one cluster before rolling wider.

## Docs

- `UPGRADE.md` — the change-day runbook: what each values edit does
  (scale vs roll), the verification chain, and the field-ownership pitfalls
  (start here before touching a running cluster).
- `docs/longhorn-lifecycle.md` — the Longhorn-with-data contract: settings,
  procedure, and verification rounds for cluster lifecycle with volumes
  aboard.
- `docs/gitrepo-fleet-clustertemplate.md` — layers, GitRepo schema, creation
  process, Fleet behaviors (including the footguns we recorded).
- `docs/image-bake.md` — what the golden image changes vs upstream, and why
  (immutable `/`, masked autopatch, cloud-final fix).
- `docs/custom-sl-micro-longhorn-image.md` — full step-by-step golden-image bake
  guide (build host setup → bake → verify → import).
- `docs/promotion-model.md` — the branch-per-environment promotion model:
  dev → staging → production by PR merge, verification gates, hotfixes and
  rollback (validated in-lab).
