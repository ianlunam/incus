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
           -> container:  frigate         (CPU only - object detection; see GPU note below)
           -> container:  ollama          (GPU: 1070 - local LLM for Assist)
           -> container:  whisper         (GPU: 1650 - speech-to-text)
           -> container:  piper           (GPU: 1650 - text-to-speech)
           -> container:  mosquitto       (CPU only - MQTT broker)
           -> container:  matter-server   (CPU only - Matter support for Assist)
           -> container:  esphome         (CPU only - ESPHome dashboard/build+flash server)
           -> VM:        unifi           (UniFi OS Server - needs a full OS, not a container)

GPU split: the plan was to share the 1070 (more VRAM/compute) between
Frigate and Ollama, the two heaviest consumers, with the 1650 handling the
lighter Whisper/Piper voice pipeline. In practice Frigate can't use the 1070
at all right now (see the CUDA/Pascal note under "Known rough edges") - it's
still attached to the `gpu-1070` profile alongside Ollama (harmless, doesn't
reserve anything), but only Ollama actually uses it. Adjust profile
assignments in `ansible/group_vars/all.yml` and each container's `.tf` file
if your GPUs are newer and don't hit that wall.

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
                                   nvidia driver, DKMS/nouveau handling,
                                   Zabbly Incus repo, Incus install/init,
                                   docker/ghcr OCI remotes, GPU profiles,
                                   HAOS image import, volume dirs
terraform/
  provider.tf                  <- Incus provider
  haos.tf                      <- HAOS VM
  frigate.tf, ollama.tf        <- GPU-1070 containers
  whisper-piper.tf             <- GPU-1650 containers
  mosquitto.tf                  <- CPU-only container
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

- **Frigate can't use an NVIDIA GPU on Pascal cards (GTX 10-series) with
  current Frigate releases.** Frigate's `onnx` detector needs CUDA 12.8,
  which needs driver >=570 - but NVIDIA dropped Pascal/Maxwell/Volta support
  starting at driver 560, so a Pascal card is permanently stuck on the 550.x
  branch (the last one that supports it). There's no driver version that
  satisfies both at once; this isn't a config problem, it's a real dead end
  for this GPU generation. Frigate's own native `tensorrt` detector is also a
  dead end on x86_64 - it's been deprecated in favor of Jetson-only ARM
  builds. If you're on Pascal, budget for CPU-only detection (fine for a
  couple of low-res/low-fps cameras) or a newer GPU. Turing and later
  (GTX 16xx/RTX 20xx+) shouldn't hit this at all.
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
- **GPU device syntax** (`incus profile device add ... gpu pci=<addr>`) is
  correct for Incus's GPU device type but pins the whole card to whichever
  container profile uses it - anything sharing a profile gets concurrent
  access to the same card. Right now only Ollama actually uses `gpu-1070`
  (see the Frigate/Pascal note above), so this isn't a live concern, but
  keep an eye on `nvidia-smi` if you add something else to that profile.
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
- This has been run end-to-end against real hardware (2x cheap ESP32-CAM
  boards, a Thread/Zigbee dongle, real Matter devices, a UniFi AP fleet, a
  full HAOS backup restore) - the rough edges above are the real ones that
  came up, not hypothetical ones. New hardware/devices will still surface
  new issues; send me the actual error and I'll fix the specific resource.
