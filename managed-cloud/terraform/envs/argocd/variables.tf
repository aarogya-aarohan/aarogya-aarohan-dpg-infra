variable "project_id" {
  type = string
}

variable "region" {
  type        = string
  description = "GCP region. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "env" {
  type    = string
  default = "argocd"
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

variable "repo_url" {
  type    = string
  default = "git@github.com:YOUR_ORG/aarogya-aarohan-dpg-infra.git"
}

variable "repo_target_revision" {
  type    = string
  default = "main"
}

variable "repo_ssh_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the GitHub repo SSH deploy key. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "argocd_chart_version" {
  type    = string
  default = "7.8.23"
}

variable "node_service_account" {
  type        = string
  description = "account_id of the shared GKE node SA pre-created by the platform team."
}
