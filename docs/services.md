# Per-service notes

Known rough edges for individual services. Back to the [README](../README.md).

- **UniFi OS Server**: despite the `.deb`-looking filename, Ubiquiti's
  download is actually a self-contained ELF installer binary, not a real
  Debian package - `apt-get install` on it fails with "Invalid archive
  signature". `unifi.tf`'s cloud-init now downloads it, `chmod +x`s it, and
  runs it directly with `--non-interactive` (it also needs `podman`
  preinstalled, which cloud-init handles too). You still need to set
  `unifi_os_server_deb_url` yourself (see [Usage](../README.md#usage)) since Ubiquiti's
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
