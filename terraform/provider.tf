terraform {
  required_version = ">= 1.5.0"
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 0.3"
    }
  }
}

variable "incus_remote_scheme" {
  description = "How Terraform reaches the Incus daemon. 'unix' if running Terraform ON the host; 'https' if running it remotely against Incus's API (requires incus config trust add)."
  type        = string
  default     = "unix"
}

provider "incus" {
  # Default (unix socket) needs no config when terraform runs on the host
  # itself. For remote use, set:
  #   generate_client_certificates = true
  #   accept_remote_certificate    = true
  #   remote { ... }
  # per the provider docs - left minimal here since this is one box.
}

variable "bridge_name" {
  type    = string
  default = "br0"
}

variable "thread_usb_vendor_id" {
  description = "Vendor ID (hex, no '0x') of the Thread/Zigbee USB radio, from `lsusb` on the host. Matches ansible's thread_usb_vendor_id."
  type        = string
  default     = "10c4"
}

variable "thread_usb_product_id" {
  description = "Product ID (hex, no '0x') of the Thread/Zigbee USB radio, from `lsusb` on the host. Matches ansible's thread_usb_product_id."
  type        = string
  default     = "ea60"
}

variable "enable_thread_usb_passthrough" {
  description = "Pass the Thread/Zigbee USB radio through to HAOS. Leave false until the dongle is plugged in and its vendor/product ID (lsusb) is set above - Incus won't wait for a device that isn't there yet."
  type        = bool
  default     = false
}

variable "piper_voice" {
  description = "Piper TTS voice name (rhasspy/piper-voices) - the wyoming-piper image's entrypoint requires --voice with no default, so this must be set to something valid."
  type        = string
  default     = "en_US-lessac-medium"
}

variable "mqtt_broker_host" {
  description = "Address of the Mosquitto broker as reachable from other containers (its bridged DHCP address - pin it with a router reservation, the MAC is fixed in mosquitto.tf). Used by rtl_433."
  type        = string
  default     = "192.168.0.134"
}

variable "rtlsdr_usb_vendor_id" {
  description = "Vendor ID (hex, no '0x') of the RTL-SDR dongle, from `lsusb` on the host."
  type        = string
  default     = "0bda"
}

variable "rtlsdr_usb_product_id" {
  description = "Product ID (hex, no '0x') of the RTL-SDR dongle, from `lsusb` on the host."
  type        = string
  default     = "2832"
}
