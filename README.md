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
see "nvidia.runtime and the container GPU library gap" in
[docs/gpu-and-llm.md](docs/gpu-and-llm.md). Both cards are confirmed working end-to-end on Pascal/Turing
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
  roles/incus-host/
    tasks/main.yml             <- ordered list of imports, one file per concern
                                  (each tagged: --tags rtl-sdr re-runs just that)
      networking.yml           bridge + udev rule keeping VM/container NICs attached
      nvidia-driver.yml        apt components, headers, host driver (skipped if
                               one is already active, e.g. NVIDIA's .run installer)
      incus.yml                NVMe-backed state, Zabbly repo, Incus install/init,
                               docker/ghcr OCI remotes, ZFS quota
      gpu-containers.yml       nvidia-container-toolkit + nvidia.runtime, per-GPU profiles
      haos-image.yml           HAOS qcow2 imported as a local image
      volumes.yml              bind-mounted container volumes, default mosquitto.conf
      rtl-sdr.yml              blacklist DVB-T drivers for the RTL-SDR dongle
      power.yml                TLP, CPU governor, GPU power caps, ZFS ARC cap
      incus-boot.yml           start Incus only after the GPUs/mounts are ready
      ollama-selfheal.yml      restart Ollama if it boots onto the CPU
      monitoring.yml           Glances + incus-metrics-push (host/GPU/per-instance -> HA)
      esphome-backup.yml       optional ESPHome config backup to git
    handlers/, templates/
terraform/
  provider.tf                  <- Incus provider
  haos.tf                      <- HAOS VM
  frigate.tf, ollama.tf        <- GPU-1070 containers
  whisper-piper.tf             <- GPU-1650 containers
  mosquitto.tf                  <- CPU-only container
  rtl433.tf                    <- RTL-SDR dongle -> 433 MHz sensor readings -> MQTT
  searxng.tf                   <- self-hosted search (web tool for Ollama, see docs/gpu-and-llm.md)
  esphome.tf                   <- ESPHome dashboard (flash/manage m5stack Atom Echo S3R units)
  unifi.tf                     <- UniFi OS Server (runs as a VM, not a container - see file)
  outputs.tf                   <- endpoint summary + HA wiring instructions
docs/                          <- detail split out of this README (see "More detail")
tests/, check.sh               <- pytest suite + ./check.sh (linters/validation); CI runs it
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
   a udev rule - see tasks/networking.yml), but a genuinely broken bridge config (wrong IP/
   gateway) still needs console access to fix.
4. Create `terraform/terraform.tfvars` before applying - at minimum:
   ```
   unifi_os_server_deb_url = "<current link from https://ui.com/download/unifi-os-server>"
   ```
   `terraform apply` will fail without this one (no default, deliberately -
   see the UniFi note in docs/services.md). If your Thread/Zigbee USB radio isn't plugged
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

## More detail

| Doc | Covers |
|---|---|
| [docs/migrating-from-haos-addons.md](docs/migrating-from-haos-addons.md) | Which HAOS add-ons moved to containers here, and which stayed |
| [docs/rtl433.md](docs/rtl433.md) | RTL-SDR dongle, 433 MHz devices, the HA button/automation |
| [docs/power-savings.md](docs/power-savings.md) | TLP, CPU governor, GPU power caps, ZFS ARC cap |
| [docs/gpu-and-llm.md](docs/gpu-and-llm.md) | NVIDIA in containers, Whisper/Piper/Ollama, web search for the LLM |
| [docs/host-and-storage.md](docs/host-and-storage.md) | HAOS image import, NVMe vs HDD layout, MACs/DHCP, autostart |
| [docs/services.md](docs/services.md) | UniFi OS Server, ESPHome + voice satellites, Frigate cameras |
| [docs/monitoring-and-backup.md](docs/monitoring-and-backup.md) | Glances/metrics in HA, ESPHome config backup |
| [docs/testing.md](docs/testing.md) | `./check.sh`: linters, validation, pytest suite, what is and isn't covered |

**Read the "Known rough edges" notes in the docs above before running** - they
cover the real failures hit on this hardware.


- This has been run end-to-end against real hardware (2x cheap ESP32-CAM
  boards, a Thread/Zigbee dongle, real Matter devices, a UniFi AP fleet, a
  full HAOS backup restore) - the rough edges in docs/ are the real ones that
  came up, not hypothetical ones. New hardware/devices will still surface
  new issues; send me the actual error and I'll fix the specific resource.
