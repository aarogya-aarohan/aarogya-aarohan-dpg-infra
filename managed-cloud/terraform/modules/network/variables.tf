variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "vpc_name" {
  type    = string
  default = "aa-vpc"
}

variable "subnets" {
  type = list(object({
    cluster_name  = string
    short_name    = string
    primary_cidr  = string
    pods_cidr     = string
    services_cidr = string
  }))
}
