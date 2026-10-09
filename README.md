# HAOS + Frigate + Voice (Whisper/Piper) + Ollama + MQTT on Incus
### Debian 13, i5, 48GB RAM, GTX 1070 + GTX 1650

## Architecture

Everything runs under **Incus** on one Debian 13 host - VMs and containers
managed by the same tool:

    Debian 13 (bare metal host)
      -> nvidia driver installed directly on the host (NOT vfio - containers
         share the host's GPU driver, unlike VM passthrough)
      -> Incus
           -> VM:        haos            (Home Assistant OS, no GPU needed)
           -> container:  frigate         (GPU: 1070 - object detection, onnx/CUDA;
                                            1650 - NVENC recording encode)
           -> container:  ollama          (GPU: 1070 - local LLM for Assist + coding)
           -> container:  whisper         (GPU: 1650 - speech-to-text)
           -> container:  piper           (CPU - text-to-speech; attached to gpu-1650
                                            profile but doesn't itself use CUDA, Piper
                                            has no GPU inference path)
           -> container:  mosquitto       (CPU only - MQTT broker)
           -> container:  rtl433          (CPU only - RTL-SDR USB dongle decoding 433 MHz
                                            sensors, publishes to mosquitto)
           -> container:  searxng         (CPU only - self-hosted web search,
                                            free web/Wikipedia lookups for Ollama)
           -> container:  matter-server   (CPU only - Matter support for Assist)
           -> container:  esphome         (CPU/RAM-heavy on demand - PlatformIO
                                            firmware builds, otherwise idle dashboard)
           -> VM:        unifi           (UniFi OS Server - needs a full OS, not a container)

GPU split: the 1070 (more VRAM/compute) is shared between Frigate and Ollama,
the two heaviest consumers, with the 1650 handling Whisper (Piper stays on
CPU regardless of profile). Getting GPU acceleration actually working inside
containers needed one non-obvious extra step beyond Incus's `gpu` device -
see "nvidia.runtime and the container GPU library gap" under Known rough
edges. Both cards are confirmed working end-to-end on Pascal/Turing
(GTX 1070 + GTX 1650 SUPER) with driver 580 - the CUDA-version wall this repo
used to hit here is now fixed, not a hardware dead end.

Containers use Incus's native OCI support (pulls `docker:` images directly,
no nested Docker-in-container needed) - this requires **Incus >= 6.1**.
Debian 13's own repo only ships 6.0.4, which is too old, so the
`incus-host` role adds Incus's official upstream repo (Zabbly) and installs
from there instead - no manual step needed, just don't be surprised to see
a non-Debian apt source appear.

## Layout

```
ansible/
  inventory/hosts.ini          <- edit: your host's IP/SSH user
  group_vars/all.yml           <- edit: NIC name, GPU PCI IDs, bridge IP plan
  site.yml
  roles/incus-host/            <- bridge (+ bridge-utils, a udev rule to keep
                                   VM/container network devices attached),
                                   nvidia driver (skipped if one's already
                                   active, e.g. installed by hand via
                                   NVIDIA's .run installer - see the
                                   nvidia.runtime note below), DKMS/nouveau
                                   handling, nvidia-container-toolkit +
                                   nvidia.runtime (GPU libs inside
                                   containers), Zabbly Incus repo, Incus
                                   install/init, docker/ghcr OCI remotes,
                                   GPU profiles, HAOS image import, volume dirs,
                                   Glances + incus-metrics-push (host/GPU/
                                   per-container monitoring - see below),
                                   optional ESPHome config backup (see below)
terraform/
  provider.tf                  <- Incus provider
  haos.tf                      <- HAOS VM
  frigate.tf, ollama.tf        <- GPU-1070 containers
  whisper-piper.tf             <- GPU-1650 containers
  mosquitto.tf                  <- CPU-only container
  rtl433.tf                    <- RTL-SDR dongle -> 433 MHz sensor readings -> MQTT
  searxng.tf                   <- self-hosted search (web tool for Ollama, see below)
  esphome.tf                   <- ESPHome dashboard (flash/manage m5stack Atom Echo S3R units)
  unifi.tf                     <- UniFi OS Server (runs as a VM, not a container - see file)
  outputs.tf                   <- endpoint summary + HA wiring instructions
```

