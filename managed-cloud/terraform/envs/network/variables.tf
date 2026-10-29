variable "project_id" {
  type = string
}

variable "region" {
  type        = string
  description = "GCP region. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "shared_vpc_host_project_id" {
  type        = string
  description = "Host project that owns the Shared VPC. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "shared_vpc_name" {
  type        = string
  description = "Shared VPC network name provided by platform team. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "shared_subnet_name" {
  type        = string
  description = "Shared subnet name dedicated for AA. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "pods_secondary_range_name" {
  type        = string
  description = "Secondary range name for pods on the shared subnet. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "services_secondary_range_name" {
  type        = string
  description = "Secondary range name for services on the shared subnet. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}
