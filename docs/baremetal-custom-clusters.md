# Bare-metal / bring-your-own-node clusters via Fleet (custom-cluster template)

Bare metal is rare in the estate; Harvester-provisioned VMs are the day-to-day
path. So the Fleet bits are **separated at the provisioning layer** and
**shared at the component layer**:

| Layer | Harvester flavor | Bare-metal flavor | Shared? |
|---|---|---|---|
| Cluster template (provisioning) | `cluster-templates/chart` — machine pools, HarvesterConfig, cloud credential, image/network | `cluster-templates-custom/chart` — one `Cluster` CR, no pools, no credential | separate |
| Component bundles (Longhorn, data layer) | `longhorn` single-file `fleet.yaml` | identical | **shared** |
| GitRepo routing rules | fleet-local for templates, fleet-default for components | identical | **shared** |
| Ops scripts (roll window, residue cleanup, verify) | scripts/ | identical | **shared** |

The discriminator is structural, not a flag: **an `rkeConfig` without
`machinePools` IS a custom cluster.** The CRD states it plainly: *"RKEConfig
represents the desired state for machine configuration and day 2 operations.
NOTE: This is only populated for provisioned and custom clusters."* No cloud
credential, no image, no network, no VM shape — those are node-driver
concepts. Nodes register themselves by running the per-role system-agent
registration command; the Fleet-managed cluster object tracks them the same
way it tracks driver-provisioned machines.

## Anatomy of the custom template

`cluster-templates-custom/chart/templates/cluster.yaml` produces exactly one
object:

```yaml
apiVersion: provisioning.cattle.io/v1
kind: Cluster
metadata:
  name: <name>
  namespace: fleet-default
spec:
  enableNetworkPolicy: false
  kubernetesVersion: <pinned>
  rkeConfig:
    machineGlobalConfig:   # cni: calico, ingress-controller: traefik (clickops parity)
      ...
    # machinePools ABSENT -> custom cluster
```

Everything else a Harvester cluster needs is deliberately gone:
`cloudCredentialSecretName`, `harvester-cloud-provider` chart values, node
pools, `drainBeforeDelete*` (a machine-pool concept — custom nodes are
drained manually or via the UI per-node option when removed).

## Node roles: decided at registration, not in the template

Roles are assigned by the registration command flags, so the template is
topology-free:

| Role | Registration command flag | Notes |
|---|---|---|
| First server (init) | `--server --etcd --controlplane` (or role tabs in the UI) | boots etcd + CP |
| Additional CP/etcd | same flags | joins existing etcd |
| Worker | `--worker` | where Longhorn lives |

The registration command comes from the cluster itself. UI: Cluster →
Registration tab (per-role tabs, exact command). CLI (verified against
2.14.3): the `clusterregistrationtoken` object in `fleet-default` named for
the cluster carries `status.nodeCommand` (and `status.insecureCommand` when
CA verification is off). The command form is:

```
curl -fL https://<rancher>/system-agent/install.sh -o system-agent-install.sh &&
  sudo sh system-agent-install.sh --server https://<rancher> --token <TOKEN> \
    --ca-checksum <SUM> --rke2 --server --etcd --controlplane    # or --worker
```

Two paths exist for bare metal and they are NOT the same — this repo uses the
first:
1. **Rancher custom-node registration** (system-agent `install.sh`) — the
   agent joins the Rancher-managed cluster; Fleet owns the lifecycle.
2. Raw RKE2 install + cluster import (clickops) — out of Fleet's reach; not
   our standard. (Note: the raw installer exits 0 without enabling the
   service — `systemctl enable --now rke2-server` is a manual step there.
   The system-agent path handles services itself.)

## Topology and Longhorn

Longhorn registers on nodes WITHOUT the CP/etcd taints — same rule as the
Harvester flavor. Shapes that work:

- **3 CP + ≥1 worker**: Longhorn available; component GitRepo targets the
  cluster normally.
- **3 CP only (no workers)**: no Longhorn — skip the Longhorn component
  GitRepo for this cluster, or deliberately untaint CP nodes (own the
  consequences: etcd latency under storage load; not the default).

Storage layout is operator-owned (no VM disk size knob): partition/mount
extra disks for Longhorn before registration if the defaults don't suit.

## Validation status (honest ledger)

| Piece | Status |
|---|---|
| CR schema vs live Rancher 2.14.3 API | server-side dry-run + real create — proven |
| Custom cluster provisioned via Fleet template | proven in lab (throwaway `fleet-proxy-custom`) |
| Registration command retrieval (CLI) | proven — `clusterregistrationtoken`/`status.nodeCommand` |
| Node join via registration command | validated in lab with a VM standing in for metal (the flow is metal-agnostic — same system-agent); PXE/hardware specifics are out of scope by design |
| Component layer (Longhorn) on a custom cluster | same GitRepo mechanics as any cluster; the `managed-by=fleet` label pitfall applies identically |

## Work-copy checklist (what to pull when updating the copy)

1. `cluster-templates-custom/` (chart + README) — new, no churn to the
   Harvester path.
2. `resources/gitrepos/cluster-templates-custom.yaml` — the EXAMPLE GitRepo.
3. `docs/baremetal-custom-clusters.md` — this doc.
4. README repo-map entry (see repo README delta).
5. Nothing in `cluster-templates/chart/` changes — the day-to-day Harvester
   path is untouched by this addition.