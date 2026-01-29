# Homelab

A personal Kubernetes-based homelab for experiments, services, and automation.

## Goals

- Learn and test Kubernetes, networking, and infra-as-code.
- Run self-hosted services (monitoring, DNS, CI, media).
- Automate reproducible bootstrapping and deployments.

## High-level layout

- app/ — Kubernetes manifests and Helm charts for services.
- bootstrap/ — cluster bootstrap scripts and manifests.
- scripts/ — utility scripts for admin and automation.
- workloads/ — example workloads and demo apps.
- .github/workflows/ — CI for config validation and automation.

## Quick start

Prereqs: a provisioned machine or VM, kubectl, and an installer (k3s/kind/kubeadm).

1. Review bootstrap steps in [bootstrap/](bootstrap/).
2. Run bootstrap script: `scripts/bootstrap.sh` (adjust for your environment).
3. Deploy base services from [app/](app/).
4. Add workloads from [workloads/](workloads/).

## Inventory & network

Document your physical/virtual hosts, IP ranges, DNS entries, and storage backends here.

## Contributing

- Keep manifests declarative and idempotent.
- Add README snippets inside folders describing intent.
- Open PRs for changes; CI in [.github/workflows/](.github/workflows/) runs validations.

## Notes

- Use branches for experimental changes.
- Back up cluster state before major upgrades.
