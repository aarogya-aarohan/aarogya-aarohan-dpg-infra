variable "project_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "env" {
  type = string
}

variable "accessor_principal" {
  description = "IAM principal that should receive roles/secretmanager.secretAccessor on per-tenant secrets. Pass the full member string — `principal://...` for direct WI, or `serviceAccount:<email>` for a GSA."
  type        = string
}
