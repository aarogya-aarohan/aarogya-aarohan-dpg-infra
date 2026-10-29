output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_endpoint" {
  value     = module.cluster.cluster_endpoint
  sensitive = true
}

output "cluster_ca" {
  value     = module.cluster.cluster_ca_certificate
  sensitive = true
}

output "cluster_location" {
  value = module.cluster.cluster_location
}

output "db_connection_name" {
  value = module.db.connection_name
}

output "db_private_ip" {
  value     = module.db.private_ip
  sensitive = true
}

output "wi_principals" {
  description = "Direct-WI principal identifiers per workload — use as IAM members on Google resources."
  value       = local.wi_principals
}
