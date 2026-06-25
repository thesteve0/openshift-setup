# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an OpenShift cluster provisioning and GitOps configuration framework. It provisions OpenShift clusters on AWS and configures them via OpenShift GitOps (ArgoCD) using an "app-of-apps" pattern.

## Key Commands

All commands should be run from inside the container environment:

```bash
# Enter the container shell (required for all operations)
make shell
# or without GNU Make:
./openshift-setup.sh

# Inside the container:
make install           # Provision a new cluster on AWS
make bootstrap         # Bootstrap GitOps on an existing cluster
make update-applications  # Regenerate ArgoCD applications from templates
make encrypt           # Encrypt secrets (secrets.yaml -> secrets.enc.yaml)
make decrypt           # Decrypt secrets for editing
make destroy           # Destroy the cluster infrastructure
make start             # Start stopped cluster instances
make stop              # Stop running cluster instances
make approve-csrs      # Approve pending certificate signing requests
```

## Architecture

### Directory Structure

- `clusters/<cluster-url>/` - Per-cluster configuration committed to git
  - `cluster.yaml` - Cluster metadata (infraID, AWS details, age public key)
  - `applications/` - Generated ArgoCD Application manifests
  - `values/<app-name>/` - Helm values and encrypted secrets per application
- `install/<cluster-url>/` - Local installation artifacts (gitignored)
  - Contains kubeconfig, SSH keys, age keys, openshift-install binary
- `charts/` - Helm charts for each deployable component
- `applications-templates/` - ArgoCD Application templates with `${VAR}` substitution
- `bootstrap/` - Kustomize resources to install OpenShift GitOps operator
- `hack/` - Shell scripts invoked by Makefile targets

### GitOps Flow

1. `bootstrap/` installs OpenShift GitOps operator and creates ArgoCD instance
2. An "app-of-apps" Application watches `clusters/<cluster-url>/applications/`
3. Each Application in that directory references a chart from `charts/` with values from `clusters/<cluster-url>/values/<app>/`
4. Applications are generated from `applications-templates/*.yaml.tpl` by `hack/update-applications.sh`

### Secrets Management

Secrets use Mozilla SOPS with age encryption:
- Plaintext: `clusters/<cluster>/values/<app>/secrets.yaml` (gitignored)
- Encrypted: `clusters/<cluster>/values/<app>/secrets.enc.yaml` (committed)
- Per-cluster age key stored in `install/<cluster-url>/argo.txt`
- ArgoCD uses `ksops` to decrypt secrets at sync time

## Using Red Hat Demo Platform (RHDP)

To provision a cluster with this framework, order an "AWS Blank Open Environment" from RHDP:
https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/sandboxes-gpte.sandbox-open.prod

This provides:
- AWS credentials (API and CLI access)
- A public Route53 hosted zone (e.g., `sandbox3255.opentlc.com`)
- 7-day lifetime (extensions available)
- Auto-stop after 10h (can be disabled); auto-destroy after 48h

For your `BASE_DOMAIN`, you have two options:
1. Use the domain RHDP provides (e.g., `sandbox3255.opentlc.com`) - no additional setup needed
2. Delegate a subdomain from your own domain using `ROOT_AWS_*` credentials for the account that owns your domain

## Environment Variables

The project uses two levels of dot-env files:

**Root `.env`** - Global settings and secrets shared across clusters:
- `CLUSTER_NAME`, `BASE_DOMAIN` - Define the active cluster URL
- `PULL_SECRET` - Red Hat pull secret for OpenShift installation
- `GH_TOKEN` - GitHub token for automatic deploy key configuration
- `ACME_EMAIL` - Email for LetsEncrypt certificate registration
- `ROOT_AWS_ACCESS_KEY`, `ROOT_AWS_SECRET_ACCESS_KEY` - AWS credentials for the account that owns the parent domain (used for DNS delegation when clusters run in a different AWS account)

**Per-cluster `install/<cluster-url>.env`** - Cluster-specific overrides:
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` - AWS credentials for the cluster's AWS account (compute/billing)
- `AWS_REGION`, `AWS_DEFAULT_REGION` - AWS region for cluster resources
- `ARGO_APPLICATIONS` - Space-delimited list of apps to bootstrap
- `WORKER_COUNT`, `WORKER_TYPE` - Cluster sizing overrides

## Adding a New Application

1. Create a Helm chart in `charts/<app-name>/`
2. Create an application template in `applications-templates/<app-name>.yaml.tpl`
3. Add values in `clusters/<cluster-url>/values/<app-name>/values.yaml`
4. If secrets needed, create `secrets.yaml` and run `make encrypt`
5. Run `make update-applications` to generate the ArgoCD Application manifest
6. Commit and push changes; ArgoCD will sync automatically