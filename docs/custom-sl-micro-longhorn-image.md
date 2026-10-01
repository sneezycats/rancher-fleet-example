# Custom SUSE Linux Micro Image — Automatic Longhorn Data-Disk Mount

**Audience:** Linux administrators building a Harvester/RKE2 node image.
**Outcome:** a SUSE Linux Micro (SL Micro) qcow2 golden image that, on first boot, automatically
formats and mounts a dedicated Longhorn data disk at `/var/lib/longhorn` — so every node created
from the image (including replacement nodes during upgrades) has Longhorn storage ready without
per-node manual steps.

**Tested with:** SL Micro 6.0, 6.1 and 6.2 x86_64 on Harvester 1.8.x with RKE2 guest clusters
(the image-build procedure is identical across all three).
**Toolchain:** `libguestfs` (virt-customize/guestfish) on any Linux build host.
**Companion doc:** `image-bake.md` (same directory) — the change-set vs upstream; this
document is the full step-by-step procedure.

> **Provenance:** this guide documents a reference lab. Paths like
> `build:~/…` and references to companion documents outside this repo
> (`longhorn-maintenance-behavior.md`, `cdi-vmimage-import-howto.md`,
> `harvester-longhorn-single-mig-sc.yaml`, `docs/bootcmd-vs-runcmd.md`)
> point at that lab's build host and doc set — substitute your own
> equivalents.

---

## 1. Why bake it into the image?

