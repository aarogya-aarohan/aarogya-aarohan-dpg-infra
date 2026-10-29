variable "project_id" {
  type = string
}

variable "region" {
  type        = string
  description = "GCP region. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md."
}

variable "state_bucket_name" {
  type        = string
  description = "Name of the Terraform state GCS bucket. Not encrypted: every downstream env's `terraform init` reads this value via terraform/backend.hcl before SOPS can run, so encrypting it here would only hide it at apply time while it still leaks via backend.hcl."
  default     = "your-tf-state-bucket"
}

# ---------------------------------------------------------------------------
# Bastion host
# ---------------------------------------------------------------------------

variable "host_project_id" {
  type        = string
  description = "Shared VPC host project that owns the VPC and subnets."
  default     = "your-shared-vpc-host-project"
}

variable "bastion_subnet" {
  type        = string
  description = "Shared VPC subnetwork name (in host project)."
  default     = "your-shared-subnet"
}

variable "bastion_zone" {
  type        = string
  description = "Zone for the bastion VM."
  default     = "asia-south1-c"
}

variable "bastion_machine_type" {
  type        = string
  description = "Machine type for the bastion VM."
  default     = "t2d-standard-1"
}

variable "bastion_disk_size_gb" {
  type        = number
  description = "Boot disk size in GB."
  default     = 100
}

variable "bastion_boot_image" {
  type        = string
  description = "Boot disk image. Use a standard image (e.g. debian-cloud/debian-12) for first-time creation, or a custom image created from a machine-image snapshot for recovery."
  default     = "debian-cloud/debian-12"
}

variable "bastion_ip" {
  type        = string
  description = "Static internal IP for the bastion. GKE master authorised-networks reference this address so it must not change between recreations."
  default     = "10.0.0.10"
}

variable "bastion_service_account" {
  type        = string
  description = "GSA email for the bastion VM. Pre-created by the platform team."
  default     = "aa-bastion@your-gcp-project-id.iam.gserviceaccount.com"
}
