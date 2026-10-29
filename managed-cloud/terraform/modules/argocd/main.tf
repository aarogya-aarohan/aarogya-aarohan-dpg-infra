terraform {
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
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "argo_cd" {
  name       = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  timeout    = 900

  values = [yamlencode({
    controller = {
      replicas = 1
    }
    server = {
      replicas = 1
      # Listen on 80 so the platform-team-owned LB firewall rule
      # (which only allows tcp:80,443 from GCP health-check ranges to
      # aa-gke-argocd-nodes) covers both serving traffic and the
      # backend-service health check. The non-root container user needs
      # NET_BIND_SERVICE to bind a privileged port.
      containerPorts = {
        server = 80
      }
      containerSecurityContext = {
        runAsNonRoot             = true
        readOnlyRootFilesystem   = true
        allowPrivilegeEscalation = false
        seccompProfile = {
          type = "RuntimeDefault"
        }
        capabilities = {
          drop = ["ALL"]
          add  = ["NET_BIND_SERVICE"]
        }
      }
      service = {
        type = "ClusterIP"
        annotations = {
          "cloud.google.com/neg" = jsonencode({ exposed_ports = { "80" = { name = "neg-aa-argocd-server-asouth1-c" } } })
        }
      }
    }
    repoServer = {
      replicas = 1
    }
    applicationSet = {
      replicas = 1
    }
    configs = {
      params = {
        "server.insecure" = true
        # Use the apiserver for diff calculation so newer status fields (e.g.
        # Deployment.status.terminatingReplicas on k8s 1.32) don't trip ArgoCD's
        # bundled OpenAPI schema and leave apps stuck in SYNC=Unknown.
        "controller.diff.server.side" = "true"
      }
    }
  })]
}

data "google_secret_manager_secret_version" "repo_ssh" {
  secret  = var.repo_ssh_secret_id
  project = var.project_id
}

resource "kubernetes_secret_v1" "repo_cred" {
  metadata {
    name      = "argocd-repo-cred"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  type = "Opaque"

  data = {
    type          = "git"
    url           = var.repo_url
    sshPrivateKey = data.google_secret_manager_secret_version.repo_ssh.secret_data
  }

  depends_on = [helm_release.argo_cd]
}

resource "kubernetes_secret_v1" "spoke_cluster" {
  for_each = { for c in var.spoke_clusters : c.name => c }

  metadata {
    name      = "cluster-${each.key}"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  type = "Opaque"

  data = {
    name   = each.value.name
    server = "https://${each.value.endpoint}"
    config = jsonencode({
      bearerToken = each.value.sa_token
      tlsClientConfig = {
        caData = each.value.ca
      }
    })
  }

  depends_on = [helm_release.argo_cd]
}

resource "kubectl_manifest" "app_of_projects" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "app-of-projects"
      namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.repo_url
        path           = "managed-cloud/projects"
        targetRevision = var.repo_target_revision
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.argocd.metadata[0].name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [helm_release.argo_cd]
}

resource "kubectl_manifest" "app_of_apps" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "app-of-apps"
      namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.repo_url
        path           = "managed-cloud/apps"
        targetRevision = var.repo_target_revision
        directory = {
          recurse = true
          exclude = "app_of_apps/**"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.argocd.metadata[0].name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [
    helm_release.argo_cd,
    kubectl_manifest.app_of_projects,
  ]
}
