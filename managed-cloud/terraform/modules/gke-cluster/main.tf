locals {
  authorized_networks = var.master_authorized_networks
}

data "google_service_account" "nodes" {
  account_id = var.node_service_account
  project    = var.project_id
}

module "cluster" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/private-cluster"
  version = "~> 30.0"

  project_id = var.project_id
  name       = var.cluster_name
  region     = var.region
  zones      = var.node_zones

  network            = var.network_name
  subnetwork         = var.subnet_name
  network_project_id = var.network_project_id
  ip_range_pods      = var.pods_range_name
  ip_range_services  = var.services_range_name

  enable_private_nodes          = true
  enable_private_endpoint       = var.enable_private_endpoint
  deploy_using_private_endpoint = true
  master_ipv4_cidr_block        = var.master_ipv4_cidr
  master_authorized_networks    = local.authorized_networks

  release_channel     = var.release_channel
  deletion_protection = var.deletion_protection

  identity_namespace         = "${var.project_id}.svc.id.goog"
  network_policy             = false
  datapath_provider          = "ADVANCED_DATAPATH"
  enable_shielded_nodes      = true
  http_load_balancing        = true
  horizontal_pod_autoscaling = true

  # GMP managed collection. Both must be set together — see the gotcha
  # comment on monitoring_enabled_components in variables.tf; setting only
  # monitoring_enable_managed_prometheus renders monitoring_config with an
  # empty enable_components list, which silently disables SYSTEM_COMPONENTS.
  monitoring_enable_managed_prometheus = var.enable_managed_prometheus
  monitoring_enabled_components        = var.monitoring_enabled_components

  create_service_account   = false
  remove_default_node_pool = true
  initial_node_count       = 1

  node_pools = [{
    name            = "default"
    machine_type    = var.node_machine_type
    image_type      = "COS_CONTAINERD"
    disk_size_gb    = 100
    disk_type       = "pd-standard"
    auto_repair     = true
    auto_upgrade    = true
    autoscaling     = true
    min_count       = var.node_min_count
    max_count       = var.node_max_count
    service_account = data.google_service_account.nodes.email
  }]

  node_pools_oauth_scopes = {
    all = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  node_pools_metadata = {
    all = { disable-legacy-endpoints = "true" }
  }

  node_pools_labels = { all = {} }
  node_pools_taints = { all = [] }
  node_pools_tags   = { all = var.node_tags }
}
