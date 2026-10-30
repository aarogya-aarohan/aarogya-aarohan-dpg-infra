# Contributing to Aarogya Aarohan infrastructure

Thank you for helping improve Aarogya Aarohan. This repository holds the deployment configuration for self-hosted sites, and ArgoCD applies every merged change to running sites automatically. Please read this guide before opening a pull request.

## Ways to contribute

- **Report a bug** in the configuration or documentation: open a GitHub issue with what you ran, what you expected and what happened. Redact hostnames, IPs and tokens.
- **Propose an improvement**: open an issue first for anything larger than a small fix, so the approach can be agreed before you write code.
- **Cloud provider notes**: improvements to [docs/cloud-providers.md](docs/cloud-providers.md) for other providers are welcome.
- **Security issues**: do **not** open a public issue. Follow [SECURITY.md](SECURITY.md).

## Development setup

1. Fork the repository and clone your fork.
2. Install the tools listed under [Prerequisites](README.md#prerequisites).
3. Copy each `.env-*.example` in the site overlays to `.env-*.secret` to render locally. `*.secret` is git-ignored; never commit it.

## Branches and commits

- Branch from `main` using a prefix that describes the change: `feat/<short-name>`, `fix/<short-name>`, `docs/<short-name>`, `chore/<short-name>`, `deploy/<app>-<version>` (image tag bumps).
- Write commit messages in the imperative, with a scope: `arogyam/fhir: raise liveness probe timeout`, `apps/uptime: add site probe`.
- Keep one logical change per pull request. Put image tag changes in their own pull request, and roll them out to a pilot site first.

## Before you open a pull request

```bash
# Every site overlay must render
for k in $(find components -name kustomization.yaml -path '*environment*'); do
  kubectl kustomize "$(dirname "$k")" > /dev/null || echo "FAILED: $k"
done

# Shell scripts
shellcheck script/k3s/*.sh
```

## Pull request checklist

- [ ] The change is described in plain language: what changes for sites or operators, and why
- [ ] Every overlay renders
- [ ] No secrets, tokens, private keys, internal hostnames or IP addresses are included
- [ ] Documentation under `docs/` is updated if behaviour changed
- [ ] Image tag changes reference an image that exists in the registry

## Review and merge

- At least one maintainer approval is required.
- Maintainers merge. Merging deploys, so a maintainer chooses a suitable time for production changes.
- Squash merge is preferred so each change is a single revertable commit.

## Code of conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
