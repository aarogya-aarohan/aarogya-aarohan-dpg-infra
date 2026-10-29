output "argocd_namespace" {
  value = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "argocd_server_service" {
  value = "http://argo-cd-server.${kubernetes_namespace_v1.argocd.metadata[0].name}.svc:80"
}

output "initial_admin_password_secret_name" {
  value = "argocd-initial-admin-secret"
}
