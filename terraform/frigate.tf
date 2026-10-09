# Frigate NVR - object detection. Uses the 1070 via the gpu-1070 profile
# created by Ansible (applied in addition to "default" so it keeps the
# bridged NIC/root disk from default and adds the GPU device on top).
resource "incus_instance" "frigate" {
  name  = "frigate"
  image = "ghcr:blakeblackshear/frigate:stable-tensorrt" # NVIDIA GPU detector support - plain
  # "stable" doesn't bundle the CUDA/
  # TensorRT runtime needed for this at all
  type     = "container"
  profiles = ["default", "gpu-1070"]

  config = {
    "limits.cpu"     = "4"
    "limits.memory"  = "4GiB"
    "boot.autostart" = "true"
    # Incus's nvidia.runtime only injects libs for the capabilities named
    # here (default compute,utility) - it ignores the NVIDIA_DRIVER_CAPABILITIES
    # env var Frigate's image sets. `video` adds libnvidia-encode/libnvcuvid
    # so ffmpeg's h264_nvenc works (re-encoding the cameras' MJPEG for
    # recording on the CPU was the main source of Frigate's load).
    "nvidia.driver.capabilities"        = "compute,video,utility"
    "environment.FRIGATE_RTSP_PASSWORD" = "changeme"
    # Frigate wants /dev/shm sized up for its detection buffers - the LXC
    # default (64MB) isn't enough for more than one camera, and this doesn't
    # have an Incus-native config key, so it needs a raw.lxc mount override.
    "raw.lxc" = "lxc.mount.entry = tmpfs dev/shm tmpfs rw,nosuid,nodev,size=256M 0 0"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "20GiB"
    }
  }

  # Redeclares the "default" profile's eth0 in full (a bare hwaddr-only
  # override errors with "Unsupported device type" - nictype/parent must be
  # given explicitly here too, not just inherited) - pinned so router-side
  # DHCP reservations survive future recreation, since Incus otherwise
  # generates a fresh random MAC every time. This one's changed once already.
  # Second GPU, used only for NVENC recording (ffmpeg `-gpu 1`): the 1650
  # SUPER is Turing (better H.264 encoder than the 1070's Pascal one) and
  # nearly idle, while the 1070 is shared with Ollama. Detection stays on the
  # 1070 via the gpu-1070 profile. pci must match gpu_1650_pci in ansible's
  # group_vars/all.yml.
  device {
    name = "gpu1650"
    type = "gpu"
    properties = {
      pci = "0000:05:00.0"
    }
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = var.bridge_name
      hwaddr  = "10:66:6a:59:e6:5a"
    }
  }

  device {
    name = "frigate-config"
    type = "disk"
    properties = {
      path   = "/config"
      source = "/var/incus-volumes/frigate/config"
    }
  }

  device {
    name = "frigate-media"
    type = "disk"
    properties = {
      path   = "/media/frigate"
      source = "/var/incus-volumes/frigate/media"
    }
  }

  device {
    name = "http-port"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:5000"
      connect = "tcp:127.0.0.1:5000"
    }
  }
}
