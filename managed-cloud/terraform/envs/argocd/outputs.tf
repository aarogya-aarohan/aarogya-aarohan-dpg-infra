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

output "argocd_namespace" {
  value = module.argocd.argocd_namespace
}

output "argocd_server_service" {
  value = module.argocd.argocd_server_service
}

output "argocd_initial_admin_password_command" {
  value = "kubectl --context=${module.cluster.cluster_name} -n ${module.argocd.argocd_namespace} get secret ${module.argocd.initial_admin_password_secret_name} -o jsonpath='{.data.password}' | base64 -d"
}
