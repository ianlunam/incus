# UniFi OS Server (Ubiquiti's replacement for the standalone "UniFi Network
# Application" container/docker image, which is now EOL/legacy). Unlike the
# old controller, UniFi OS Server is NOT distributed as a docker image - it's
# a .deb installer for Ubuntu that takes over the host it's installed on (it
# brings its own container runtime for Network/Protect/Access "apps" and
# expects to manage its own storage/networking). That means it can't be
# dropped in as an Incus container next to the others - it needs a full OS
# underneath it, so it runs as an Incus VM instead, the same way HAOS does.
#
# This resource boots a plain Ubuntu 24.04 cloud image and uses cloud-init to
# install UniFi OS Server on first boot. You MUST fill in
# `unifi_os_server_deb_url` below with the current download link from
# https://ui.com/download/unifi-os-server (Ubiquiti's download links are
# versioned/rotated, so there's no stable URL to hardcode here - grab the
# current one for Ubuntu 24.04 x86_64 from that page).
#
# NOTE: I have not run this against real hardware - UniFi OS Server is new
# enough (2025) that this is a best-effort translation of "how do I run this
# under Incus", not a verified recipe. If cloud-init install fails, SSH in
# and run the installer by hand to see the actual error, then tell me what
# it says and I'll adjust.
variable "unifi_os_server_deb_url" {
  description = "Direct download URL for the UniFi OS Server .deb (Ubuntu 24.04 x86_64), from https://ui.com/download/unifi-os-server - REPLACE, these links rotate."
  type        = string
  default     = ""
}

resource "incus_instance" "unifi" {
  name  = "unifi"
  image = "images:ubuntu/noble/cloud"
  type  = "virtual-machine"

  config = {
    "limits.cpu"    = "2"
    "limits.memory" = "4GiB"
    "boot.autostart" = "true"
    # Despite the ".deb" naming convention on Ubiquiti's download page, this
    # is actually a self-contained ELF installer binary, not a real .deb -
    # `apt-get install` on it fails with "Invalid archive signature". It also
    # needs podman preinstalled (its own container runtime for Network/
    # Protect/Access), which it checks for and refuses to proceed without.
    "cloud-init.user-data" = <<-EOT
      #cloud-config
      package_update: true
      packages:
        - curl
        - podman
      runcmd:
        - curl -fsSL "${var.unifi_os_server_deb_url}" -o /tmp/unifi-os-server-installer
        - chmod +x /tmp/unifi-os-server-installer
        - /tmp/unifi-os-server-installer --non-interactive
    EOT
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "32GiB"
    }
  }

  # Bridged like everything else - UniFi OS Server's Network app still needs
  # L2 presence on the LAN for device adoption/discovery (SSDP/L2 discovery
  # on port 10001).
  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = var.bridge_name
      # Pinned so router-side DHCP reservations survive future recreation -
      # Incus otherwise generates a fresh random MAC every time.
      hwaddr = "10:66:6a:7a:d6:b5"
    }
  }

  # No proxy/port-forward devices needed: this VM is bridged directly onto
  # the LAN (like HAOS), so it's already reachable on all its ports at its
  # own DHCP address - proxy devices are for NAT'd/isolated instances, and
  # Incus rejects them here anyway (VM NAT-mode proxies require "connect" to
  # be one of the instance's own IPs, which isn't known until it's DHCP'd).
  # Find the address via `incus list unifi` or your router's DHCP leases.
}
