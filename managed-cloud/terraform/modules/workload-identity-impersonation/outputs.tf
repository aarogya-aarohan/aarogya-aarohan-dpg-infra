output "gsa_email" {
  value = var.gsa_email
}

output "ksa_annotation" {
  value = "iam.gke.io/gcp-service-account: ${var.gsa_email}"
}