## Usage

1. Fresh Debian 13 minimal install, SSH reachable, sudo user.
2. Edit `ansible/inventory/hosts.ini`, `ansible/group_vars/all.yml`:
   - real NIC name (`ip -br link`)
   - real GPU PCI addresses (`lspci -D | grep -i nvidia` - one line per
     card, not per function this time, since container passthrough grabs
     the whole device node rather than binding individual PCI functions)
3. Bootstrap the host:
   ```
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ansible-playbook -i inventory/hosts.ini site.yml
   ```
   Reconfigures networking (bridge) - **do this first run from console/IPMI**,
   not a remote link with no fallback, in case the bridge comes up wrong.
   The role now auto-recovers a VM/container that gets left disconnected by
   a networking restart (a real failure mode we hit repeatedly - covered by
   a udev rule, see below), but a genuinely broken bridge config (wrong IP/
   gateway) still needs console access to fix.
4. Create `terraform/terraform.tfvars` before applying - at minimum:
   ```
   unifi_os_server_deb_url = "<current link from https://ui.com/download/unifi-os-server>"
   ```
   `terraform apply` will fail without this one (no default, deliberately -
   see the UniFi note below). If your Thread/Zigbee USB radio isn't plugged
   in yet, leave `enable_thread_usb_passthrough` at its default `false`; add
   `enable_thread_usb_passthrough = true`, `thread_usb_vendor_id`, and
   `thread_usb_product_id` (from `lsusb` on the host) once it is.
5. Deploy everything:
   ```
   cd terraform
   terraform init
   terraform apply
   ```
6. Read `terraform output service_endpoints` for URLs/ports and the HA
   wiring steps (MQTT integration, Wyoming Protocol entries, Assist voice
   pipeline, Ollama conversation agent).

## Migrating from an existing HAOS add-on-based install

If you're moving from a bare-metal HAOS install that used its add-on store
for things this repo now runs as separate Incus containers, here's the
mapping so you don't end up running the same service twice:

| Old HAOS add-on | What to do here |
|---|---|
| ESPHome | Stop the add-on; use the `esphome` container instead (`terraform/esphome.tf`) - point it at the same `/config` content if you want to keep your existing device configs (copy the add-on's `/config` into `/var/incus-volumes/esphome/config` before first boot). |
| Mosquitto (MQTT broker) | Stop the add-on; use the `mosquitto` container instead. Re-point every integration/device that used the old broker (Zigbee2MQTT, Frigate, etc.) at the new host-ip:1883. |
| Matter Server | Stop the add-on; use the `matter-server` container instead. **Tried migrating its storage volume by hand - doesn't work.** The add-on (HA's own "Matter Server" versioning, e.g. 9.2.0) and this container's image (`ghcr:home-assistant-libs/python-matter-server:stable`, capped at 8.1.0 - no newer tag is published) use incompatible storage formats; the older server just resets to a fresh empty fabric on startup rather than erroring. Budget for re-commissioning every Matter device from scratch. |
| Piper / Whisper | Stop the add-ons; use the `whisper`/`piper` containers instead, re-point Assist's Wyoming Protocol integrations at the new host-ip:port entries. |
| OTBR | **Keep as a HAOS add-on** - it needs the Thread/Zigbee USB radio, which this repo passes through directly to the HAOS VM (see `haos.tf`), so OTBR still runs inside HAOS itself, just on the new VM. |
| motionEye | **Dropped** - Frigate (already in this repo) covers camera detection/recording, so motionEye would just be a redundant consumer of the same camera streams. |
| nginx SSL Proxy + Let's Encrypt | **Keep as HAOS add-ons** - these front your own static sites (not HA), and HAOS's add-on already automates cert renewal, so there's no reason to re-platform them into a container here. They migrate with the HAOS VM as-is. |

## 433 MHz devices (rtl433)

`rtl433` decodes an RTL-SDR dongle and publishes to Mosquitto under
`rtl_433/devices/<model>/<id>/...`. Built-in decoders cover many weather
stations/sensors; a flex decoder in `rtl433.tf` handles a generic EV1527
fixed-code button (id `9782e`). HA entities are created by retained MQTT
discovery messages, not YAML - re-publish this if the broker's retained data is
ever lost:

