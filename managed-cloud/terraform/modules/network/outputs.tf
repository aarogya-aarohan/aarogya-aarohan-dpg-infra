output "vpc_self_link" {
  value = module.vpc.network_self_link
}

output "vpc_name" {
  value = module.vpc.network_name
}

output "subnet_self_links" {
  value = {
    for s in var.subnets : s.cluster_name => module.vpc.subnets["${var.region}/aa-${s.short_name}-subnet"].self_link
  }
}

output "subnet_names" {
  value = {
    for s in var.subnets : s.cluster_name => "aa-${s.short_name}-subnet"
  }
}

output "pods_range_names" {
  value = { for s in var.subnets : s.cluster_name => "pods" }
}

output "services_range_names" {
  value = { for s in var.subnets : s.cluster_name => "services" }
}
