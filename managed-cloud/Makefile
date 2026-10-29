# SOPS-aware wrapper for terraform plan/apply per env.
# Decrypts terraform/envs/$(ENV)/secrets.enc.json into a tmpfs-backed path,
# passes the path to terraform as -var-file, and removes the plaintext on exit.
# Requires: sops >= 3.7, terraform >= 1.5, gcloud auth application-default login.
#
# _bootstrap is special-cased:
#   - uses local state, so init takes no -backend-config flags
#   - project_id is not stored in secrets.enc.json; supply it via TF_VAR_project_id, e.g.
#       TF_VAR_project_id=your-gcp-project-id make plan ENV=_bootstrap

ENV ?= staging
DIR := terraform/envs/$(ENV)
SECRETS := $(DIR)/secrets.enc.json

ifeq ($(ENV),_bootstrap)
  INIT_ARGS :=
else
  INIT_ARGS := -backend-config=../../backend.hcl -backend-config="prefix=$(ENV)"
endif

.PHONY: init plan apply destroy-cluster check-sops

check-sops:
	@command -v sops >/dev/null 2>&1 || { echo "sops not found; brew install sops"; exit 1; }
	@sops --version --disable-version-check | head -1 | awk '{print $$2}' | awk -F. '{ if ($$1 < 3 || ($$1 == 3 && $$2 < 7)) exit 1 }' \
		|| { echo "sops >= 3.7 required (for exec-file)"; exit 1; }

init:
	cd $(DIR) && terraform init $(INIT_ARGS)

plan: check-sops
	@test -f $(SECRETS) || { echo "missing $(SECRETS) — see docs/deployment-guide.md"; exit 1; }
	sops exec-file --filename secrets.tfvars.json $(SECRETS) 'cd $(DIR) && terraform plan -var-file={} -out=tfplan'

apply: check-sops
	@test -f $(DIR)/tfplan || { echo "no tfplan in $(DIR); run 'make plan ENV=$(ENV)' first"; exit 1; }
	cd $(DIR) && terraform apply tfplan

# Destroy only the GKE cluster module (leaves Cloud SQL, secrets, IAM intact).
# For production, temporarily set deletion_protection=false in main.tf first, apply, then run this.
destroy-cluster: check-sops
	@test -f $(SECRETS) || { echo "missing $(SECRETS) — see docs/deployment-guide.md"; exit 1; }
	sops exec-file --filename secrets.tfvars.json $(SECRETS) 'cd $(DIR) && terraform destroy -target=module.cluster -var-file={} -auto-approve'