| Delivery mechanism | Works for RKE2 node-driver VMs? | Why |
|---|---|---|
| Terraform/CAPI `user_data` with `runcmd:`/`bootcmd:` | ❌ | The Rancher RKE2 node-driver rebuilds cloud-init from a whitelist; only `users`/`ssh` survive. See [harvester/harvester#3392](https://github.com/harvester/harvester/issues/3392). |
| `harvester_config.user_data` (machine config) | ❌ | Same stripping — verified: the HarvesterConfig CR carried the directives, the VM's consumed user-data did not. |
| `machine_global_config` | ❌ | That is RKE2 server configuration (CNI, feature gates), not a boot-time hook. |
| **Firstboot systemd unit in the image** | ✅ | Runs independently of Rancher, survives node replacement, idempotent. |

The last row is the point: a node **replaced** during an upgrade boots the same image and re-runs
the firstboot unit. When the data disk is re-attached (or re-created and then re-populated by
Longhorn's own replication), the mount is ready with no operator involvement. This is a prerequisite
for the detach/reattach Longhorn data-preservation pattern (`longhorn-maintenance-behavior.md` —
in the Harvester doc set) and for running Longhorn replicas on a dedicated disk rather than the
OS volume.

---

## 2. Prerequisites

### 2.1 Build host (Linux)

`libguestfs` is Linux-only — there is no macOS build. Any x86_64 Linux host or VM works;
Debian/Ubuntu is shown here.

```bash
sudo apt-get update
sudo apt-get install -y libguestfs-tools qemu-utils qemu-system-x86 ca-certificates
```

Notes:
- `libguestfs` falls back to TCG software emulation when `/dev/kvm` is absent — slower but
  functional. A VM with nested virtualization enabled is comfortable; a bare-metal host is fastest.
- Run all `virt-*`/`guestfish` commands as root (`sudo -E`); the appliance needs readable host
  kernel images.

### 2.2 Source image

A pristine SL Micro qcow2 for your target version (6.2: `SL-Micro.x86_64-6.2-Default-qcow-GM.qcow2`;
6.0 ships as `…-GM2`, 6.1 as `…-GM`; ~1.3–1.4 GB; licensed copies live in `build:~/slmicro-build/` —
see §8). Keep it read-only and work on a copy — the build mutates the file in place.

### 2.3 The three files to bake

**`slmicro-longhorn-setup.sh`** — the firstboot script (baked into the image as
`/usr/local/sbin/longhorn-setup.sh`; verbatim from `build:~/slmicro-build/`):

```bash
#!/usr/bin/env bash
# Firstboot setup for a Longhorn data disk on SL Micro.
# Baked into the golden VM image. Runs ONCE on first boot (guarded by a marker).
# Idempotent: safe to re-run (blkid guard prevents re-format).
#
# Purpose: RKE2 node-driver strips custom cloud-init from user_data, so the
# format+mount of /dev/vdc (the Longhorn data disk) cannot be delivered per-VM.
# Instead it lives in the image and runs on first boot.
#
# Behavior:
#   1. Wait for /dev/vdc to appear (Harvester attaches it at create; may be late).
#   2. If /dev/vdc has no filesystem, mkfs.ext4 it and set a fixed label LONGHORN.
#   3. Write /etc/fstab entry using UUID (device-name independent).
#   4. Create /var/lib/longhorn and mount it now (and on every boot via fstab).
#   5. Touch a completion marker so this only runs meaningfully once,
#      but remains idempotent if the node is replaced with the disk reattached.

set -euo pipefail

DISK="/dev/vdc"
MOUNTPOINT="/var/lib/longhorn"
MARKER="/var/lib/longhorn-setup.done"
FSTAB_TAG="LONGHORN"
UNIT="slmicro-longhorn-setup.service"
# Enable symlink in /etc (honored by systemd at boot). /etc is ro IN THE IMAGE on
# SL Micro 6.0/6.1 but writable + persistent at RUNTIME via transactional-update
# overlay, so self-arranging here makes the unit durable across reboots.
ETC_WANTS="/etc/systemd/system/multi-user.target.wants/$UNIT"
UNIT_SRC="/usr/local/lib/systemd/system/$UNIT"

log() { echo "[longhorn-setup] $*"; }

# --- Self-arrange enablement (idempotent): so a reboot keeps this unit running ---
if [ -f "$UNIT_SRC" ] && [ ! -e "$ETC_WANTS" ]; then
  mkdir -p "$(dirname "$ETC_WANTS")"
  ln -s "$UNIT_SRC" "$ETC_WANTS" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  log "self-enabled unit via $ETC_WANTS"
fi

# --- Wait for the disk (Harvester attaches data disk at VM create; may appear late) ---
log "Waiting for ${DISK} ..."
for i in $(seq 1 60); do
  if [ -b "${DISK}" ]; then
    break
  fi
  sleep 1
done
if [ ! -b "${DISK}" ]; then
  log "ERROR: ${DISK} never appeared after 60s. Longhorn data disk not configured; skipping."
  # Do NOT create a failure marker; a later boot (or reattach) can retry.
  exit 0
fi

# --- Format only if blank (idempotent) ---
if ! blkid "${DISK}"; then
  log "Formatting ${DISK} as ext4 (label ${FSTAB_TAG})"
  mkfs.ext4 -L "${FSTAB_TAG}" "${DISK}"
else
  log "${DISK} already has a filesystem; leaving it intact."
fi

# Label may not be set if the FS pre-dates this script (e.g. prior run). Set it idempotently.
if ! blkid -s LABEL -o value "${DISK}" | grep -qx "${FSTAB_TAG}" 2>/dev/null; then
  e2label "${DISK}" "${FSTAB_TAG}" 2>/dev/null || log "note: could not set label (non-root?)"
fi

# --- Resolve UUID for fstab (device-name independent) ---
UUID="$(blkid -s UUID -o value "${DISK}")"
if [ -z "${UUID}" ]; then
  log "ERROR: could not read UUID of ${DISK}"; exit 1
fi

mkdir -p "${MOUNTPOINT}"

# --- fstab entry (idempotent) ---
if ! grep -qs "${MOUNTPOINT}" /etc/fstab; then
  echo "UUID=${UUID} ${MOUNTPOINT} ext4 defaults,noatime 0 2" >> /etc/fstab
  log "Added fstab entry: UUID=${UUID} ${MOUNTPOINT}"
else
  log "fstab already has ${MOUNTPOINT} entry."
fi

# --- Mount now (deterministic): prefer the systemd unit generated from fstab ---
mkdir -p "${MOUNTPOINT}"
if ! mountpoint -q "${MOUNTPOINT}"; then
  # Let systemd mount it (from fstab) so it's properly tracked as a .mount unit;
  # fall back to mount -a if the unit isn't ready yet (early first boot).
  systemctl start "var-lib-longhorn.mount" 2>/dev/null \
    || mount "${MOUNTPOINT}" 2>/dev/null \
    || true
fi
# Recreate the mount unit state if we mounted manually so a reboot tracks it.
udevadm settle 2>/dev/null || true

touch "${MARKER}"
log "Done. Longhorn data disk ready at ${MOUNTPOINT}."
```

> The script's `self-arrange` block covers *manual* (non-baked) installs; on baked images the
> unit and its `basic.target.wants` symlink are already in `/etc`, so it is a no-op there.

**`slmicro-longhorn-setup.service`** — the unit that runs it once per boot:

```ini
[Unit]
Description=SL Micro Longhorn data disk setup (format+mount /dev/vdc)
# Runs after the disk may appear and after local filesystems are up.
# WantedBy=basic.target (NOT multi-user.target): the multi-user chain has an
# ordering cycle on Harvester/RKE2 images (cloud-final -> health-checker ->
# multi-user.target) and systemd's cycle-breaking deletes late wants — observed
# on live nodes where this unit was enabled but never started. basic.target is
# ordered before that chain and outside the cycle.
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/longhorn-setup.sh
TimeoutStopSec=90

[Install]
WantedBy=basic.target
```

**`slmicro-disable-autopatch.service`** — suppresses SL Micro's self-patching before it can fire:

```ini
[Unit]
Description=Disable SL Micro automatic patching (transactional-update) and rebootmgr
Documentation=man:transactional-update(8)
# Run early, alongside the disk-setup unit (same ordering; After=multi-user.target
# creates a dependency cycle with the WantedBy= link and systemd silently drops
# the job — observed on live nodes where the unit existed, was enabled, and
# never started).
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
# transactional-update.timer: SL Micro's default patch policy — runs
# transactional-update daily and transactional-update.service applies
# snapshots + may schedule a reboot. In an environment where patching is
# orchestrated (Rancher/Fleet, CAPI node replacement), the node must not
# patch or reboot itself on a timer.
ExecStart=/usr/bin/systemctl disable --now transactional-update.timer
ExecStart=/usr/bin/systemctl disable --now transactional-update.service
# rebootmgr: SL Micro's reboot coordination daemon — decides WHEN a pending
# reboot (such as one requested by a transactional-update) happens. With the
# timer disabled nothing requests reboots, but disable the decision-maker too.
ExecStart=/usr/bin/systemctl disable --now rebootmgr.service
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

**Why `basic.target`, not `multi-user.target`:** the multi-user chain on Harvester SL Micro images
has an ordering cycle (`cloud-final → health-checker → multi-user.target`) and systemd breaks it by
deleting late jobs. Enabling the unit on `basic.target` (which is reached *before* that chain and is
outside the cycle) sidesteps the problem entirely. Verified live 2026-09-11 on v3e nodes: unit starts
at boot, disk mounted.

**Design decisions worth understanding before you change anything:**

- **`/dev/vdc`** is the first *data* disk on Harvester SL Micro VMs: the boot image occupies
  `vda`/`vdb` partitions, so the first blank data disk appears as `vdc`. If you re-attach a disk
  later it may renumber (`vdd`, `vde`) — which is why the fstab entry uses the **UUID**, not the
  device path.
- **The `blkid` guard** makes the script idempotent and non-destructive: an already-formatted disk
  (i.e. one holding Longhorn data) is never re-formatted.
- **The script lives in `/usr/local/sbin`** (the `@/usr/local` btrfs subvolume) so it survives
  SL Micro `transactional-update` snapshots; the unit lives in `/etc/systemd/system` (`@/etc`
  subvolume) for the same reason. Do not put them in `/usr/bin` or `/usr/sbin`.
- **`systemctl start var-lib-longhorn.mount`** (rather than a bare `mount`) makes systemd track the
  mount; a bare mount raced the fstab generator and left the unit inactive in earlier iterations.
- The disk must exist at first boot — provision the VM with the data disk attached (see §5 for the
  storage-class requirement).

---

## 3. Bake the image

> **Reference implementation:** `bake-v4g.sh` (SL Micro 6.2), plus `bake-v4g-660.sh` (6.0)
> and `bake-v4g-661.sh` (6.1) — all in `~/slmicro-build/` on the build host. The steps
> below are exactly what those scripts do, in order: run the script, or follow along —
> then verify (§4).

```bash
# 1. Work on a COPY — never the pristine source image.
cd ~/slmicro-build
SRC=SL-Micro.x86_64-6.2-Default-qcow-GM.qcow2     # 6.0: …-GM2.qcow2; 6.1: …-GM.qcow2 (§8)
OUT=slmicro-6.2-longhorn-v4g.qcow2                # naming: slmicro-<version>-longhorn-<generation>
rm -f "$OUT"; cp --reflink=auto "$SRC" "$OUT"
```

```bash
# 2. Flip the subvols the bake needs writable (see the note below for why).
#    6.2: /home.  6.0/6.1: /home AND / (their /etc overlay sits on the ro @ subvol).
export LIBGUESTFS_BACKEND=direct        # direct appliance backend
sudo -E guestfish -a "$OUT" -i <<'EOF'
command "btrfs property set /home ro false"
command "btrfs property set / ro false"          # 6.0/6.1 only — omit on 6.2
command "btrfs property get /home"
EOF
```

```bash
# 3. File operations only: mkdir/upload/chmod. `--no-selinux-relabel` because a
#    whole-image relabel is impossible on the read-only root (step 5 restores the
#    contexts that matter). Do NOT use --run-command — any command fails inside the
#    SL Micro transactional guest, even `echo`.
sudo -E virt-customize -a "$OUT" --no-selinux-relabel \
  --mkdir /usr/local/sbin \
  --upload slmicro-longhorn-setup.sh:/usr/local/sbin/longhorn-setup.sh \
  --chmod 0755:/usr/local/sbin/longhorn-setup.sh \
  --upload slmicro-longhorn-setup.service:/etc/systemd/system/slmicro-longhorn-setup.service \
  --upload slmicro-disable-autopatch.service:/etc/systemd/system/slmicro-disable-autopatch.service
```

```bash
# 4. Enable the units. Do NOT use `systemctl enable` — it fails inside the SL Micro
#    transactional root. Create the enable symlinks via guestfish instead:
#    - disk unit → basic.target.wants (sidesteps the multi-user ordering cycle)
#    - autopatch unit → multi-user.target.wants
#    - /dev/null MASKS for transactional-update.timer/.service, rebootmgr.service AND
#      health-checker.service (health-checker is the cloud-final race fix — §3.1;
#      masks are honored at unit-load time, immune to any ordering-cycle breakage)
#    NOTE: everything here lives under /etc/systemd/system — the unit files, wants
#    symlinks, and masks must be transaction-time resolvable. /usr/local/lib/systemd
#    is mounted too late for systemd's boot-transaction resolution and units there
#    are silently dropped (verified: v3d units "enabled" yet never queued at boot).
sudo -E guestfish -a "$OUT" -i <<'EOF'
mkdir-p /etc/systemd/system/basic.target.wants
ln-sf /etc/systemd/system/slmicro-longhorn-setup.service \
       /etc/systemd/system/basic.target.wants/slmicro-longhorn-setup.service
ln-sf /etc/systemd/system/slmicro-disable-autopatch.service \
       /etc/systemd/system/multi-user.target.wants/slmicro-disable-autopatch.service
rm-f /etc/systemd/system/transactional-update.timer
ln-sf /dev/null /etc/systemd/system/transactional-update.timer
rm-f /etc/systemd/system/transactional-update.service
ln-sf /dev/null /etc/systemd/system/transactional-update.service
rm-f /etc/systemd/system/rebootmgr.service
ln-sf /dev/null /etc/systemd/system/rebootmgr.service
rm-f /etc/systemd/system/health-checker.service
ln-sf /dev/null /etc/systemd/system/health-checker.service
EOF
```

```bash
# 5. SELinux: restorecon the NEW paths (whole-image relabel is impossible — / is ro).
sudo -E guestfish -a "$OUT" -i <<'EOF'
sh "command -v restorecon >/dev/null && restorecon -R /etc/systemd/system/slmicro-longhorn-setup.service /etc/systemd/system/slmicro-disable-autopatch.service /usr/local/sbin/longhorn-setup.sh || true"
EOF
```

> **Why the flips — and what they do NOT change.** `/home` is flipped on **every**
> generation: the node driver provisions its user + ssh key into `/home` via
> `user_data`, which needs the subvol writable. The `/` flip appears **only** in the
> 6.0/6.1 scripts — a bake-time convenience for those versions' layout (their `/etc`
> overlay's lower layer sits on the `@` subvol); nothing mounts `/` writable at
> runtime. On a booted node from any generation, `findmnt -n -o OPTIONS /` shows
> `ro` — the OS root is immutable by design (patching is by image replacement, §1).

**About the third file — `slmicro-disable-autopatch.service`:**

SL Micro's default patch policy runs `transactional-update` on a **daily timer** and will patch
the node and reboot it — at whatever time the timer fires, including production hours, without
asking anyone. On nodes whose patching is orchestrated (Rancher/Fleet, CAPI machine replacement),
that is wrong: the node must not patch or reboot itself.

This unit disables `transactional-update.timer`, `transactional-update.service` and
`rebootmgr.service` on every boot. It must live in the **image** — cloud-init cannot deliver it:
the RKE2 node-driver strips `runcmd:`/`write_files:` (and even `bootcmd:`) from `user_data`
(see `docs/bootcmd-vs-runcmd.md` in the terraform module), and we
verified on live nodes that a `bootcmd:`-delivered `systemctl disable` never runs.

If your patching strategy differs (e.g. you *want* transactional-update but only in a maintenance
window), adjust the unit instead of removing it — the default policy is the surprise, not the
suppression.

**Known pitfalls:**

- `virt-customize --run-command` (**any** command, even `echo`) fails inside the SL Micro guest with
  exit 1 — a transactional-root exec issue. Stick to `--upload`/`--mkdir`/`--chmod` file operations
  and use `guestfish` for symlinks or anything that must execute.
- `virt-customize`'s SELinux relabel step would `touch /.autorelabel` and error **read-only** on
  SL Micro — that is why step 3 passes `--no-selinux-relabel`. Without the flag the error is still
  benign (the files are written before it), but keep the flag, and keep step 5's `restorecon`.
- If `guestfish` reports it cannot find the root filesystem, list partitions with
  `guestfish -a image run : list-filesystems` and mount the btrfs root (typically `/dev/sda3`).

---

## 3.1 Bake version history (what changed per golden image)

| Version | Era | Changes over predecessor |
|---|---|---|
| v3d | 2026-09-10 | First working golden: disk-mount + autopatch-suppression units, `/dev/null` masks. Discovered the `/usr/local/lib/systemd` trap (units there are "enabled" yet never queued — resolve before the boot transaction mounts `/usr/local`). |
| v3e | 2026-09-11 | Canonical layout: everything under `/etc/systemd/system`; disk unit → `basic.target.wants`, autopatch unit → `multi-user.target.wants`; verified live on a v3e node. |
| v3f | 2026-09-12 | Removed baked-in ssh user/keys — the RKE2 node-driver delivers keys via `user_data`; baked keys are stale access that outlives the operator. `cwsneezy` key restored separately in the lab. |
| v3g | 2026-09-21 | Added the **`health-checker.service` mask** — fixes the SL Micro 6.2 upstream cloud-final race (health-checker↔cloud-final cycle randomly kills cloud-final → node-driver `install.sh` never runs → ~half the nodes never join; `systemctl start cloud-final` unblocks). `/home` left `ro=false` (transactional runtime remounts it rw anyway; the flip is needed at bake time so uploads land). The recipe is stable from here — later generations re-tag it only (v4g). |
| 6.0 / 6.1 ports | 2026-09-25 | Identical recipe to v3g, **plus** `btrfs property set / ro false` during bake: 6.0/6.1 have **no writable `/etc` subvol** — `/etc` is an fstab *overlay* whose **lower layer lives on the btrfs root subvol `@`** (`ro=true` by default). The flip is required before the `virt-customize --upload` writes; at runtime `/etc` stays writable through the overlay (upper in `/var/lib/overlay`, on the rw `/var` subvol), so RKE2 config writes work normally. `longhorn-setup.sh` + the four masks are identical. |
| v4g | 2026-09-26/27 | **Re-tag of v3g** — byte-identical output; the tag iterates the golden-image *generation*, not content (it drove the fleet image-hop cycle, 6.0→6.1→6.2). Verify a re-tag by exact byte size: 6.0 = 1324875776, 6.1 = 1345191936, 6.2 = 1451687936. Current built images: `slmicro-{6.0,6.1,6.2}-longhorn-v4g.qcow2`. |

**Why masks instead of a disable unit for the patch suppression:** `/dev/null` masks are honored at unit-load time, immune to any ordering-cycle breakage — this is the suppression that actually works on live nodes (see §3).

**The four masks on a v3g/v4g node** (verify with `systemctl list-unit-files | grep -E "transactional|rebootmgr|health"`):
`transactional-update.timer`, `transactional-update.service`, `rebootmgr.service`, `health-checker.service` — all `masked`.

**No baked credentials on v3g+:** user management happens entirely via node-driver `user_data`; nothing image-level grants access.

---

## 4. Verify

### 4.1 Structure check (no boot required)

```bash
sudo -E guestfish --ro -a slmicro-6.2-longhorn-v4g.qcow2 -i <<'EOF'
sh "ls -la /usr/local/sbin/longhorn-setup.sh"
sh "ls -la /etc/systemd/system/slmicro-longhorn-setup.service"
sh "ls -la /etc/systemd/system/basic.target.wants/slmicro-longhorn-setup.service"
sh "ls -la /etc/systemd/system/ | grep -E 'transactional|rebootmgr|health'"
EOF
```

Expect: the script, the unit, the basic.target wants symlink, and all four
`/dev/null` masks present — `transactional-update.timer`,
`transactional-update.service`, `rebootmgr.service`, `health-checker.service`
(§3.1).

### 4.2 Live-boot check (the real proof)

Boot a VM from the image **with a data disk attached** (§5), then on the node:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/vdc   # ext4, LABEL=LONGHORN
findmnt /var/lib/longhorn                              # /dev/vdc mounted
grep longhorn /etc/fstab                               # UUID=... entry
systemctl status slmicro-longhorn-setup.service        # active (exited), SUCCESS
cat /var/lib/longhorn-setup.done                       # marker exists
```

### 4.3 Replacement check (the pattern's whole point)

Delete the VM (keeping/re-creating the data disk) and boot a new VM from the same image with the
same disk: the unit must find the existing filesystem via `blkid`, skip formatting, and mount it.
Longhorn data on that disk is preserved.

---

## 5. Upload to Harvester

Upload the finished qcow2 as a VM image (Harvester UI → Images → Create → Upload) in your target
namespace, and note the generated image name (`image-XXXXX`).

**Storage-class requirement (critical):** a Longhorn-backed data disk that KubeVirt presents as a
raw *block* volume must use a StorageClass with **`migratable: "true"`**. With `migratable: false`,
Longhorn serves RWX volumes over NFS via a share-manager and no `/dev` block device appears — the
firstboot script skips (`no /dev/vdc`) and you get
`special device ... does not exist` errors. See `harvester-longhorn-single-mig-sc.yaml` (in the
Harvester doc set) for a migratable single-node example; the lab storage class is
`harvester-longhorn-single-mig`.

> **Scripted alternative (what the lab uses):** stage the finished qcow2 into the CDI root on the
> build host (served by `headserver.py` on :8081) and import it as a `VirtualMachineImage` with a
> flat `sourceType: download` — name chosen by you, `displayName` = the chart's `imageName`.
> Full walkthrough: `cdi-vmimage-import-howto.md`. Either path lands the same VMI; the CDI path is
> scriptable and survives rebuilds.

---

## 6. Terraform wiring

```hcl
harvester_image_name      = "image-XXXXX"                    # the golden image
longhorn_disk_gb          = 100                              # per-worker data disk size
longhorn_storage_class    = "harvester-longhorn-single-mig"  # migratable=true SC
```

---

## 7. Single-disk note (when you DON'T need this image)

If your Longhorn nodes store replicas on the **OS volume** instead of a dedicated disk (the
"single-disk" pattern), no custom image is needed at all: Longhorn's default disk path is
`/var/lib/longhorn` on the root filesystem, and stock SL Micro images work as-is. The dedicated-disk
pattern above remains valuable when you want replica data isolated from OS churn, larger per-node
storage than the boot disk, or the detach/reattach preservation pattern. Both patterns are
validated with [longhorn-capi-controller](https://github.com/sneezycats/longhorn-capi-controller).

---

## 8. Artifacts

Lab artifacts below live on the build host; adjust paths for your environment.

| Artifact | Location |
|---|---|
| Firstboot script (source) | `build: ~/slmicro-build/slmicro-longhorn-setup.sh` (uploaded as `/usr/local/sbin/longhorn-setup.sh`) |
| Systemd units (sources) | `build: ~/slmicro-build/slmicro-longhorn-setup.service` + `slmicro-disable-autopatch.service` |
| Bake driver scripts (current) | `build: ~/slmicro-build/bake-v4g.sh` (6.2), `bake-v4g-660.sh` (6.0), `bake-v4g-661.sh` (6.1); v3g and earlier kept alongside |
| Built golden images (current) | `build: ~/slmicro-build/slmicro-{6.0,6.1,6.2}-longhorn-v4g.qcow2` (v3g retained) |
| Staging / archive helper | `build: ~/slmicro-build/image-store.sh` — LOCAL/CDI/ARCHIVE tiers + hash-checked manifest |
| Import walkthrough | `cdi-vmimage-import-howto.md` (build: `~/harvester/`) |
| VMI (Harvester) | displayName `sl-micro-longhorn-{6.0,6.1,6.2}-<generation>` (e.g. `…-v4g`) — must match the chart `imageName` (§5; give the VMI the same name to keep name and displayName aligned) |
| Source SL Micro images | `build: ~/slmicro-build/SL-Micro.x86_64-6.{0,1,2}-Default-qcow-GM*.qcow2` (licensed copies) |
