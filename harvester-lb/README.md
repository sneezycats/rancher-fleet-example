# harvester-lb — GitOps'd Harvester Layer-4 LB (no UI click-ops)

The Harvester UI "create LoadBalancer" button is a form over two plain
CRDs (`loadbalancer.harvesterhci.io/v1beta1`: `IPPool` + `LoadBalancer`).
This path applies them through Fleet to the **Harvester (management)
cluster itself** — not to the guest/workload cluster — so the LB is
git-tracked like everything else and the manual path disappears.

## Production shape (work)

    client -> F5 L7 VIP (security-mandated) -> pool member = ONE Harvester
    L4 LB VIP -> workload cluster nodes -> ingress/gateway routes

The Harvester L4 LB is port-agnostic below the VIP: give it one listener
per port the F5 (or any upstream) forwards. The cluster's ingress
(traefik/gateway) owns L7 routing. Mocking in the lab = skip the F5 and
curl the VIP directly; nothing about the Harvester-side plumbing changes.

## Files

- `ippool.yaml`      — static IP pool for LB VIPs (keep OUT of the DHCP range)
- `loadbalancer.yaml`— one LB per workload cluster; backends selected by the
  labels the Harvester node driver stamps automatically
- `fleet.yaml`       — raw-YAML bundle marker (see warning inside)

## Delivery (verified live 2026-10-12 on hobbyfarm + fleetlab5)

GitRepo lives in `gitrepos/` (applied manually to the Rancher mgmt
cluster) with `paths: [harvester-lb]` and a `targets` entry selecting the
HARVESTER cluster. The harvester-load-balancer controller then creates
and OWNS the Service + dummy EndpointSlice + kube-vip claim — never
author those yourself.

## Pitfalls (all caught live, 2026-10-12)

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
    port you probe excludes nodes not serving it (verified live — hc=6443
    silently killed the VIP's :80 path). Split LBs per port group:
    apiserver LB + ingress LB, each with a matching healthCheck port.
11. **Traefik on RKE2 = hostNetwork on workers** (hostPort 80/443 on the
    worker node IPs), so the ingress LB can select the worker pool via
    nodepool.harvesterhci.io/name — but the pool name carries a generated
    suffix (workers-<5chars>); read it off a live VM (`kubectl get vm
    --show-labels`) or select the whole cluster and let the health check
    trim.
