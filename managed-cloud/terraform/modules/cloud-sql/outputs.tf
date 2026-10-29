output "connection_name" {
  value = module.postgres.instance_connection_name
}

output "private_ip" {
  value     = module.postgres.private_ip_address
  sensitive = true
}

output "instance_name" {
  value = module.postgres.instance_name
}

output "database_name" {
  value = var.database_name
}

output "keycloak_database_name" {
  value = google_sql_database.keycloak.name
}

output "admin_user" {
  value = var.admin_user_name
}

output "admin_password_secret_id" {
  value = google_secret_manager_secret.admin_password.id
}

output "hapi_user_name" {
  value = var.hapi_user_name
}

output "hapi_password" {
  value     = random_password.hapi.result
  sensitive = true
}

output "keycloak_user_name" {
  value = var.keycloak_user_name
}

output "keycloak_password" {
  value     = random_password.keycloak.result
  sensitive = true
}