```
mosquitto_pub -h <mosquitto-ip> -r -t homeassistant/binary_sensor/rtl433_ev1527_620590/config -m '{"name":"Button","unique_id":"rtl433_ev1527_620590_button","state_topic":"rtl_433/devices/EV1527/620590/button","payload_on":"7","off_delay":2,"availability_topic":"rtl_433/rtl433/availability","device":{"identifiers":["rtl433_ev1527_620590"],"name":"433 MHz button 9782e","manufacturer":"Generic","model":"EV1527 fixed-code remote"}}'
```

Entity: `binary_sensor.433_mhz_button_9782e_button` (on for 2s per press; one press
can send two MQTT messages, which `off_delay` absorbs). The "Fairy Lights button" HA automation (created through HA's UI/API, not in
this repo) triggers on that entity going `on` and runs `light.toggle` on
`light.dining_room_dining_room_light_switch_switch_3`; the existing "Fairy
Lights" linked-entities blueprint automation then syncs the two Grillplats plugs.
To add another remote,
find its timing with `rtl_433 -A` (stop the `rtl433` container first so the
dongle is free), then add another `-X` flex spec.

## Power savings

Applied by the `incus-host` role, all tunable in `group_vars/all.yml`:
- TLP (PCIe ASPM, SATA/USB link power management) - `enable_tlp`
- CPU governor pinned to `powersave` by default - `cpu_governor`
- Both GPUs power-capped well under their stock TDP - `nvidia_1070_power_limit_w`,
  `nvidia_1650_power_limit_w` (persisted via a systemd unit, not just a
  one-shot `nvidia-smi` call that reverts on reboot)
- ZFS ARC capped at 4GiB so cache doesn't creep across all 48GB - `zfs_arc_max_bytes`

If Frigate detection latency or LLM inference feels sluggish, the GPU power
caps are the first thing to loosen - raise `nvidia_1070_power_limit_w`
toward stock (~150W) and re-run the playbook.

## Known rough edges - read before running

- **`nvidia.runtime` and the container GPU library gap.** Frigate's `onnx`
  detector (and Ollama, and Whisper) initially failed with "CUDA driver
  version is insufficient for CUDA runtime version" even on a freshly
  updated host driver - misleading, since the host driver was fine. Root
  cause: Incus's plain `gpu` device only passes through the `/dev/nvidia*`
  device nodes, not the host driver's userspace libraries (`libcuda.so`
  etc) - unlike Docker's `--gpus` flag, which injects both. Fix: install
  `nvidia-container-toolkit`/`libnvidia-container` on the host (the
  `incus-host` role does this) and set `nvidia.runtime = true` on the GPU
  profiles (also automated - see `gpu-1070`/`gpu-1650` profile tasks).
  Needs driver >=570 for CUDA 12.8 (Frigate's `onnx` detector requirement);
  the earlier belief that this made Pascal (GTX 10-series) a hard dead end
  was wrong - Pascal supports driver 580 fine, confirmed working via
  NVIDIA's official `.run` installer (Debian 13's own apt repo was just
  behind at the time). Frigate's native `tensorrt` detector is still a dead
  end on x86_64 (deprecated for Jetson-only ARM builds) - use `onnx`.
  **Gotcha:** setting `nvidia.runtime` on a profile doesn't retroactively
  fix an already-running container - it needs a restart (`incus restart
  <name>`) to actually get the injected libraries.
- **Whisper defaults to CPU even with a working GPU passthrough.** The
  `rhasspy/wyoming-whisper` image's `docker_run.sh` only requests
  `--device cuda` if `STT_DEVICE=cuda` is set (same env var its own GPU
  build variant sets internally) - otherwise it silently runs on CPU with
  no error. `whisper-piper.tf` sets `"environment.STT_DEVICE" = "cuda"` to
  opt in; still needs the `nvidia.runtime` fix above and a restart to take
  effect. Piper doesn't have a GPU path at all regardless of profile - it's
  a CPU-native TTS engine by design.
