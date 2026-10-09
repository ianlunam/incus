# Migrating from an existing HAOS add-on-based install

Back to the [README](../README.md).


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
