variable "container_tag" {
  description = "The tag of the container image to deploy."
  type        = string
}

variable "enable_storage_firewall" {
  description = "Whether to enable the storage account firewall."
  type        = bool
  default     = false
}
