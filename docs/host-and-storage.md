# Host, storage and networking notes

Known rough edges around the Incus host itself: image import, where data lives, addressing and autostart. Back to the [README](../README.md).

- **HAOS image import** now generates its own `metadata.yaml` and packages
  it into the metadata tarball `incus image import` expects (a bare qcow2
  isn't a valid Incus image on its own - Incus can't tell it's meant to boot
  as a VM without that). This is fully automated in the `incus-host` role
  now; no manual `incus launch` fallback needed.

- **Storage layout: Incus state lives on the NVMe, recordings on the HDD.**
  The root disk is a fast NVMe; `/var` is a 5400rpm HDD. Everything under
  `/var/lib/incus` - including the file-backed ZFS pool (`disks/default.img`,
  holding both VMs' disks and every container root) and Incus's database -
  originally lived on the HDD, so a cold boot had two VMs and ten containers
  all seeking on one slow disk: `incus.service` alone took ~190s, host load
  stayed >10 for 10+ minutes, and services with fixed timeouts (Ollama's GPU
  probe, UniFi's login backend, HA's Glances setup) lost races (see those
  entries). Measured: the HDD read 12GB and was ~36% busy in the first 50
  minutes after boot; the NVMe did ~nothing.
  Now `/srv/incus/lib` is **bind-mounted over `/var/lib/incus`** and
  `/srv/incus/volumes/<name>` over each `/var/incus-volumes/<name>` (the
  list is `nvme_volume_dirs` in `group_vars/all.yml`), via `/etc/fstab`
  entries the `incus-host` role manages. Bind mounts keep every path
  identical, so Terraform's device `source`s and the pool's own `source`
  are unchanged. **Frigate's recordings (`frigate/media`) deliberately stay
  on the HDD** (big sequential writes - what it's good at).
  Things worth knowing:
  - `incus.service` has `RequiresMountsFor=/var/lib/incus`: if the bind
    mount ever fails at boot, Incus refuses to start instead of silently
    initialising a brand-new empty state in the directory underneath.
  - The pool file is sparse with a 300GiB apparent size (bigger than the
    NVMe), so the role sets `zfs set quota=150G default`; ZFS refuses
    writes before the disk can actually fill.
  - **Migration is manual, once** (the role only maintains the mounts):
    stop everything, `rsync -aHAXS --numeric-ids` the directories to
    `/srv/incus/...`, move the originals aside (`*.premigration`), run the
    role. Verified with a dry-run rsync (no diffs) and a `zpool scrub` of the
    copy (0 errors) before switching. The originals
    (`/var/lib/incus.premigration`, `/var/incus-volumes/*.premigration`) and
    a backup of the old pool file (`/var/backups/incus-premigration/`) are
    safe to delete once you're happy - together ~60-100GB. **Rollback** is:
    stop Incus, remove the bind lines from `/etc/fstab` (the pre-migration
    copy is `/etc/fstab.pre-nvme-migration`), `umount` them, move the
    `.premigration` directories back, start Incus.
  - Why not a native ZFS partition instead of a file on ext4: the NVMe is
    fully allocated (root + swap), so it would mean an offline shrink of the
    root filesystem and a rebuilt pool. On NVMe the file-vdev overhead is
    minor next to what leaving the HDD gained; revisit only if wanted.

- **MAC addresses and DHCP reservations**: every instance's `eth0` device
  now pins `hwaddr` explicitly to whatever address it already had, so
  router-side DHCP reservations survive future recreation (Incus otherwise
  hands out a fresh random MAC every time an instance is destroyed and
  recreated - it doesn't change on a plain restart). **HAOS is the one
  exception** - modifying its `eth0` device, even while stopped, even via
  raw `incus config device` outside Terraform entirely, reproducibly fails
  ("Failed to stop device eth0: Failed to detach NIC after 10s") and leaves
  it disconnected from the LAN until force-restarted. Its MAC has been left
  unpinned; if this VM is ever genuinely recreated (not just restarted),
  set `hwaddr` in `haos.tf` at that point instead - device *creation* with a
  fixed MAC works fine, it's only *modifying an existing* device that's
  broken for this particular VM.

- **`boot.autostart` is set on every instance** so they all come back after
  a real power-off/power-on, not just a `systemctl restart`-style event -
  without it, Incus's default behavior here is ambiguous enough not to rely
  on. Expect the first boot after a genuine cold start to take noticeably
  longer than a normal `incus restart` (HAOS in particular - budget several
  minutes, not the usual under-a-minute, before assuming something's wrong).
