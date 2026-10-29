variable "project_id" {
  type = string
}

variable "namespace" {
  type    = string
  default = "argocd"
}

variable "chart_version" {
  type    = string
  default = "7.6.12"
}

variable "repo_url" {
  type = string
}

variable "repo_target_revision" {
  type    = string
  default = "main"
}

variable "repo_ssh_secret_id" {
  type    = string
  default = "aa-argocd-repo-sshkey"
}

variable "spoke_clusters" {
  type = list(object({
    name     = string
    endpoint = string
    ca       = string
    sa_token = string
  }))
  default = []
}
