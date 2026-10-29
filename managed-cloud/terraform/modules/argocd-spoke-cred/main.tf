terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

resource "kubernetes_service_account_v1" "argocd_manager" {
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding_v1" "argocd_manager" {
  metadata {
    name = "argocd-manager-cluster-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argocd_manager.metadata[0].name
    namespace = kubernetes_service_account_v1.argocd_manager.metadata[0].namespace
  }
}

# K8s 1.24+ does not auto-create token secrets; create one explicitly so ArgoCD
# can authenticate as argocd-manager via a long-lived bearer token.
resource "kubernetes_secret_v1" "argocd_manager_token" {
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.argocd_manager.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"

  depends_on = [kubernetes_cluster_role_binding_v1.argocd_manager]
}

# kube-controller-manager populates data.token asynchronously after creation.
resource "time_sleep" "wait_for_token" {
  depends_on      = [kubernetes_secret_v1.argocd_manager_token]
  create_duration = "20s"
}

data "kubernetes_secret_v1" "argocd_manager_token" {
  metadata {
    name      = kubernetes_secret_v1.argocd_manager_token.metadata[0].name
    namespace = kubernetes_secret_v1.argocd_manager_token.metadata[0].namespace
  }

  depends_on = [time_sleep.wait_for_token]
}