- **HAOS image import** now generates its own `metadata.yaml` and packages
  it into the metadata tarball `incus image import` expects (a bare qcow2
  isn't a valid Incus image on its own - Incus can't tell it's meant to boot
  as a VM without that). This is fully automated in the `incus-host` role
  now; no manual `incus launch` fallback needed.
- **UniFi OS Server**: despite the `.deb`-looking filename, Ubiquiti's
  download is actually a self-contained ELF installer binary, not a real
  Debian package - `apt-get install` on it fails with "Invalid archive
  signature". `unifi.tf`'s cloud-init now downloads it, `chmod +x`s it, and
  runs it directly with `--non-interactive` (it also needs `podman`
  preinstalled, which cloud-init handles too). You still need to set
  `unifi_os_server_deb_url` yourself (see Usage above) since Ubiquiti's
  links are versioned and rotate. This has been run end-to-end and works;
  first boot takes a few minutes since the installer pulls its own
  container image for the Network/Protect/Access "apps" - if it looks stuck,
  give it a few minutes before assuming it's broken.
- **ESPHome + m5stack Atom Echo S3R voice satellites**: `esphome.tf` runs the
  ESPHome dashboard container for building/flashing firmware. The Atom Echo
  units themselves aren't Incus resources - they're standalone ESP32-S3
  boards you flash once (over USB, or over WiFi after the first flash) with
  an ESPHome "voice assistant satellite" config, then they show up in HA as
  ESPHome devices and get wired into an Assist pipeline as satellites. This
  specific board hasn't actually been tried yet - ask and I'll generate a
  starting YAML for it.
