# harvester-lb — GitOps'd Harvester Layer-4 LB (no UI click-ops)

The Harvester UI "create LoadBalancer" button is a form over two plain
CRDs (`loadbalancer.harvesterhci.io/v1beta1`: `IPPool` + `LoadBalancer`).
This path applies them through Fleet to the **Harvester (management)
cluster itself** — not to the guest/workload cluster — so the LB is
git-tracked like everything else and the manual path disappears.

## Reference topology

    client -> upstream L7 balancer (optional; e.g. F5) -> pool member =
    ONE Harvester L4 LB VIP -> workload cluster nodes -> ingress/gateway routes

The Harvester L4 LB is port-agnostic below the VIP: give it one listener
per port the upstream balancer forwards. The cluster's ingress
(traefik/gateway) owns L7 routing. Without an upstream balancer, clients
reach the VIP directly; nothing about the Harvester-side plumbing changes.

## Files

- `ippool.yaml`      — static IP pool for LB VIPs (keep OUT of the DHCP range)
- `loadbalancer.yaml`— one LB per workload cluster; backends selected by the
  labels the Harvester node driver stamps automatically
- `fleet.yaml`       — raw-YAML bundle marker (see warning inside)

## Delivery

GitRepo lives in `resources/gitrepos/` (applied manually to the Rancher
mgmt cluster) with `paths: [harvester-lb]` and a `targets` entry
selecting the HARVESTER cluster. The harvester-load-balancer controller
then creates and OWNS the Service + dummy EndpointSlice + kube-vip claim —
never author those yourself.

## Do you need an apiserver LB at all?

Under the default Rancher posture, usually not:

- `kubectl` to a downstream cluster rides the Rancher proxy
  (`https://<rancher>/k8s/clusters/<id>`) — no direct route to the guest
  API server is required.
- Node agents **dial out** to the Rancher URL (verified: the RKE2
  node-plan `server:` entry is the Rancher URL, not a cluster VIP), and
  inter-node RKE2 traffic (9345 join, etcd) uses node IPs directly.

So the ingress LB alone covers the work chain. Add an apiserver LB only
when you want one of:

1. **Break-glass access that survives a Rancher outage** — the proxy
   path dies with Rancher; a direct VIP does not.
2. **External automation with its own kubeconfig** pointed at a stable
   VIP that survives control-plane replacement (the alternative —
   pinning node IPs — breaks on every machine replacement).
3. **An upstream L7 balancer fronting 6443** as well as 80/443.

If you enable one, add the VIP to the API server's serving-cert SANs
(RKE2 `api-endpoints` in the machine GlobalConfig) or direct clients hit
TLS name mismatches. The template ships it commented out for this reason.

## Pitfalls

All observed in practice; the dated run records are in
`docs/lab-validation-log.md`.

1. **GitRepo namespace = target cluster namespace.** Imported Harvester
   clusters live in `fleet-default`; a `fleet-local` GitRepo matches zero
   clusters and reports a silent 0/0.
2. **Targeting is `spec.targets[].clusterSelector`** — there is no
   `targetClusterSelector` field; strict decoding refuses the manifest.
3. **A chartless path with any `helm:` block renders ZERO resources.**
   Raw YAML needs no helm block (bundle existed with resources: null).
4. **IPPool `spec.selector.scope` is an ARRAY** of
   `{namespace|project|guestCluster}` objects — a map is rejected by
   Fleet's typed patch.
5. **Selector matches VMI labels.** The node driver stamps both VM and
   VMI, so this only bites hand-labeled VMs.
6. **LB before cluster is safe**: zero backends sits `Ready=False
   "no running backend servers"` and self-heals when VMs appear.
7. `healthCheck.port` must equal one listener `backendPort`;
   `periodSeconds` is lowercase in v1beta1 (v1alpha1 quirk gone).
8. `workloadType: vm` = the standalone LB we own. `cluster` is reserved
   for LBs the Harvester CCM auto-creates from guest LoadBalancer
   Services — the mgmt controller deliberately skips those.
9. v1alpha1 is deprecated and lacks `backendServerSelector` — v1beta1 only.
10. **healthCheck.port gates the WHOLE backend set, not per-listener.**
    An LB with listeners on 6443 AND 80 cannot health both: whichever
    port you probe excludes nodes not serving it (observed: hc=6443
    silently killed the VIP's :80 path). If you run both an apiserver LB
    and an ingress LB, keep them split, each with a matching
    healthCheck port.
11. **Traefik on RKE2 = hostNetwork on workers** (hostPort 80/443 on the
    worker node IPs), so the ingress LB can select the worker pool via
    nodepool.harvesterhci.io/name — but the pool name carries a generated
    suffix (workers-<5chars>); read it off a live VM (`kubectl get vm
    --show-labels`) or select the whole cluster and let the health check
    trim.
12. **Listener changes do not prune the owned Service's ports.** The
    controller ADDS ports on listener edits but never removes them —
    stale listeners keep routing (and can shadow the health-check
    change you just made). On any listener-shape change, delete the LB
    and let Fleet re-create it (the same pool IP is re-allocated).
