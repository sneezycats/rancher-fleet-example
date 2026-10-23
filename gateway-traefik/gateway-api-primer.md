# Gateway API primer — the objects, in one breath

Vendor-neutral: every Gateway API implementation (Traefik, ingress-nginx
v2, Istio, Envoy Gateway, cloud LB controllers) speaks the same set of
objects. API group `gateway.networking.k8s.io` (`v1` = stable). The CRDs
come from the Gateway API project; a controller must implement the class
you reference.

| CR | Scope | Purpose (one line) | Typical owner |
|---|---|---|---|
| `GatewayClass` | cluster | names the implementation — "which controller serves this class"; the StorageClass analogue | platform team |
| `Gateway` | namespaced | the entry point: listeners (port + protocol + hostname) under one class — the "IP + ports" contract | cluster admin |
| `HTTPRoute` | namespaced | L7 rules: match host/path → forward to a backend Service; attached to a Gateway via `parentRefs` | app team |
| `Service` | namespaced | core Kubernetes object, NOT a Gateway API CR — the backend a route forwards to | app team |

The route family all shares one shape (`parentRefs` in, `backendRefs`
out): `HTTPRoute` and `GRPCRoute` at L7; `TCPRoute` / `TLSRoute` /
`UDPRoute` at L4.

Request path, generically:

```
client -> load balancer / node port -> controller pod
       -> Gateway listener -> HTTPRoute rule -> Service -> app pod
```

Two extras worth knowing early:

- `ReferenceGrant` — unlocks cross-namespace references (e.g. a route in
  namespace A pointing at a Service in namespace B). Denied by default.
- `sectionName` in a route's `parentRefs` — pins the route to ONE named
  listener on the Gateway instead of all compatible listeners.

Runnable example in this folder: `gateway.yaml` (the Gateway) +
`demo-httproute.yaml` (an HTTPRoute) + `demo-whoami.yaml` (backend
Service + pod). For the RKE2 + Traefik specifics — enabling the provider,
who creates the GatewayClass, listener-port traps — see `README.md`.