- **Frigate camera config** isn't templated here (every camera setup is
  different), but a full working pattern now exists for cheap ESP32-CAM
  boards flashed with ESPHome, added to HA as a native camera entity, and
  pulled into Frigate straight from HA - no RTSP stream needed:
  - ESPHome's `esp32_camera` component needs `psram:` declared to compile at
    anything above a small resolution, and (for a 180°-mounted camera)
    `vertical_flip: true` / `horizontal_mirror: true`.
  - HA's camera entity_id ends up as a slug combining the device name *and*
    the `esp32_camera` block's own `name:` (e.g. two devices both left at
    the default `name: "Camera 1"` collide into confusingly-similar
    entity_ids) - check `/api/states` if it's not what you expect.
  - Frigate needs a long-lived HA access token passed as an
    `Authorization: Bearer` header, not a `?token=` query param (that only
    works for a different, short-lived "signed path" token type) - set this
    via the camera's `ffmpeg.inputs[].input_args`, not go2rtc's `#hint`
    string syntax (fragile in practice; a plain YAML list of args is more
    reliable).
  - Frigate's own `mqtt:` block is mandatory, even if you don't care about
    it - omit it and Frigate silently drops into "safe mode" with your
    camera config ignored, no obvious error pointing at the real cause.
  - **MJPEG cameras re-encode to H.264 for recording, which is CPU-heavy
    by default.** Frigate's `preset-record-mjpeg` uses `libx264`: two ESP32
    cameras cost ~125% of a core in ffmpeg alone, continuously (`mode:
    motion` only filters what's *kept*, not what's encoded). Recording now
    uses NVENC on the **1650 SUPER** (Turing - a better H.264 encoder than
    the 1070's Pascal one, and nearly idle) - Frigate's total dropped to
    ~20% of a core. Pieces needed, each non-obvious:
    - `nvidia.driver.capabilities = "compute,video,utility"` on the Frigate
      instance (`frigate.tf`). Incus's `nvidia.runtime` injects libs per
      *this* key (default `compute,utility`) and ignores the
      `NVIDIA_DRIVER_CAPABILITIES` env var Frigate's image sets - without
      `video`, ffmpeg says `Cannot load libnvidia-encode.so.1`.
    - The 1650 added to Frigate as a second `gpu` device (`gpu1650` in
      `frigate.tf`), since the `gpu-1070` profile only exposes the 1070.
      Detection stays on the 1070. (NVENC on the 1070 works on the host but
      fails inside the container with `unsupported device`; cause not
      chased since the 1650 is the better encoder anyway.)
    - Per camera in Frigate's `config.yml`: `ffmpeg.hwaccel_args: []` and
      `ffmpeg.output_args.record: -f segment -segment_time 10 -segment_format
      mp4 -reset_timestamps 1 -strftime 1 -c:v h264_nvenc -gpu 1 -pix_fmt
      yuv420p -rc vbr -cq 28 -b:v 0 -an`. Frigate *requires* the segment
      args in any custom record args (it refuses to start otherwise - the
      preset used to supply them), and `hwaccel_args: []` is needed because
      once the `video` capability exists Frigate auto-enables CUDA decode,
      which can't handle these cameras' MJPEG pixel format
      (`Error reinitializing filters` crash loop). `-cq 28` is the quality
      knob (lower = better/bigger). Decode stays on the CPU.
- **GPU device syntax** (`incus profile device add ... gpu pci=<addr>`) is
  correct for Incus's GPU device type but pins the whole card to whichever
  container profile uses it - anything sharing a profile gets concurrent
  access to the same card. Frigate and Ollama both share `gpu-1070` now and
  fit comfortably (Frigate's detector ~250MB, Ollama's 7B Q4 model
  ~4.4-5.2GB depending on context length, well under the 1070's 8GB) - keep
  an eye on `nvidia-smi` if you add a third consumer or a bigger model.
  Ollama itself will only keep one model resident on a GPU at a time by
  default (no `OLLAMA_MAX_LOADED_MODELS` override here) - loading a second
  model that doesn't fit alongside the first evicts it entirely rather than
  splitting across GPU/CPU, so don't expect two large models warm at once
  on one card.
  **Ollama can silently end up on CPU after a host reboot.** It probes for
  GPUs once, at startup, with a hard 30s watchdog per backend (CUDA 12,
  CUDA 13, Vulkan) and no env var to extend it. On a cold boot the host is
  swamped starting the HAOS/UniFi VMs (Incus itself took ~190s to finish
  starting; load average >10 for 10+ minutes), discovery times out
  (`llama-server GPU discovery watchdog timed out` in the container's
  console log), Ollama logs `inference compute id=cpu`, and HA's "keep
  loaded forever" setting then pins the CPU-resident model indefinitely
  (seen twice: `qwen2.5:7b` at "100% CPU", 1070 idle, Assist never
  answering - no error anywhere, just high host CPU). **Ordering Incus after
  the NVIDIA units did not fix this** (tried first; the driver was already
  up - it's contention, not readiness). What does: the `incus-host` role
  installs `ollama-gpu-check.timer` (4 min after boot, then every 5 min),
  which restarts the `ollama` container if its startup log says
  `id=cpu` or a loaded model has no VRAM - capped at 3 restarts per boot so
  a genuinely broken GPU can't flap it forever (logs to the journal:
  `journalctl -u ollama-gpu-check`). After a self-heal restart nothing is
  preloaded, so the first Assist query pays a ~35s model load.
  Side fix from the same investigation: Debian ships the `nvidia-persistenced`
  binary but no unit, so the old enable task silently did nothing and
  `nvidia-power-limits.service` (which `Requires=` it) never ran at boot;
  the role now installs the unit, and `incus`/`incus-startup` wait for both.
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
- **Ollama's model and HA wiring aren't managed by this repo** (same
  reasoning as Frigate's camera config below - it's runtime/data-plane
  state, not infrastructure). Currently running `qwen2.5:7b` as a single
  model for both HA's Assist conversation agent and general coding use (e.g.
  a VSCode extension pointed at `http://<host-ip>:11434` directly, bypassing
  HA entirely) rather than juggling two models that don't both fit in 8GB
  VRAM at once. Wired into HA via Settings > Devices & Services > Ollama
  (`http://<host-ip>:11434`), then its "conversation" subentry picks the
  model, context length (`num_ctx` - each doubling costs real VRAM, roughly
  4.4GB/4.8GB/5.2GB at 4096/8192/16384 tokens for this model), and which LLM
  APIs it gets (`assist` for device control, `llm_intents` for search tools -
  see below). Assigned as the conversation engine on the Assist pipeline
  that also uses Whisper/Piper.
  **A model listing `tools` as a capability doesn't mean it reliably
  produces tool calls Ollama can actually parse.** `qwen2.5-coder:7b` was
  tried first (reasoning: Qwen's coder fine-tunes are marketed as retaining
  general ability, so one model could cover both HA tool-calling and VSCode
  coding) - it silently failed every time: instead of wrapping its function
  call in the `<tool_call>` tags its own chat template requires, it printed
  the raw `{"name": ..., "arguments": ...}` JSON as plain assistant text,
  which Ollama can't parse into a real tool call - no error, it just looks
  like an oddly-formatted normal reply. Plain `qwen2.5:7b` and `llama3.1:8b`
  both passed a repeated direct test against Ollama's `/api/chat` (structured
  `tool_calls` field present, 3/3 tries) - `qwen2.5:7b` was kept since it
  uses less VRAM at the same context length. If you change models, verify
  tool-calling with a direct `/api/chat` call and a dummy `tools` array
  before trusting it in HA - the failure mode is silent, not an error.
