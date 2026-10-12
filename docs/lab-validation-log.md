# Lab validation log

Dated, environment-specific proof records for this repo. The READMEs and
docs state the mechanics; this file keeps the evidence trail: what was
run, on what versions, with what observed result. Nothing here is
required to use the repo — it exists so a reader can see *why* a
pitfall note exists and how recently a mechanic was re-verified.

Environment names below refer to a single-node Harvester lab host and
its guest clusters; substitute your own equivalents.

## Gateway API on bundled Traefik — 2026-10-12

Rancher 2.14.3 + Harvester 1.7.x + RKE2 v1.33.13+rke2r1, rke2-traefik
chart 40.1.003, guest cluster `fleetlab5` (3 CP + 3 workers).

- Enabled via `extraChartValues` on the Cluster CR; verified the
  downstream HelmChartConfig and the Traefik DaemonSet args gained
  `--providers.kubernetesgateway`.
- First reconcile failed: bundle-authored GatewayClass `traefik`
  collided with the chart's Helm-owned one —
  `cannot be imported into the current release`. Removed from bundle.
- A hand-created HelmChartConfig blocked the Fleet bundle (Helm-backed
  adoption); after deletion the RKE2 addon controller recreated it —
  confirming RKE2 ownership of that object.
- Chart auto-created a second Gateway (`traefik-gateway`,
  allowedRoutes Same-namespace); suppressed with `gateway.enabled: false`.
- Listener on port 80/HTTP failed: `PortUnavailable — no matching
  entryPoint for port 80 and protocol "HTTP"`. Port 8000 accepted.
- End-to-end proof through the Harvester ingress LB VIP (192.168.1.201,
  pool `lab-lb-pool`, VM namespace `k8s-infra`):
  `curl -H 'Host: whoami.home.sneezycats.com' http://192.168.1.201/`
  → whoami pod echoed the request (X-Forwarded-For: 192.168.1.31);
  unmatched Host → 404. Gateway `Accepted=True Programmed=True`,
  listener `attachedRoutes=1`; HTTPRoute `Accepted=True
  ResolvedRefs=True`; Fleet GitRepo 1/1 Ready.

## Harvester L4 LB GitOps — 2026-10-12

Same host/cluster. IPPool `lab-lb-pool` (.200–.202, kept outside the
Kea DHCP scope .100–.199), split LBs `fleetlab5-apiserver` (.200,
healthCheck 6443) and `fleetlab5-ingress` (.201, healthCheck 80).

- Single LB with listeners 6443+80+443 and healthCheck.port=6443:
  workers (no 6443) were excluded and the VIP's :80 went dead —
  healthCheck.port gates the whole backend set. Split LBs fixed it.
- After narrowing the apiserver LB to 6443-only, the VIP went silent:
  the owned Service kept the old 3-port shape (controller adds ports,
  never prunes). Deleted the LB; Fleet recreated it with the same pool
  IP .200; `curl -k https://192.168.1.200:6443/version` → 401 (serving).
- Earlier same-day pass with one combined LB: VIP .201:80 → 404 from
  traefik (proving the L4 path), apiserver 401.

## Cluster upgrade mechanics (UPGRADE.md) — 2026-10-04

Rancher 2.14.3 + Harvester 1.7.x. Control-plane 1→3 and workers 1→2 in
one change: 3 new VMs, 5/5 nodes Ready ~9 min after push.

## Longhorn rolls with data (longhorn-lifecycle.md) — 2026-10-05

Rancher 2.14.3 + Longhorn 1.11.2. Three full serial rolls of all six
machines with volume data aboard, verified by created-at identity,
uninterrupted writer counters, and rebuilt 3/3 replica placement.
Three regimes in one day: with the optional lhcc controller present
(6.1 → 6.2), with zero controller (6.2 → 6.1), and with the vendor
eviction policy (`block-for-eviction-if-contains-last-replica`) enabled
for the maintenance window (6.1 → 6.2, including a single-replica
volume — the vendor evicted its last replica off the doomed node before
allowing the drain; volume stayed attached and healthy). Data safety
was vendor-native in all regimes. One real gap: dead nodes' node CRs
and replicas do NOT self-clean (residue cleanup step in the doc).

## Ingress Dual Mode (ingress-dual-mode.md) — 2026-10-08

Rancher 2.14.3 + Harvester 1.7.x + RKE2 v1.33.13, fresh dual-controller
cluster build; both controllers confirmed serving; the verification
checks in the doc are from that round.

## GitRepo workspace A/B + cluster identity (gitrepo-fleet-clustertemplate.md) — 2026-10-09

Rancher 2.14.3. Same template chart deployed four ways (only the
GitRepo workspace/targets differed), single-node all-role instance:

1. fleet-local, no targets → Cluster CR rendered on the management API
   → cluster bootstraps (the bootstrap path).
2. fleet-default, no targets → `Ready=True, 0/0 clusters`, deploys
   nothing (no `default` clusterGroup in fleet-default on 2.14.3).
3. fleet-default, target `local` → 0 targets, nothing.
4. fleet-default, target a registered downstream cluster → ErrApplied:
   `no matches for kind "Cluster" in version "provisioning.cattle.io/v1"`
   (CRD absent downstream).

