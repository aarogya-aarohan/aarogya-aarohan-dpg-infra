output "token" {
  value     = data.kubernetes_secret_v1.argocd_manager_token.data["token"]
  sensitive = true
}
