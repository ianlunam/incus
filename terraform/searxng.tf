# SearXNG - self-hosted meta-search engine, CPU only. Used as a free web
# search tool for the Ollama conversation agent via the "Tools for Assist"
# HACS integration (llm_intents) - no API key, no per-query cost, unlike
# the Brave Search alternative that integration also supports.
#
# JSON API responses are disabled in SearXNG's default settings.yml (only
# "html" is listed under search.formats) to deter public-instance scraping -
# this is a private, LAN-only instance, so that's added by hand after first
# boot generates the default config (see README). Not templated here since
# a hand-authored settings.yml risks missing keys the image expects; letting
# the image generate its own default and editing it in place is more
# reliable, matching how Frigate/Mosquitto configs are handled in this repo.
resource "incus_instance" "searxng" {
  name  = "searxng"
  image = "docker:searxng/searxng:latest"
  type  = "container"

  config = {
    "limits.cpu"     = "1"
    "limits.memory"  = "1GiB"
    "boot.autostart" = "true"
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
      hwaddr = "10:66:6a:2d:91:c4"
    }
  }

  device {
    name = "searxng-port"
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:8080"
      connect = "tcp:127.0.0.1:8080"
    }
  }

  device {
    name = "searxng-config"
    type = "disk"
    properties = {
      path   = "/etc/searxng"
      source = "/var/incus-volumes/searxng/config"
    }
  }
}
