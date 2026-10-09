# Ollama - local LLM runtime for Assist's "conversation agent" (or the
# HA Ollama integration). Shares the 1070 with Frigate; on an 8GB 1070
# stick to smaller models (llama3.2:3b, qwen2.5:3b) rather than 8B+ ones.
resource "incus_instance" "ollama" {
  name     = "ollama"
  image    = "docker:ollama/ollama:latest"
  type     = "container"
  profiles = ["default", "gpu-1070"]

  config = {
    "limits.cpu"     = "4"
    "limits.memory"  = "16GiB"
    "boot.autostart" = "true"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "40GiB" # model weights add up fast
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
      hwaddr  = "10:66:6a:3b:06:3b"
    }
  }

  device {
    name = "ollama-models"
    type = "disk"
    properties = {
      path   = "/root/.ollama"
      source = "/var/incus-volumes/ollama/models"
    }
  }

  device {
    name = "ollama-port"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:11434"
      connect = "tcp:127.0.0.1:11434"
    }
  }
}
