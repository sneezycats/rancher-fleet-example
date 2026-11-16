# etcd snapshots to an S3-compatible backup target (incl. Google Cloud Storage)

Rancher delegates etcd snapshotting to the downstream RKE2 engine. By default
snapshots are local files on every etcd node (`/var/lib/rancher/rke2/server/db/snapshots`,
cron `0 */5 * * *`, 5 kept per node) — which dies with the etcd nodes. This
guide makes the GitOps Cluster CR write snapshots to an S3-compatible object
store instead/in addition, so a cluster survives total etcd-node loss.

**Provenance of the field list:** `spec.rkeConfig.etcd` is the same slot the
Rancher UI's *etcd* panel writes ("Edit as YAML" lands here too). Field names
below are verified against the live `clusters.provisioning.cattle.io` CRD
schema (Rancher 2.14 line) and the SUSE Rancher docs *Backing up a Cluster*
(§S3 Backup Target) and *RKE2 Cluster Configuration*; the engine flags behind
them are in the RKE2 docs *Backup and Restore* (§S3 Compatible Object Store
Support).

## What lands in the Cluster CR

```yaml
spec:
  rkeConfig:
    etcd:
      snapshotRetention: 5            # LOCAL snapshots kept per etcd node
      snapshotScheduleCron: "0 */5 * * *"
      s3:
        endpoint: "storage.googleapis.com"
        region: "us-central1"
        bucket: "rke2-etcd-snapshots"
        folder: "<per-cluster-prefix>"
        cloudCredentialName: "fleet-default:etcd-s3-creds"
        retention: 10                 # S3 objects kept CLUSTER-WIDE (2.14+)
        # endpointCA: |               # only for private S3 backends w/ custom CA
        # skipSSLVerify: true         # emit only when true (see template note)
```

The chart renders this from an `etcd:` values block that **ships fully
commented**: with it absent, the rendered CR is identical to the chart
without this feature (Rancher injects its own snapshot defaults), so adopting
the chart version is a no-op for existing clusters. Uncomment the block to
opt in; the commented defaults match what Rancher injects anyway, so
enabling it as-is is drift-neutral.

Credential material never appears in git or in the Cluster spec.
`cloudCredentialName` points at a Secret (format `namespace:name`) with:

| key | required | notes |
| --- | --- | --- |
| `accessKey` | yes | GCS: the service account's **HMAC** access key |
| `secretKey` | yes | GCS: the matching HMAC secret |
| `defaultEndpoint`, `defaultRegion`, `defaultBucket`, `defaultFolder`, `defaultEndpointCA`, `defaultSkipSSLVerify` | no | defaults; inline `etcd.s3` spec fields take precedence |

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: etcd-s3-creds
  namespace: fleet-default        # must live in the Rancher LOCAL cluster
type: Opaque
stringData:
  accessKey: "<HMAC-ACCESS-KEY>"
  secretKey: "<HMAC-SECRET>"
```

Create it out-of-band (or via your secret-management tooling); this repo only
references it by name.

## GCS specifics (S3 interoperability)

Cloud Storage speaks the S3 XML API to RKE2/Rancher — no GCP SDK involved:

1. **Bucket**: globally unique name, and keep it **dot-free** (dotted bucket
   names break the wildcard TLS cert under virtual-hosted addressing, which
   RKE2's default `bucket-lookup-type: auto` prefers).
2. **Service account** dedicated to snapshots; grant it
   `roles/storage.objectAdmin` **on that bucket only**.
3. **HMAC keys**: Cloud Console → the bucket → *Interoperability* tab →
   *Create a key for a service account*. Feed the pair into the Secret above.
4. **Endpoint**: `storage.googleapis.com` (the XML API request endpoint).
5. **Region**: Google's docs state the V4-signing region is an AWS-compat
   shim — *any value signs*, the recommendation is the bucket's location
   (e.g. `us-central1`). RKE2's default (`us-east-1`) also works; prefer the
   bucket location for clarity.
6. **Folder**: one per cluster — see the CAUTION below.

## Rules that bite

- **One bucket or folder per cluster.** Rancher populates the cluster's
  snapshot list from *whatever it finds* at the configured target — sharing a
  prefix across clusters cross-lists and cross-prunes.
- **Two retention knobs, different scopes**: `snapshotRetention` = local files
  per node; `etcd.s3.retention` = objects in bucket+folder cluster-wide
  (each schedule cycle uploads one object per etcd node, so size it
  `nodes × cycles`). The `s3.retention` CRD field needs Rancher 2.14+; the
  engine flag `etcd-s3-retention` needs RKE2 ≥ v1.33.4 / v1.34.0 line.
- **Rancher server also needs egress** to the endpoint (it lists bucket
  contents to render the Snapshots tab); etcd nodes need it to upload.
- **Restore from S3**: Rancher's restore flow pulls the chosen snapshot from
  the configured target automatically; a bare `rke2` host-level restore must
  pass the `--etcd-s3-*` flags on the CLI (the kube-system config Secret is
  unavailable that early — RKE2 docs, §S3 Configuration Secret Support).
- Fleet Modified-churn: Rancher's normalizer strips false-valued booleans in
  this block; the chart template emits `skipSSLVerify`/`disableSnapshots`
  only when true (same pitfall class as `machinePools` booleans).

## Verify

```bash
# after the GitRepo syncs, the spec should carry the s3 block:
kubectl -n fleet-default get clusters.provisioning.cattle.io <cluster> \
  -o jsonpath='{.spec.rkeConfig.etcd}' | jq

# an on-demand snapshot should appear in bucket + Snapshots tab:
# Rancher UI → Cluster Management → <cluster> → Snapshots → Snapshot Now
gsutil ls gs://<bucket>/<folder>/
```
