# Ingress controllers — single, and Dual Mode (Traefik + Ingress-NGINX side by side)

How to pick and configure the cluster's bundled ingress controller(s)
through this repo — including the Rancher UI's "Dual Mode", where Traefik
and Ingress-NGINX run beside each other as a migration bridge instead of a
flag-day swap.

*Provenance: validated in-lab on Rancher 2.14.3 + Harvester 1.7.x + RKE2
v1.33.13 (fresh dual-controller cluster build, 2026-10-08) — both
controllers confirmed serving; the checks below are from that round.*

## The knob

`machineGlobalConfig.ingress-controller` in
`cluster-templates/chart/values.yaml` — the same field the Rancher cluster
UI's Ingress section writes into the provisioning Cluster CR.

| value | result |
|---|---|
| `traefik` | Traefik only — the UI's "Traefik" card; default for new clusters in RKE2 v1.36+ |
| `ingress-nginx` | Ingress-NGINX only — the UI's "Ingress NGINX" card; legacy (upstream EOL as of 2026-03) |
| `none` | no bundled ingress controller |
| `[traefik, ingress-nginx]` | **Dual Mode** — both side by side; the UI's "Dual Mode" card |

Rules:

- One controller = **string**; two = **list** (list support: the 2026-06+
  RKE2 releases — v1.32.11 / v1.33.7 lines and up).
- The **first** entry becomes the cluster's default IngressClass. During a
  migration keep the incumbent first (`[ingress-nginx, traefik]`) and flip
  the order when you cut over; a fresh dual cluster takes the UI order
  (`[traefik, ingress-nginx]`) — Traefik is born the default.

Background and the official phases:
<https://docs.rke2.io/reference/ingress_migration>.

## Dual Mode — the exact values

Both charts default to host ports 80/443, so a dual deployment must move
one of them. The UI writes this split: Ingress-NGINX keeps 80/443, Traefik
moves to 8000/8443, and Traefik gains a second **Ingress-NGINX
compatibility provider** wired to the migration class
`rke2-ingress-nginx-migration` — the per-workload switch (duplicate a
workload's Ingress with that class; NGINX keeps serving the original).

```yaml
machineGlobalConfig:
  cni: calico
  ingress-controller: [traefik, ingress-nginx]   # dual; first = default class

extraChartValues:
  rke2-traefik:
    ports:
      web:
        hostPort: 8000
      websecure:
        hostPort: 8443
    providers:
      kubernetesIngressNGINX:
        enabled: true
        ingressClass: rke2-ingress-nginx-migration
        controllerClass: rke2.cattle.io/ingress-nginx-migration
```

`extraChartValues` is a raw pass-through into
`spec.rkeConfig.chartValues` — the same slot Rancher uses for the packaged
charts — so anything else you need to pin can ride the same mechanism.

Chart-key gate: the compatibility provider's key was renamed
`kubernetesIngressNginx` → `kubernetesIngressNGINX` in the 2026-06 chart
line (present in the rke2-traefik chart shipped with v1.33.13). On older
RKE2 the lowercase key is the active one; a wrong-case key **silently**
leaves the provider disabled. Inspect your version's chart:

```bash
kubectl -n kube-system get secret sh.helm.release.v1.rke2-traefik.v1 \
  -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip \
  | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["chart"]["values"]["providers"]))'
```

## What lands where (mechanism)

- The values render into the provisioning CR
  (`spec.rkeConfig.machineGlobalConfig` / `spec.rkeConfig.chartValues`) —
  the repo is the UI's equal.
- The Rancher plan drops the RKE2 config onto every node at
  `/etc/rancher/rke2/config.yaml.d/50-rancher.yaml`, verbatim
  (`"ingress-controller": ["traefik","ingress-nginx"]`).
- The RKE2 supervisor deploys one HelmChart per enabled controller
  (`rke2-traefik`, `rke2-ingress-nginx` in kube-system); chartValues for a
  packaged chart arrive as its HelmChartConfig and merge over the chart
  defaults.

## Verify (after build or promotion)

```bash
KUBECONFIG=<cluster> kubectl get ingressclass
#   traefik (default), nginx, rke2-ingress-nginx-migration
KUBECONFIG=<cluster> kubectl -n kube-system get helmchart | grep -E 'traefik|ingress-nginx'
KUBECONFIG=<cluster> kubectl -n kube-system get ds rke2-traefik \
  -o jsonpath='{.spec.template.spec.containers[0].ports}'   # hostPort 8000/8443
ssh <node> 'sudo cat /etc/rancher/rke2/config.yaml.d/50-rancher.yaml'   # the list, verbatim
# functional: an Ingress with class nginx answers on <node>:80; one with
# class rke2-ingress-nginx-migration (or traefik) answers on <node>:8000.
```

## Notes / troubleshooting

- Don't point the compatibility provider at the `nginx` class while
  Ingress-NGINX still serves it — one class, one controller; the bridge
  class is deliberately distinct.
- Single → dual is a `machineGlobalConfig` change: config-hash change, so
  it rolls every machine the same as any other config edit (see UPGRADE.md
  for the taxonomy).
- `none` disables both bundled controllers — only for clusters bringing
  their own ingress stack.