ClusterGroup A/B: a ClusterGroup with no selector matched nothing
(`clusterCount: 0` — no empty-selector match-all); a label-selector
group delivered the template bundle to the downstream agent, same
`no matches for kind "Cluster"` failure.

Cluster identity: management cluster id (`c-m-...`) is re-minted on
every same-name rebuild; pinning component targets to it strands them
at 0/0. Pinning `targets: [{clusterName: <name>}]` re-attached with
zero repo changes through a full delete/rebuild cycle (~6 min rebuild,
instant re-attach, verified with a canary bundle).

## Promotion model (promotion-model.md)

- Branch pinning: two GitRepos, same repo+path, different branches →
  distinct bundles, zero collision.
- Config change as one commit → Fleet sync → CRs change → CAPI rolls
  machines; data layer continuous through the rollout.
- Storage change as its own commit → Fleet upgraded Longhorn in place
  (1.11.2 → 1.12.1: release adopted, revision bumped, data plane
  untouched, verify.sh green throughout).
- Node loss mid-roll with ≥3 replicas across ≥3 workers: data intact,
  replicas rebuilt onto the new generation.
- All of it by `git push` — no UI clicks.

## Bare-metal custom clusters (baremetal-custom-clusters.md) — 2026-10-05

Rancher 2.14.3. The template GitRepo (`fleet-proxy-custom-templates`)
rendered the chart through Fleet; the Cluster CR was created
(`c-m-lvfjtkfs`, phase: progressing / waiting for at least one control
plane, etcd — the correct custom-cluster lifecycle). Empty `name:`
yielded the release-derived CR name
`fleet-proxy-custom-templates-cluster-templates-48f64`. The `fleetlab1`
template GitRepo was observed in the same NotReady-while-waiting state.
Node join via registration command: pending as of that date.

## Golden-image generations (custom-sl-micro-longhorn-image.md)

| Version | Date | Changes over predecessor |
|---|---|---|
| v3d | 2026-09-10 | First working golden: disk-mount + autopatch-suppression units, `/dev/null` masks. Discovered the `/usr/local/lib/systemd` trap (units there are "enabled" yet never queued — resolve before the boot transaction mounts `/usr/local`). |
| v3e | 2026-09-11 | Canonical layout: everything under `/etc/systemd/system`; disk unit → `basic.target.wants`, autopatch unit → `multi-user.target.wants`; verified live on a v3e node (unit starts at boot, disk mounted). |
| v3f | 2026-09-12 | Removed baked-in ssh user/keys — the RKE2 node-driver delivers keys via `user_data`; baked keys are stale access that outlives the operator. |
| v3g | 2026-09-21 | Added the `health-checker.service` mask — fixes the SL Micro 6.2 upstream cloud-final race (health-checker↔cloud-final cycle randomly kills cloud-final → node-driver `install.sh` never runs → ~half the nodes never join; `systemctl start cloud-final` unblocks). `/home` left `ro=false` (transactional runtime remounts it rw anyway; the flip is needed at bake time so uploads land). Recipe stable from here — later generations re-tag only. |
| 6.0 / 6.1 ports | 2026-09-25 | Identical recipe to v3g, plus `btrfs property set / ro false` during bake: 6.0/6.1 have no writable `/etc` subvol — `/etc` is an fstab overlay whose lower layer lives on the btrfs root subvol `@` (`ro=true` by default). The flip is required before `virt-customize --upload` writes; at runtime `/etc` stays writable through the overlay (upper in `/var/lib/overlay`, on the rw `/var` subvol). |
| v4g | 2026-09-26/27 | Re-tag of v3g — byte-identical output; the tag iterates the golden-image generation, not content (it drove the fleet image-hop cycle, 6.0→6.1→6.2). Verify a re-tag by exact byte size: 6.0 = 1324875776, 6.1 = 1345191936, 6.2 = 1451687936. |

## Reference-lab artifact locations (bake guide §8)

The bake guide is written generically; the reference lab kept these on a
dedicated Linux build host under `~/slmicro-build/`:

| Artifact | Reference location |
|---|---|
| Firstboot script (source) | `slmicro-longhorn-setup.sh` (uploaded as `/usr/local/sbin/longhorn-setup.sh`) |
| Systemd units (sources) | `slmicro-longhorn-setup.service` + `slmicro-disable-autopatch.service` |
| Bake driver scripts | `bake-v4g.sh` (6.2), `bake-v4g-660.sh` (6.0), `bake-v4g-661.sh` (6.1); v3g and earlier kept alongside |
| Built golden images | `slmicro-{6.0,6.1,6.2}-longhorn-v4g.qcow2` (v3g retained) |
| Staging / archive helper | `image-store.sh` — LOCAL/CDI/ARCHIVE tiers + hash-checked manifest |
| CDI import walkthrough | `cdi-vmimage-import-howto.md` (lab doc set, not in this repo) |
| Source SL Micro images | `SL-Micro.x86_64-6.{0,1,2}-Default-qcow-GM*.qcow2` (licensed copies) |

The lab's scripted import path stages the finished qcow2 into the CDI
root on the build host (served by a small static HTTP server, `:8081`)
and imports it as a `VirtualMachineImage` with `sourceType: download`.
The lab's migratable storage class is `harvester-longhorn-single-mig`.
