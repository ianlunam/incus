# Throwaway Ubuntu 26.04 LTS (resolute) server to ssh into from the LAN - for
# trying out curl commands and the like that don't work from a work laptop
# (different network path, no corporate proxy/TLS inspection in the way). A VM
# rather than a container so it behaves like a normal full host: its own
# kernel, systemd, apt, sudo, no OCI/app-container quirks. Small on purpose;
# raise the limits here if it ever gets used for more than poking at URLs.
#
# Bridged onto the LAN like HAOS and UniFi, so it has its own DHCP address
# (check `incus list sandbox` or the router's leases) and is reachable on
# port 22 directly - no proxy device. The image ships without sshd, so
# cloud-init installs openssh-server (and `dnsutils` is now bind9-dnsutils -
# one unknown package makes cloud-init skip the whole list). Login is key-only as the user `ian`
# (the image's cloud-init also keeps its default `ubuntu` user, with no
# password and no key, so that one is unreachable).
variable "sandbox_ssh_public_key" {
  description = "Public key authorised for the sandbox VM's `ian` user."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFQBDQZRFavv/XjlAPcpilMmklVqWOLb5AYJBz0Sv+bb ian@ian-ThinkPad-P15v-Gen-3"
}

resource "incus_instance" "sandbox" {
  name  = "sandbox"
  image = "images:ubuntu/26.04/cloud"
  type  = "virtual-machine"

  config = {
    "limits.cpu"           = "1"
    "limits.memory"        = "1GiB"
    "boot.autostart"       = "true"
    "cloud-init.user-data" = <<-EOT
      #cloud-config
      package_update: true
      packages:
        - openssh-server
        - curl
        - bind9-dnsutils
        - jq
        - traceroute
      users:
        - default
        - name: ian
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          lock_passwd: true
          ssh_authorized_keys:
            - ${var.sandbox_ssh_public_key}
    EOT
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
      hwaddr = "10:66:6a:ae:64:ba"
    }
  }
}
