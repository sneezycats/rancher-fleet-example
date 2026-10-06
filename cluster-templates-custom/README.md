# cluster-templates-custom — bare metal / bring-your-own-node clusters

Fleet-managed RKE2 clusters whose nodes are machines YOU install — physical
servers today, anything with an agent-capable OS tomorrow. Same Fleet
process, same component bundles, different provisioning template: an
`rkeConfig` **without machinePools** is a custom cluster. Design rationale
and validation ledger: `docs/baremetal-custom-clusters.md`.

## 1. Create the cluster object (Fleet)

Fill `chart/values.yaml`:

```yaml
name: "your-bm-cluster"
kubernetesVersion: "v1.33.13+rke2r1"   # check the support matrix first
machineGlobalConfig:
  cni: calico
  ingress-controller: traefik
```

Deploy it the same way as the Harvester template (TEMPLATES go in
**fleet-local**): apply `../resources/gitrepos/cluster-templates-custom.yaml`
filled in for your git host/branch, with
`spec.paths: [cluster-templates-custom/chart]`. Fleet renders the `Cluster`
CR into `fleet-default`; no VMs appear — there are no machine pools.

Watch it:

    kubectl --kubeconfig <mgmt-kc> -n fleet-default get clusters.provisioning.cattle.io <name>

## 2. Get the registration command

UI: cluster → Registration tab → per-role tabs (exact commands).

CLI (verified on 2.14.3):

    kubectl -n fleet-default get clusterregistrationtoken <name> \
      -o jsonpath='{.status.nodeCommand}'

## 3. Register the nodes, role per role

Run the command on each server. Role flags decide the topology:

- First server + additional CP: append `--server --etcd --controlplane`
- Workers (where Longhorn will live): append `--worker`

Prereqs per server: supported OS per the support matrix, stable
IP/DNS-reachability to the Rancher endpoint (443) and between nodes
(6443/9345/8472-or-VXLAN per CNI), NTP healthy, and any extra disks
partitioned/mounted before registration if Longhorn should use them.

## 4. Verify

    kubectl --kubeconfig <mgmt-kc> -n fleet-default get clusters.provisioning.cattle.io <name>
    kubectl --kubeconfig <mgmt-kc> get machines.cluster.x-k8s.io -A | grep <name>

Cluster goes Active once etcd has quorum and agents are healthy; machines
appear as agent-registered entries.

## 5. Components

Identical to every other cluster — the component GitRepos (Longhorn etc.)
target it by name. Longhorn needs worker-role (untainted) nodes; a CP-only
cluster skips the Longhorn GitRepo entirely. Pitfall (applies to custom
clusters exactly like provisioned ones): the target `clusters.fleet.cattle.io`
object needs the `managed-by=fleet` label or the bundle shows 0/0 targets.

## 6. Remove the cluster

    kubectl -n fleet-default delete clusters.provisioning.cattle.io <name>

Custom clusters with no machines delete instantly (no CAPI machines, no
drains, no finalizer wedges). Individual node removal: drain manually
(UI drain option) then delete the node from the cluster.