# Wyoming Whisper (speech-to-text) - shares the 1650 with Piper. Both are
# Wyoming-protocol services HA's Assist pipeline talks to directly (no HTTP
# API needed, just the Wyoming TCP port).
resource "incus_instance" "whisper" {
  name     = "whisper"
  image    = "docker:rhasspy/wyoming-whisper:latest"
  type     = "container"
  profiles = ["default", "gpu-1650"]

  config = {
    "limits.cpu"    = "2"
    "limits.memory" = "2GiB"
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
      hwaddr  = "10:66:6a:e7:69:60"
    }
  }

  device {
    name = "whisper-data"
    type = "disk"
    properties = {
      path   = "/data"
      source = "/var/incus-volumes/whisper/data"
    }
  }

  device {
    name = "whisper-port"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:10300"
      connect = "tcp:127.0.0.1:10300"
    }
  }
}

resource "incus_instance" "piper" {
  name     = "piper"
  image    = "docker:rhasspy/wyoming-piper:latest"
  type     = "container"
  profiles = ["default", "gpu-1650"]

  config = {
    "limits.cpu"    = "2"
    "limits.memory" = "2GiB"
    "boot.autostart" = "true"
    # The image's entrypoint requires --voice with no default (bare
    # `docker_run.sh` exits with "error: --voice is required for the piper
    # backend") - override the OCI entrypoint to supply one.
    "oci.entrypoint" = "bash docker_run.sh --voice ${var.piper_voice}"
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
      hwaddr  = "10:66:6a:44:bf:a2"
    }
  }

  device {
    name = "piper-data"
    type = "disk"
    properties = {
      path   = "/data"
      source = "/var/incus-volumes/piper/data"
    }
  }

  device {
    name = "piper-port"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:10200"
      connect = "tcp:127.0.0.1:10200"
    }
  }
}
