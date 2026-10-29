output "state_bucket_name" {
  value = google_storage_bucket.tf_state.name
}

output "bastion_internal_ip" {
  value       = google_compute_address.bastion.address
  description = "Static internal IP of the bastion host. Referenced by GKE master authorised-networks."
}

output "bastion_self_link" {
  value       = google_compute_instance.bastion.self_link
  description = "Self-link of the bastion compute instance."
}
