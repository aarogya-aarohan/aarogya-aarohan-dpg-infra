output "vpc_self_link" {
  value = local.vpc_self_link
}

output "vpc_name" {
  value = var.shared_vpc_name
}

output "host_project_id" {
  value = var.shared_vpc_host_project_id
}

output "subnet_self_links" {
  value = {
    argocd     = local.subnet_self_link
    staging    = local.subnet_self_link
    production = local.subnet_self_link
  }
}

output "subnet_names" {
  value = {
    argocd     = var.shared_subnet_name
    staging    = var.shared_subnet_name
    production = var.shared_subnet_name
  }
}

output "pods_range_names" {
  value = {
    argocd     = var.pods_secondary_range_name
    staging    = var.pods_secondary_range_name
    production = var.pods_secondary_range_name
  }
}

output "services_range_names" {
  value = {
    argocd     = var.services_secondary_range_name
    staging    = var.services_secondary_range_name
    production = var.services_secondary_range_name
  }
}
