variable "project_id" {
  type = string
}

variable "name" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "tier" {
  type = string
}

variable "vpc_self_link" {
  type = string
}

variable "availability_type" {
  type = string
}

variable "backup_retention_days" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "database_name" {
  type    = string
  default = "arogyam"
}

variable "admin_user_name" {
  type    = string
  default = "arogyam_admin"
}

variable "hapi_user_name" {
  type    = string
  default = "hapi"
}

variable "keycloak_user_name" {
  type    = string
  default = "keycloak"
}

variable "keycloak_database_name" {
  type    = string
  default = "keycloak"
}
