variable "tenant_id" {
  type = string
}

variable "env" {
  type = string
}

variable "location" {
  type    = string
  default = "asia-south1"
}

variable "hapi_principal" {
  description = "IAM principal that should receive roles/storage.objectAdmin on the tenant bucket. Pass the full member string — `principal://...` for direct WI, or `serviceAccount:<email>` for a GSA."
  type        = string
}

variable "hapi_gsa_email" {
  description = "Optional GSA email for an additional roles/storage.objectAdmin grant. Needed when the HAPI KSA is annotated for GSA impersonation (the pod's ADC identity becomes this GSA, not the direct-WI KSA principal). Empty disables the grant."
  type        = string
  default     = ""
}

variable "gateway_principal" {
  description = "IAM principal that should receive roles/storage.objectViewer on the tenant bucket."
  type        = string
}

variable "dashboard_origins" {
  type = list(string)
}
