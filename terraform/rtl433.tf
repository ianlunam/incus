# rtl_433 - decodes 433 MHz sensors (weather stations, door/window contacts,
# tyre-pressure, etc.) from an RTL-SDR USB TV dongle and publishes each
# reading to Mosquitto. CPU only.
#
# The dongle is passed to this container, not to HAOS, so the whole path
# stays in the container stack. The host's DVB-T kernel drivers
# (dvb_usb_rtl28xxu etc.) must NOT claim the dongle or rtl_433 can't open
# it - the incus-host role blacklists them.
resource "incus_instance" "rtl433" {
  name  = "rtl433"
  image = "docker:hertzg/rtl_433:latest"
  type  = "container"

  config = {
    "limits.cpu"     = "1"
    "limits.memory"  = "512MiB"
    "boot.autostart" = "true"
    # Default frequency is 433.92 MHz. Topics land under rtl_433/devices/
    # <model>/<id>/<field>.
    #
    # The -X flex decoder handles a generic EV1527-style fixed-code button
    # (24-bit code repeated ~12x, 20-bit id + 4-bit button value). rtl_433's
    # built-in SC226x decoder (protocol 30) expects slower timing (~464/1404
    # us) so it ignores these remotes, whose pulses measured ~364/1084 us.
    # Found with `rtl_433 -A` while pressing the button - re-measure that way
    # for any other remote rather than reusing these numbers.
    "oci.entrypoint" = "rtl_433 -F mqtt://${var.mqtt_broker_host}:1883,retain=0,devices=rtl_433/devices[/model][/id] -X 'n=EV1527,m=OOK_PWM,s=364,l=1084,r=10864,g=1064,t=288,y=0,bits>=24,repeats>=3,unique,get=id:@0:{20}:%05x,get=button:@20:{4}:%x'"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "2GiB"
    }
  }

  # Redeclares the "default" profile's eth0 in full (a bare hwaddr-only
  # override errors with "Unsupported device type" - nictype/parent must be
  # restated too). Bridged only so it reaches Mosquitto on the LAN; nothing
  # listens here.
  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = var.bridge_name
      # Pinned so router-side DHCP reservations survive future recreation -
      # Incus otherwise generates a fresh random MAC every time.
      hwaddr = "10:66:6a:7e:3a:52"
    }
  }

  device {
    name = "rtl-sdr"
    type = "usb"
    properties = {
      vendorid  = var.rtlsdr_usb_vendor_id
      productid = var.rtlsdr_usb_product_id
    }
  }
}
