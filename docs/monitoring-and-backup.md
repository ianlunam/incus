# Monitoring and backup

Host/GPU/per-instance monitoring in HA, and the optional ESPHome config backup. Back to the [README](../README.md).

- **Host/GPU monitoring in HA**: [Glances](https://nicolargo.github.io/glances/)
  runs directly on the Debian host (not containerized - monitoring "the
  host" from inside a container would only ever show that container's own
  cgroup-limited view, not true host-wide stats), exposing its REST API on
  port 61208 for HA's built-in Glances integration. Gives CPU, memory, disk,
  network, per-core temps, and both GPUs' utilization/memory/temp/fan via
  `nvidia-ml-py` - deliberately installed via pip, not apt's
  `python3-pynvml`, which depends on Debian's own `libnvidia-ml1` (driver
  550.163.01) and drags in `nvidia-alternative`/`nvidia-installer-cleanup`,
  an apt-managed driver stack that actively conflicts with the
  .run-installed 580 driver these GPUs need (hit this directly mid-install -
  see `incus-host`'s tasks for the full story). `nvidia-ml-py` is a pure
  ctypes wrapper with no bundled library, so it just uses whatever
  `libnvidia-ml.so.1` is already on the system. Debian's glances package is
  a `+dfsg` repackage missing the WebUI's bundled static assets, hence
  `--disable-webui` - only the REST API is needed anyway.
  Per-container CPU/memory (Glances only sees the host's aggregate view,
  though it does show per-container *disk* usage for free via ZFS mount
  discovery) comes from a separate mechanism: `incus-metrics-push.timer`
  runs a script every 2 minutes that reads Incus's own `/1.0/metrics` over
  the **local unix socket** (`incus query`, the same access the CLI always
  has) and pushes parsed CPU%/memory values straight to HA's REST API
  (`POST /api/states/<entity>`) as `sensor.incus_<name>_cpu`/`_memory`.
  This exists because the more obvious approach - HA pulling from Incus
  directly - turned out not to be possible at all: Incus's metrics endpoint
  needs `core.https_address` exposed to the network (off by default) *and*
  a client certificate for every request (no anonymous access), and HA's
  core `rest` integration has no way to present a client cert. Pushing from
  the host sidesteps both problems entirely. Needs a HA long-lived access
  token dropped by hand into `/etc/incus-metrics-push/ha_token` (never
  committed here, same secrets discipline as everywhere else). CPU% is
  computed from the change in cumulative cpu-seconds between this run and
  the *previous* run (state kept in `.last_state.json` next to the token) -
  not two samples taken a second apart within one run, which was the first
  thing tried and always measured 0%: Incus's own metrics collector only
  refreshes cpu-seconds internally every ~8-10s, so two queries a second
  apart are byte-identical every time. Comparing across timer runs (minutes
  apart) sidesteps that and doesn't need the script to block at all.
  The counter is cumulative since instance start, so it resets on an
  instance restart - a negative delta (once showed Frigate at -258,071.5%)
  is treated as a restart and the new counter value is used as the delta.
  **A bug in this same script briefly made `unifi`/`haos` (the two VMs)
  read ~200%/~400% CPU** - Incus reports VM CPU time broken out by full
  mode (`user`/`system`/`nice`/`irq`/`softirq`/`steal` *and* `idle`/
  `iowait`), since a VM has its own guest-kernel accounting, unlike a
  container's cgroup (which has no "idle" concept to report at all). The
  parser summed every mode blindly, so a completely idle N-vCPU VM read
  ~N x 100% no matter what it was actually doing. Fixed by excluding
  `idle`/`iowait` from the sum - containers were never affected (they
  never emit those labels).

- **ESPHome device config backup** (`esphome_backup_repo` in
  `group_vars/all.yml`, blank by default = skipped entirely): pushes
  `esphome.tf`'s config volume to a git remote every 30 minutes via a
  systemd timer, using a dedicated SSH deploy key generated on the host
  (`/etc/esphome-backup/deploy_key` - the ansible run prints the public
  half to add once, if it doesn't already have write access to your
  repo). Deliberately not automated end-to-end - the repo itself, and who
  has write access to it, is created and owned by you, not provisioned by
  this role. ESPHome's own dashboard already `git init`s that directory
  for local version history on every save, with a sensible `.gitignore`
  of its own (`secrets.yaml`, build caches, device pairing state) - this
  only adds pushing that existing history somewhere durable. The backup
  script also needs `git config --system` (not `--global`) for the
  repo's `safe.directory` exception and commit identity, since it runs as
  root via systemd with no resolvable `HOME` for a `--global` config to
  live in.
