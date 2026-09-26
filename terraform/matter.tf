# python-matter-server - backend for HA's built-in Matter integration.
# Matter commissioning/operation relies on mDNS + IPv6 multicast, so this
# needs to be a first-class citizen on the LAN segment (bridged, same as
# everything else here) rather than NAT'd - a routed/NAT'd container often
# can't see or be seen by Matter devices during commissioning.
resource "incus_instance" "matter_server" {
  name     = "matter-server"
  image    = "ghcr:home-assistant-libs/python-matter-server:stable"
  type     = "container"
  profiles = ["default"]

  config = {
    "limits.cpu"    = "1"
    "limits.memory" = "1GiB"
    "boot.autostart" = "true"
    # Kernel default (0) discards the Route Information Option in Router
    # Advertisements, so this container never learns OTBR's Thread route no
    # matter how correctly OTBR itself is publishing it - Matter commissioning
    # then fails late with "Network is unreachable" once it tries to reach an
    # actual Thread device. Both the interface-specific AND "all" variants
    # need this set - "all" alone isn't enough, and only setting it live via
    # /proc/sys (rather than here) doesn't survive a container restart.
    "linux.sysctl.net.ipv6.conf.all.accept_ra_rt_info_max_plen"  = "64"
    "linux.sysctl.net.ipv6.conf.eth0.accept_ra_rt_info_max_plen" = "64"
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

  # Redeclares the "default" profile's eth0 in full (a bare hwaddr-only
  # override errors with "Unsupported device type" - nictype/parent must be
  # given explicitly here too, not just inherited) - pinned so router-side
  # DHCP reservations survive future recreation, since Incus otherwise
  # generates a fresh random MAC every time.
  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = var.bridge_name
      hwaddr  = "10:66:6a:71:19:fa"
    }
  }

  device {
    name = "matter-data"
    type = "disk"
    properties = {
      path   = "/data"
      source = "/var/incus-volumes/matter-server/data"
    }
  }

  # WebSocket API HA's Matter integration connects to.
  device {
    name = "matter-ws-port"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:5580"
      connect = "tcp:127.0.0.1:5580"
    }
  }
}
