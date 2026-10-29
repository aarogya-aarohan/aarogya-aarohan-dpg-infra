output "cluster_name" {
  value = module.cluster.name
}

output "cluster_endpoint" {
  value     = module.cluster.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = module.cluster.ca_certificate
  sensitive = true
}

output "cluster_location" {
  value = module.cluster.location
}

output "node_service_account_email" {
  value = data.google_service_account.nodes.email
}
