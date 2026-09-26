# HAOS runs as an Incus VM (it's a full appliance OS, not something you
# containerize). Uses the "haos" image alias imported by Ansible.
#
# NOTE: importing a foreign qcow2 as an Incus VM image (ansible's
# `incus image import` step) sometimes needs a hand-built metadata.yaml
# if Incus can't infer VM vs container from the raw qcow2 alone. If
# `terraform apply` fails to launch this instance, run on the host:
#   incus launch local:haos haos --vm -c security.secureboot=false
# once by hand to confirm the image imports cleanly, then re-import
# under Terraform's management, or just leave this instance created
# by hand and remove this resource block - the containers below don't
# depend on it.
resource "incus_instance" "haos" {
  name  = "haos"
  image = "haos"
  type  = "virtual-machine"

  config = {
    "limits.cpu"      = "4"
    "limits.memory"   = "4GiB"
    "boot.autostart"  = "true"
    "security.secureboot" = "false"
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

  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = var.bridge_name
      # NOT pinning hwaddr here like the other instances: modifying this
      # device on this VM - even while stopped, even via raw `incus config
      # device` outside terraform - reproducibly fails ("Failed to stop
      # device eth0: Failed to detach NIC after 10s") and leaves it
      # disconnected from the LAN until force-restarted. Its MAC has been
      # stable all along regardless (regenerated only on instance creation,
      # not restart) - if this VM is ever actually recreated, set hwaddr
      # here at that point instead, which is a different, working code path.
    }
  }

  # Thread/Zigbee radio stick (SkyConnect, ConBee, etc.) - passed straight
  # through to HAOS so its OTBR/Zigbee add-ons see it as a real USB device.
  # Matched by vendor:product ID so it survives replugging into any port.
  # Disabled until enable_thread_usb_passthrough is set (dongle not plugged
  # in yet) - re-enable once it is and its lsusb vendor/product ID is set.
  dynamic "device" {
    for_each = var.enable_thread_usb_passthrough ? [1] : []
    content {
      name = "thread-radio"
      type = "usb"
      properties = {
        vendorid  = var.thread_usb_vendor_id
        productid = var.thread_usb_product_id
      }
    }
  }

  # Microdia TEMPer USB temperature sensor.
  device {
    name = "temper-sensor"
    type = "usb"
    properties = {
      vendorid  = "0c45"
      productid = "7401"
    }
  }
}
