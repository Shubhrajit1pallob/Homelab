# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Repository Overview

This is a Homelab repository for DevOps experimentation and infrastructure management. The repository is currently empty and will grow to contain infrastructure-as-code, configuration files, and automation scripts.

## Architecture Notes

As the repository grows, consider organizing it with these common patterns:
- Infrastructure definitions (Terraform, Ansible, etc.)
- Container orchestration configs (Kubernetes, Docker Compose)
- CI/CD pipeline definitions
- Monitoring and observability configurations
- Documentation and runbooks

## Development Workflow

This section will be populated as the repository structure is established. Common homelab workflows may include:
- Infrastructure provisioning and teardown
- Service deployment and updates
- Backup and disaster recovery procedures
- Security hardening and compliance checks

## Important Considerations

- **Secrets Management**: Never commit sensitive data (passwords, API keys, certificates). Use tools like `sops`, `git-crypt`, or environment variables.
- **State Management**: If using Terraform or similar tools, ensure state files are properly backed up and secured.
- **Testing**: Test infrastructure changes in isolated environments before applying to production services.
- **Documentation**: Keep runbooks and architectural decision records (ADRs) up to date as the homelab evolves.