- **Web search / Wikipedia tools for Ollama**: HA core has no built-in way
  for a conversation agent to search the web - this needs the HACS custom
  integration `skye-harris/llm_intents` ("Tools for Assist") - not part of
  this repo's prerequisites, install it yourself via HACS: search "Tools for
  Assist" > install > restart HA. It registers an
  additional LLM API (`llm_intents`, shown as "Search Services" in the
  conversation agent's API selector) alongside HA's own `assist` API, and
  its search provider is self-hosted **SearXNG** (`terraform/searxng.tf`,
  `docker:searxng/searxng` image) rather than the integration's other option
  (Brave Search API - free tier, but needs a signup/key) since SearXNG needs
  neither an API key nor a per-query cost. SearXNG's default `settings.yml`
  disables its JSON API (`search.formats: [html]` only, to deter scraping on
  public instances) - not templated here since a hand-authored settings.yml
  risks missing keys the image expects; let the image generate its own
  default on first boot (`/var/incus-volumes/searxng/config/settings.yml`),
  then add `json` to `search.formats` by hand and restart the container.
  **Wikipedia's tool was broken, then patched locally - this patch WILL be
  silently erased by a future HACS update, until the upstream fix ships.**
  `llm_intents` called Wikipedia's API through HA's shared `aiohttp` client
  session without setting a custom `User-Agent` - Wikipedia rejects that
  default signature outright per its own [API etiquette
  policy](https://meta.wikimedia.org/wiki/User-Agent_policy) (confirmed:
  the exact same request 403s with HA's default UA string and 200s with
  any descriptive one), so the tool failed every time, and the model was
  observed silently falling back to stale training-data answers instead of
  reporting the failure (asked "who is the current pope" mid-2026, got the
  previous one back with no hint anything had gone wrong).
  Fixed by patching the installed
  `/config/custom_components/llm_intents/wikipedia.py` directly (added a
  `User-Agent` header to its two `session.get()` calls, via SSH to HAOS's
  Terminal & SSH add-on) and re-enabling Wikipedia in the integration
  options - confirmed working with real, current Wikipedia content. Also
  submitted upstream as
  [skye-harris/llm_intents#165](https://github.com/skye-harris/llm_intents/pull/165)
  so this isn't just a local patch waiting to be erased.
  **This is exactly the kind of fix that doesn't survive a HACS update** -
  HACS will pull a fresh copy of `wikipedia.py` from GitHub on the next
  update to this integration, silently reverting the patch (no error, it'll
  just start failing again with the same symptom: model answers as if the
  lookup never happened). Until PR #165 (or an equivalent) is merged and
  released: after any `llm_intents` update, check whether Wikipedia answers
  are actually current, and if not, check the PR's status - if unmerged,
  reapply the same two-line header change by hand.
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
- This has been run end-to-end against real hardware (2x cheap ESP32-CAM
  boards, a Thread/Zigbee dongle, real Matter devices, a UniFi AP fleet, a
  full HAOS backup restore) - the rough edges above are the real ones that
  came up, not hypothetical ones. New hardware/devices will still surface
  new issues; send me the actual error and I'll fix the specific resource.
