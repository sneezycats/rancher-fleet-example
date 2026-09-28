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
data continuity. **No UI clicks, no imperative tooling.**

## Repository layout

```
├── cluster-templates/chart/        # the cluster template (Helm chart)
│   └── values.yaml                 # <REPLACE_ME> config: image, k8s, pools…
├── fleet/bundles/longhorn/         # Longhorn bundle (two modes: repo-pinned + vendored) + values pin
├── resources/gitrepos/             # the GitRepo CRs (cluster + longhorn)
├── scripts/                        # data layer + verification (baseline/verify)
└── docs/                           # this approach, documented
```

## Quickstart (the checklist)

1. **Replace every `<REPLACE_ME_*>`** in `cluster-templates/chart/values.yaml`
   (cloud credential, VM namespace/network, image present on your Harvester,
   ssh user, cloud-init user data — never commit real keys).
2. **Ensure the image + storage class exist** on your Harvester (see
   `docs/image-bake.md` for the golden-image approach).
3. **Create the GitRepos** (`resources/gitrepos/*.yaml`, adjusted to your git
   host + branch strategy) and apply against your Rancher's kubeconfig.
4. **Deploy**: either let Fleet install the template bundle from the GitRepo,
   or bypass for the first build:
   `helm install <cluster> ./cluster-templates/chart`
5. **Label the cluster** once it is Ready:
   `kubectl label clusters.fleet.cattle.io -n fleet-default <cluster> managed-by=fleet`
   → Longhorn deploys from its bundle.
6. **Data layer + verification**: `scripts/` (PVCs + writers + baseline/verify)
   — the audit artifact for every future round.

## Longhorn bundle: two modes, pick one

- **Repo mode** (`fleet.yaml`, default): `helm.repo` + `version:` pin — the
  chart is fetched at deploy time. **Upgrade = edit one version line in the
  web UI.** Validated on Rancher 2.14.1 (adopts the existing release in
  place, no pod churn).
- **Vendored mode** (`fleet.vendored.yaml`): chart committed at
  `longhorn-chart/` — deterministic, air-gap friendly, but every upgrade
  needs a `helm pull` + replace + commit on a build host.

Swap between them by which fleet.yaml is deployed. Longhorn upgrades are
always their own commit, separate from cluster upgrades.

## Rules that make it safe (lab-enforced)

- One component per commit: cluster change and Longhorn change are separate
  commits, each verified before the next.
- Environment branches are release-only: `production` moves only by PR merge
  from the lower env; hotfixes flow down and up through PRs, never sideways.
- What the UI changes, the repo must reflect (sync values back, commit).
- Batch any golden-image work; test on one cluster before rolling wider.

## Docs

- `docs/gitrepo-fleet-clustertemplate.md` — layers, GitRepo schema, creation
  process, Fleet behaviors (including the footguns we recorded).
- `docs/image-bake.md` — what the golden image changes vs upstream, and why
  (immutable `/`, masked autopatch, cloud-final fix).
- `docs/promotion-model.md` — branch-per-environment promotion, validated.