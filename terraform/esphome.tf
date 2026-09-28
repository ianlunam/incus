# ESPHome dashboard - used to build/flash firmware for ESPHome devices,
# including the m5stack Atom Echo S3R voice satellite units (see the note
# in outputs.tf / README for how those units themselves get configured).
# CPU only. Bridged (not proxied) because first-time USB flashing from the
# dashboard's web UI plus over-the-air updates both expect it to be able to
# reach devices directly on the LAN, and mDNS discovery of already-flashed
# nodes works better with real L2 presence than with a proxied port.
resource "incus_instance" "esphome" {
  name     = "esphome"
  image    = "docker:esphome/esphome:latest"
  type     = "container"
  profiles = ["default"]

  config = {
    # Bumped from 1 CPU / 1GiB - PlatformIO firmware builds (triggered from
    # the dashboard or OTA pushes) are genuinely CPU/RAM-hungry compile jobs,
    # not part of the otherwise-idle dashboard's normal footprint.
    "limits.cpu"    = "6"
    "limits.memory" = "6GiB"
    "boot.autostart" = "true"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "10GiB"
    }
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = var.bridge_name
      # Pinned so router-side DHCP reservations survive future recreation -
      # Incus otherwise generates a fresh random MAC every time.
      hwaddr = "10:66:6a:bc:cf:67"
    }
  }

  device {
    name = "esphome-config"
    type = "disk"
    properties = {
      path   = "/config"
      source = "/var/incus-volumes/esphome/config"
    }
  }

  # Dashboard UI, plus device flashing over USB the first time (before a
  # unit has its own firmware/WiFi creds, OTA can't reach it yet). If you're
  # flashing from a machine other than the Incus host, you don't need this -
  # do the first flash with esphome-flasher/web serial from that machine
  # instead and just use this container for OTA updates + dashboard mgmt.
  device {
    name = "esphome-ui"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:6052"
      connect = "tcp:127.0.0.1:6052"
    }
  }
}
