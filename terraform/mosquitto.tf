# Mosquitto MQTT broker - CPU only, used by Frigate, HA, and any Zigbee/
# Z-Wave bridges you add later.
#
# Uses Incus's native OCI image support (Incus >= 6.1): images are pulled
# straight from a container registry via the "docker:" remote, no nested
# Docker-in-LXC needed. If your Incus version predates this, swap `image`
# for a plain Debian image and install mosquitto via cloud-init instead -
# ask and I'll write that variant.
resource "incus_instance" "mosquitto" {
  name  = "mosquitto"
  image = "docker:eclipse-mosquitto:latest"
  type  = "container"

  config = {
    # This image's entrypoint runs as root and chowns /mosquitto/data before
    # dropping to its own unprivileged user - an unprivileged (idmap-shifted)
    # Incus container can't chown a bind-mounted host directory it doesn't
    # already own, so this needs real host root.
    "security.privileged" = "true"
    "boot.autostart"       = "true"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "5GiB"
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
      hwaddr = "10:66:6a:56:17:9b"
    }
  }

  device {
    name = "mqtt-port"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:1883"
      connect = "tcp:127.0.0.1:1883"
    }
  }

  device {
    name = "mosquitto-config"
    type = "disk"
    properties = {
      path   = "/mosquitto/config"
      source = "/var/incus-volumes/mosquitto/config"
    }
  }

  device {
    name = "mosquitto-data"
    type = "disk"
    properties = {
      path   = "/mosquitto/data"
      source = "/var/incus-volumes/mosquitto/data"
    }
  }
}
