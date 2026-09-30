# Golden image: the change-set vs upstream

Purpose: one image for both control-plane and worker nodes; runtime OS root
immutable; patching done by image replacement (the git hop), never in place.

> Step-by-step procedure (build host → bake → verify → import):
> [`custom-sl-micro-longhorn-image.md`](custom-sl-micro-longhorn-image.md) in this directory.

## Changes vs the upstream qcow

1. **Subvol writes**: btrfs `ro=false` on `/home` (driver user provisioning);
   `/` is left stock-ro at RUNTIME on current generations (fstab `ro` +
   subvol `ro=true` = not remountable even as root). Bake-time `ro=false` on
   `/` also existed in some generations — harmless; runtime mount stays ro.
2. **Longhorn setup unit** (`/etc/systemd/system/…`) -> `basic.target.wants`
   — creates the Longhorn directory tree at boot. Units must live in /etc: a
   unit under /usr/local/lib/systemd/system is silently dropped.
3. **Autopatch suppression** unit — kills transactional-update + rebootmgr.
4. **Masks -> /dev/null**: `transactional-update.{timer,service}`,
   `rebootmgr.service`, `health-checker.service` — the health-checker mask is
   the cloud-final race fix (its cycle with systemd randomly killed
   cloud-final, breaking node bootstrap ~50% of the time on stock images).
5. **restorecon** on the new paths (no whole-image relabel; `/` is ro).
6. **Deliberately NOT baked**: ssh keys/user (driver `user_data` delivers
   them), resolvers (DHCP option 6).

## Bake mechanics

Copy the bake script per upstream version (bake-<version>-*.sh style), swap
`SRC`/`OUT` tags, run (guestfish + virt-customize), stage the qcow behind a
static URL, import on Harvester as a VMImage with a flat
`sourceType: download`, the right storage class (migratable), and
`displayName` = the chart's `imageName`.

## Sanity check a re-tag

A re-tag produces a byte-identical file size to its previous generation.
Verifying an image really changed: compare sizes or a sha256 against the
previous generation.