# lhcc-rbac — guest-cluster identity bundle

Ships the **longhorn-capi-controller's least-privilege guest identity** into
every labeled cluster: SA `lhcc-eviction-agent` + never-expiring token +
ClusterRole + binding. Content is maintained upstream in
`longhorn-capi-controller/config/rbac/workload_role.yaml` — the templates here
are copies; diff and re-copy on upstream change.

**When you need it:** only when running the longhorn-capi-controller on the
management cluster. Longhorn alone with >= 3 replicas across >= 3 workers
survives node replacement natively (validated) — this bundle is inert
otherwise.

**Why it must exist:** the controller on the management cluster can only
protect a cluster it can reach with a credential. Without this bundle, a
provisioned cluster gets Longhorn but no eviction agent — coverage silently
absent exactly when a node is replaced.

**Pairing step (management side):** after this bundle converges, run
`lhcc-setup-workload-identity.sh` from the longhorn-capi-controller repo
(`--workload-kubeconfig <admin-kc> --cluster <id>`) to create the
`<cluster>-lhcc-kubeconfig` Secret the controller resolves. Prefer pointing
`--server` at a stable LB/DNS endpoint.

**Version compatibility:** bump `Chart.yaml` version + re-copy templates when
the upstream bundle changes; the eviction controller must be running v0.11.0+.