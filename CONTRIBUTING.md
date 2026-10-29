# Contributing to Aarogya Aarohan infrastructure

Thank you for helping improve Aarogya Aarohan. This repository holds infrastructure code for both deployment models (`managed-cloud/` and `self-hosted/`) and deployment configuration, so every merged change can reach running clusters automatically. Please read this guide before opening a pull request.

## Ways to contribute

- **Report a bug** in the infrastructure code or documentation: open a GitHub issue with what you ran, what you expected and what happened (redact hostnames, IPs, project ids and tokens).
- **Propose an improvement**: open an issue first for anything larger than a small fix, so the approach can be agreed before you write code.
- **Port to another cloud**: see [docs/cloud-portability.md](managed-cloud/docs/cloud-portability.md); new provider modules and overlays are very welcome.
- **Security issues**: do **not** open a public issue. Follow [SECURITY.md](SECURITY.md).

## Development setup

1. Fork the repository and clone your fork.
2. Install the tools listed in the README of the folder you are changing ([managed-cloud](managed-cloud/README.md), [self-hosted](self-hosted/README.md#prerequisites)) and `pre-commit`.
3. Run `pre-commit install`. The hooks block committing decrypted SOPS files and run formatters.
4. For manifest changes, use the local cluster in [docs/local-development.md](managed-cloud/docs/local-development.md).

## Branches and commits

- Branch from `main` using a prefix that describes the change:
  `feat/<short-name>`, `fix/<short-name>`, `docs/<short-name>`, `chore/<short-name>`, `deploy/<app>-<version>` (image tag bumps).
- Write commit messages in the imperative, with a scope: `hapi-fhir: raise liveness probe timeout`, `managed-cloud/terraform/monitoring: add certificate expiry alert`.
- Keep one logical change per pull request. Release (image tag) changes go in their own pull request, staging before production.

## Before you open a pull request

Run the checks that apply to what you changed:

```bash
# Terraform
terraform fmt -recursive -check managed-cloud/terraform/
(cd managed-cloud/terraform/envs/<stack> && terraform init -backend=false && terraform validate)

# Kustomize: every overlay must render
for k in $(find managed-cloud/components self-hosted/components -name kustomization.yaml \( -path '*overlays*' -o -path '*environment*' \)); do
  kustomize build "$(dirname "$k")" > /dev/null || echo "FAILED: $k"
done

# Optional: schema-validate rendered manifests
kustomize build managed-cloud/components/<app>/overlays/<env> | kubeconform -strict -ignore-missing-schemas

# Shell scripts
shellcheck managed-cloud/scripts/*.sh self-hosted/script/k3s/*.sh
```

When you change one environment's overlay, check whether the other environment needs the same change, and say in the pull request description if the difference is intentional.

## Pull request checklist

- [ ] The change is described in plain language: what changes for users or operators, and why
- [ ] `terraform plan` output is attached (redacted) for Terraform changes
- [ ] Every Kustomize overlay renders
- [ ] No secrets, tokens, private keys, internal hostnames or IP addresses are included
- [ ] Documentation under the folder's `docs/` is updated if behaviour changed
- [ ] Image tag changes reference an image that exists in the registry

## Review and merge

- At least one maintainer approval is required.
- Maintainers merge; merging deploys, so a maintainer will choose a suitable time for production changes.
- Squash merge is preferred so each change is a single revertable commit.

## Code of conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
