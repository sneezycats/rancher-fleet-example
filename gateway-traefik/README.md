# gateway-traefik — Gateway API on the RKE2-bundled Traefik

Gateway API wiring for clusters that use RKE2's packaged Traefik. The
mechanics below were validated on RKE2 v1.33.x with the rke2-traefik
chart 40.1.003.

## Why this exists (the moving parts, named)

ingress-nginx is one object type (Ingress) pointed at one controller.
Gateway API splits roles across four, and Traefik adds its own vocabulary:

| Piece | Who owns it | What it does |
|---|---|---|
| Gateway API CRDs | RKE2 (`rke2-traefik-crds` addon) | installs Gateway/HTTPRoute/etc. — present even when the provider is OFF (CRDs present != provider enabled — a common false read) |
| `providers.kubernetesGateway` | Traefik's HelmChartConfig, fed by **`extraChartValues` in cluster-templates/chart/values.yaml** | turns on Traefik's Gateway controller loop |
| GatewayClass `traefik` | **the rke2-traefik chart** (auto-created when the provider is on) | platform-level: which controller claims Gateways (`traefik.io/gateway-controller`) |
| Gateway `traefik` | this bundle | the entry: listeners (port/protocol/hostname) — the "IP + ports" contract |
| HTTPRoute | app teams, in their own namespace | L7 rules (host/path match -> backend Service) |
| Harvester L4 ingress LB (harvester-lb/) | this repo | VIP :80/:443 -> node hostPorts -> Traefik pod |

Full data path: **upstream L7 balancer (optional) -> Harvester ingress LB
VIP (:80/:443) -> node hostPort 80/443 -> Traefik pod entrypoint
:8000/:8443 -> Gateway listener -> HTTPRoute -> Service -> pod.** Without
an upstream balancer, clients hit the LB VIP directly.

## Enablement is NOT a bundle resource

The enable flag rides the Cluster CR: `spec.rkeConfig.chartValues` —
set it via `extraChartValues` in cluster-templates/chart/values.yaml:

```yaml
extraChartValues:
  rke2-traefik:
    providers:
      kubernetesGateway:
        enabled: true     # exact key spelling — Helm values keys are case-sensitive; a wrong-cased key is silently ignored
    gateway:
      enabled: false      # suppress the chart's own Gateway (see pitfall 3)
```

Rancher writes that as a HelmChartConfig in the downstream kube-system;
RKE2's addon controller owns that object — a raw-YAML Fleet bundle that
tries to author/adopt a HelmChartConfig for rke2-traefik will not stick.

## Pitfalls

All observed in practice.

1. **CRDs without a provider.** Gateway API CRDs ship with RKE2's
   traefik-crds addon regardless of the flag. `kubectl get crd | grep
   gateway` proving CRDs exist means nothing — check the Traefik pod
   args for `--providers.kubernetesgateway`.
2. **Do not author the GatewayClass.** With the provider on, the chart
   creates+owns GatewayClass `traefik` (Helm release annotations). A
   bundle-authored one collides: "cannot be imported into the current
   release". Just reference `gatewayClassName: traefik`.
3. **The chart auto-creates its own Gateway** (`traefik-gateway`,
   listener web:8000, allowedRoutes Same-namespace only — useless for
   app namespaces). Suppress with `gateway.enabled: false` in
   extraChartValues and own the single Gateway from this bundle.
4. **Listener port = entrypoint CONTAINER port, not the node hostPort.**
   Traefik matches listeners to entrypoints by container port+protocol:
   web=:8000 (hostPort 80), websecure=:8443 (hostPort 443). A listener
   on 80/HTTP fails: `PortUnavailable — no matching entryPoint for port
   80 and protocol "HTTP"`. Use 8000/8443 in the Gateway; clients still
   hit the VIP on 80/443.
5. **Gateway status address is a lie here.** The chart pins
   statusAddress to the rke2-traefik ClusterIP Service (10.43.x). The
   externally reachable address is the Harvester LB VIP. Upstream
   balancers target the LB VIP, never the Gateway status.
6. **HTTPS listeners need certs.** An HTTPS/8443 listener requires
   `tls.certificateRefs` (a TLS Secret in the Gateway's namespace). The
   plain HTTP listener here is enough when an upstream balancer
   terminates TLS; add the listener + cert when a cluster must terminate
   TLS itself.
7. **Fleet drift correction is real.** Hand-editing any of this with
   kubectl gets reverted on the next bundle apply. Fix the git, not the
   cluster.

## Prove it out (no DNS needed)

```
curl -s -H 'Host: whoami.example.com' http://<ingress-LB-VIP>/   # -> whoami pod echoes
curl -s -o /dev/null -w '%{http_code}\n' http://<ingress-LB-VIP>/        # -> 404 (no route matched)
```

Expected healthy state: Gateway `Accepted=True Programmed=True`,
listener `attachedRoutes=1`, HTTPRoute `Accepted=True ResolvedRefs=True`.
