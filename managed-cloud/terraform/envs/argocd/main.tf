locals {
  short_name = {
    argocd     = "argocd"
    staging    = "stg"
    production = "prod"
  }

  cluster_name = "aa-${local.short_name[var.env]}"
}

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "your-tf-state-bucket"
    prefix = "network"
  }
}

data "terraform_remote_state" "staging" {
  backend = "gcs"
  config = {
    bucket = "your-tf-state-bucket"
    prefix = "staging"
  }
}

data "terraform_remote_state" "production" {
  backend = "gcs"
  config = {
    bucket = "your-tf-state-bucket"
    prefix = "production"
  }
}

module "cluster" {
  source = "../../modules/gke-cluster"

  project_id          = var.project_id
  cluster_name        = local.cluster_name
  region              = var.region
  network_project_id  = data.terraform_remote_state.network.outputs.host_project_id
  network_name        = data.terraform_remote_state.network.outputs.vpc_name
  subnet_name         = data.terraform_remote_state.network.outputs.subnet_names[var.env]
  pods_range_name     = data.terraform_remote_state.network.outputs.pods_range_names[var.env]
  services_range_name = data.terraform_remote_state.network.outputs.services_range_names[var.env]
  master_ipv4_cidr    = var.master_ipv4_cidr

  master_authorized_networks = var.master_authorized_networks
  enable_private_endpoint    = var.enable_private_endpoint
  deletion_protection        = var.env == "production"
  node_max_count             = 1
  node_service_account       = var.node_service_account
  node_zones                 = ["${var.region}-c"]
  node_tags                  = ["aa-gke-argocd-nodes"]
}

module "spoke_staging" {
  source     = "../../modules/argocd-spoke-cred"
  spoke_name = "staging"

  providers = {
    kubernetes = kubernetes.staging
  }
}

module "spoke_production" {
  source     = "../../modules/argocd-spoke-cred"
  spoke_name = "production"

  providers = {
    kubernetes = kubernetes.production
  }
}

module "argocd" {
  source = "../../modules/argocd"

  project_id           = var.project_id
  chart_version        = var.argocd_chart_version
  repo_url             = var.repo_url
  repo_target_revision = var.repo_target_revision
  repo_ssh_secret_id   = var.repo_ssh_secret_id

  spoke_clusters = [
    {
      name     = "staging"
      endpoint = data.terraform_remote_state.staging.outputs.cluster_endpoint
      ca       = data.terraform_remote_state.staging.outputs.cluster_ca
      sa_token = module.spoke_staging.token
    },
    {
      name     = "production"
      endpoint = data.terraform_remote_state.production.outputs.cluster_endpoint
      ca       = data.terraform_remote_state.production.outputs.cluster_ca
      sa_token = module.spoke_production.token
    },
  ]

  depends_on = [module.cluster]
}
