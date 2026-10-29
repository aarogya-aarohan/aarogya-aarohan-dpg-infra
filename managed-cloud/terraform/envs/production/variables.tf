variable "project_id" {
  type = string
}

variable "region" {
  type        = string
  description = "GCP region. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "env" {
  type    = string
  default = "production"
}

variable "master_ipv4_cidr" {
  type        = string
  description = "GKE control-plane peering range. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "CIDRs allowed to reach the GKE control plane. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "enable_private_endpoint" {
  type    = bool
  default = true
}

variable "tenants" {
  type    = list(string)
  default = []
}

variable "base_domain" {
  type = string
}

variable "node_service_account" {
  type        = string
  description = "account_id of the shared GKE node SA pre-created by the platform team."
}
