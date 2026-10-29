terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "this" {}

provider "kubernetes" {
  host                   = "https://${module.cluster.cluster_endpoint}"
  cluster_ca_certificate = base64decode(module.cluster.cluster_ca_certificate)
  token                  = data.google_client_config.this.access_token
}

provider "kubernetes" {
  alias                  = "staging"
  host                   = "https://${data.terraform_remote_state.staging.outputs.cluster_endpoint}"
  cluster_ca_certificate = base64decode(data.terraform_remote_state.staging.outputs.cluster_ca)
  token                  = data.google_client_config.this.access_token
}

provider "kubernetes" {
  alias                  = "production"
  host                   = "https://${data.terraform_remote_state.production.outputs.cluster_endpoint}"
  cluster_ca_certificate = base64decode(data.terraform_remote_state.production.outputs.cluster_ca)
  token                  = data.google_client_config.this.access_token
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.cluster.cluster_endpoint}"
    cluster_ca_certificate = base64decode(module.cluster.cluster_ca_certificate)
    token                  = data.google_client_config.this.access_token
  }
}

provider "kubectl" {
  host                   = "https://${module.cluster.cluster_endpoint}"
  cluster_ca_certificate = base64decode(module.cluster.cluster_ca_certificate)
  token                  = data.google_client_config.this.access_token
  load_config_file       = false
}
