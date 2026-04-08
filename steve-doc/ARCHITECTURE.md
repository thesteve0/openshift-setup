# Architecture: How This Repo Works

This document explains the concepts behind the repo so you can understand *why* things work the
way they do. For step-by-step instructions, see [RUNBOOK.md](RUNBOOK.md).

---

## Table of Contents

1. [The Big Picture](#the-big-picture)
2. [Phase 1: Provisioning the Cluster](#phase-1-provisioning-the-cluster)
3. [Phase 2: GitOps Configuration via ArgoCD](#phase-2-gitops-configuration-via-argocd)
4. [How Helm Charts and Values Files Work](#how-helm-charts-and-values-files-work)
5. [AWS Networking Concepts You Need](#aws-networking-concepts-you-need)
6. [Route53 and DNS: How Your Cluster Gets a URL](#route53-and-dns-how-your-cluster-gets-a-url)
7. [Secrets Management: SOPS and age Encryption](#secrets-management-sops-and-age-encryption)
8. [Directory Reference](#directory-reference)
9. [The Make Targets](#the-make-targets)
10. [Available Applications (Helm Charts)](#available-applications-helm-charts)

---

## The Big Picture

The repo does two distinct things, in sequence:

```
┌──────────────────────────────────────────────────────────────────────┐
│  YOUR LAPTOP                                                         │
│                                                                      │
│  .env                        install/<cluster>/                      │
│  ├── PULL_SECRET             ├── auth/kubeconfig    ← NEVER          │
│  ├── GH_TOKEN                ├── argo_ed25519           committed    │
│  ├── ACME_EMAIL              ├── argo.txt               to git       │
│  └── ARGO_GIT_URL            ├── id_ed25519                         │
│  (root secrets)              └── openshift-install                   │
│                                                                      │
│  clusters/<cluster>/         ← COMMITTED to your GitHub fork         │
│  ├── cluster.yaml                                                    │
│  ├── applications/                                                   │
│  └── values/                                                         │
└──────────────────┬───────────────────────────────────────────────────┘
                   │
                   │  make shell CLUSTER_NAME=foo BASE_DOMAIN=sandbox1234.opentlc.com
                   ▼
     ┌─────────────────────────────┐
     │  PODMAN CONTAINER           │  Has: aws cli, oc, kubectl, helm,
     │  (tooling environment)      │       openshift-install, sops, age, make
     └──────────────┬──────────────┘
                    │
          ┌─────────┴──────────┐
          │                    │
          ▼                    ▼
   PHASE 1 (first make)   PHASE 2 (second make, after git push)
   Provision cluster       Bootstrap ArgoCD on the cluster
          │                    │
          ▼                    ▼
   ┌─────────────┐      ┌──────────────────────────────────────────┐
   │  AWS        │      │  ARGOCD (running ON the cluster)         │
   │  ├── EC2    │      │                                          │
   │  ├── Route53│      │  watches: github.com/you/openshift-setup │
   │  └── VPC    │      │  └── clusters/<cluster>/applications/    │
   └─────────────┘      │                                          │
                        │  every ~3 min: pulls from Git, applies   │
                        │  any new/changed Helm charts             │
                        └──────────────────────────────────────────┘
```

**Phase 1** runs `openshift-install` to provision a bare OpenShift cluster on AWS. This takes about
45 minutes and only happens once.

**Phase 2** installs ArgoCD on the cluster and points it at your GitHub fork. After that, ArgoCD
owns all further configuration — you make changes by editing files and pushing to Git.

---

## Phase 1: Provisioning the Cluster

`openshift-install` is a Red Hat CLI tool that talks to the AWS API and creates all the cloud
infrastructure a cluster needs: EC2 instances for the control plane and workers, networking (VPC,
subnets, load balancers), DNS records in Route53, and more. It takes a configuration file
(`install-config.yaml`) that describes what you want.

In this repo, that config file is generated from a template (`install-config.yaml.tpl`) using the
environment variables you set in your `.env` and `install/<cluster>.env` files. You never edit
`install-config.yaml` directly.

```
install-config.yaml.tpl        Your env vars
(template in repo root)    +   (CLUSTER_NAME, BASE_DOMAIN,
                                AWS_ACCESS_KEY_ID, WORKER_TYPE, etc.)
              │
              ▼
      install-config.yaml      (generated, lives in install/<cluster>/)
              │
              ▼
      openshift-install        (runs ~45 min, talks to AWS)
              │
              ▼
    Running OpenShift cluster  (+ install/<cluster>/auth/kubeconfig)
```

Once the cluster is up, the framework queries AWS to collect details about the networking it created
(availability zones, subnets, security groups) and writes them into `clusters/<cluster>/cluster.yaml`.
This file is needed later when adding GPU nodes. See
[AWS Networking Concepts](#aws-networking-concepts-you-need) for what those terms mean.

---

## Phase 2: GitOps Configuration via ArgoCD

### What is GitOps?

GitOps means your Git repository is the single source of truth for what should be running on your
cluster. Instead of running `oc apply` commands by hand, you commit changes to Git and a tool
(ArgoCD) watches the repo and applies the changes for you.

```
  You                    Git (GitHub)              ArgoCD (on cluster)
   │                         │                            │
   │── git push ────────────>│                            │
   │                         │<─── poll every ~3 min ────│
   │                         │──── new commit found ─────>│
   │                         │                            │── apply changes
   │                         │                            │   to cluster
   │                         │                            │── report sync status
```

If someone manually changes something on the cluster that differs from what's in Git, ArgoCD
corrects it automatically (self-healing). This means **Git is always the authority** — don't make
permanent changes directly with `oc`.

### The App-of-Apps Pattern

ArgoCD watches one root "Application" object called `app-of-apps`. That object points at
`clusters/<cluster>/applications/` in your Git repo. Inside that folder are individual Application
objects, one per Helm chart you want installed. Each of those Applications points at a chart in
`charts/` and any cluster-specific values in `clusters/<cluster>/values/`.

```
  ArgoCD
    └── app-of-apps  (watches clusters/<cluster>/applications/)
          ├── cert-manager Application   ──> charts/cert-manager/
          │                                  + clusters/<cluster>/values/cert-manager/
          ├── oauth Application          ──> charts/oauth/
          │                                  + clusters/<cluster>/values/oauth/
          ├── openshift-ai Application   ──> charts/openshift-ai/
          │                                  + clusters/<cluster>/values/openshift-ai/
          └── ... (one per enabled component)
```

The Application YAML files in `clusters/<cluster>/applications/` are generated automatically —
you don't write them by hand. You signal intent by creating values files in
`clusters/<cluster>/values/` and running `make update-applications`.

### Sync Waves

Some components depend on others. For example, GPU nodes need to exist before OpenShift AI
tries to schedule on them. ArgoCD uses "sync waves" (a number in the Application YAML) to control
deployment order. Lower numbers deploy first.

```
  Wave 1:  cert-manager, oauth, config       (cluster basics)
  Wave 2:  aws-nvidia-gpu-machinesets        (provision GPU EC2 nodes)
           nvidia-gpu-enablement             (install GPU drivers/operator)
  Wave 4:  openshift-ai                      (RHOAI — needs GPU nodes ready)
```

---

## How Helm Charts and Values Files Work

Helm is a packaging system for Kubernetes. A Helm **chart** is a folder of YAML templates with
placeholder variables. A **values file** supplies the concrete values for those placeholders.

In this repo:

- `charts/<name>/` — the chart (don't edit these unless you're changing the component for everyone)
- `charts/<name>/values.yaml` — the chart's defaults
- `clusters/<cluster>/values/<name>/values.yaml` — your per-cluster overrides (only set what differs)

```
  charts/aws-nvidia-gpu-machinesets/values.yaml   (James's defaults)
  instanceType: g6.2xlarge
  desiredReplicas: 1
  ...

  clusters/mycluster/values/aws-nvidia-gpu-machinesets/values.yaml  (your override)
  instanceType: g6e.4xlarge   ← you only set what you want to change
  desiredReplicas: 2
```

Helm merges these two files (cluster values win), then renders the templates into Kubernetes YAML
and applies them. You never need to write the full Kubernetes YAML yourself.

---

## AWS Networking Concepts You Need

When `openshift-install` creates your cluster, it sets up a full network inside AWS. You don't
configure any of this directly — it's all automatic. But when you add GPU nodes later, the framework
needs to know which network to put them in, which is why `cluster-yaml.sh` queries AWS and saves
these details to `clusters/<cluster>/cluster.yaml`.

### VPC (Virtual Private Cloud)

A VPC is your cluster's private network inside AWS — like a walled-off section of the internet
that only your cluster can see. Everything in the cluster lives inside one VPC.

### Subnets

A VPC is divided into subnets — smaller network segments, each tied to a specific AWS
Availability Zone (a physical datacenter). Your cluster has both:
- **Public subnets** — where load balancers live (accessible from the internet)
- **Private subnets** — where your EC2 instances (cluster nodes) live

When you add GPU nodes, they need to be placed in the private subnets so they're part of the
cluster network. The framework reads those subnet IDs from AWS automatically.

### Security Groups

A security group is a firewall rule set that controls what network traffic an EC2 instance
allows in and out. Your cluster has a "node" security group that permits cluster-internal traffic.
New GPU nodes need to be in this same security group so they can communicate with the rest of the
cluster. The framework reads the security group ID from AWS automatically.

### Availability Zones

AWS regions (like `us-east-2`) are divided into multiple Availability Zones (like `us-east-2a`,
`us-east-2b`, `us-east-2c`). These are separate physical datacenters. The framework spreads
cluster nodes across zones for redundancy. When creating GPU MachineSets, it creates one per zone.

**Bottom line:** You don't need to configure any of this. The framework reads it from AWS and
writes it into `cluster.yaml`. The GPU charts read `cluster.yaml`. It's automatic.

---

## Route53 and DNS: How Your Cluster Gets a URL

### What is Route53?

Route53 is AWS's DNS service. DNS translates human-readable names (like
`api.mycluster.sandbox1234.opentlc.com`) into IP addresses that computers can route to.

### What is a Hosted Zone?

A Hosted Zone in Route53 is the DNS record container for a domain. When you provision an RHDP
sandbox, Red Hat creates a Hosted Zone for your assigned domain (e.g. `sandbox1234.opentlc.com`)
in an AWS account they control. They also give you an IAM user (via `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`) that has permission to add DNS records into that zone.

### How BASE_DOMAIN and CLUSTER_NAME Work Together

`BASE_DOMAIN` comes from RHDP. `CLUSTER_NAME` is something you choose — it becomes a subdomain
under your `BASE_DOMAIN`. You can run multiple clusters under one RHDP sandbox by using different
cluster names.

```
  CLUSTER_NAME = mycluster          ← you pick this
  BASE_DOMAIN  = sandbox1234.opentlc.com   ← from RHDP

  → Cluster URL = mycluster.sandbox1234.opentlc.com

  DNS records created automatically by openshift-install:
  api.mycluster.sandbox1234.opentlc.com        → control plane load balancer
  *.apps.mycluster.sandbox1234.opentlc.com     → application router (wildcard)

  A second cluster on the same sandbox would just be:
  api.othercluster.sandbox1234.opentlc.com
  *.apps.othercluster.sandbox1234.opentlc.com
```

The `*.apps.*` wildcard record means every application you expose on the cluster automatically
gets a working public URL — the OpenShift console, ArgoCD UI, your AI model endpoints, etc.

### Why cert-manager Needs AWS Credentials

LetsEncrypt (the free certificate authority used here) proves you own a domain by asking you to
create a specific DNS record (called a DNS-01 challenge). cert-manager uses your AWS credentials
to create that record in Route53 automatically, gets the certificate, then cleans up the record.
This is why `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are needed even after the cluster
is provisioned.

---

## Secrets Management: SOPS and age Encryption

### The Problem

Some configuration — passwords, API keys, AWS credentials — can't be committed to a public Git
repo in plain text. But for GitOps to work, ArgoCD needs to pull everything it needs from Git.

### The Solution: Encrypt Before Committing

This repo uses two tools:

- **age** — an encryption tool. Like PGP but simpler. Works with public/private key pairs.
- **SOPS** — a tool that encrypts specific fields inside YAML files using age.

```
  Your plaintext secrets.yaml       →  SOPS encrypts it  →  secrets.enc.yaml
  (never committed)                                          (safe to commit)

  Example secrets.yaml:                Example secrets.enc.yaml:
  providers:                           providers:
    htpasswd:                            htpasswd:
      admin: mypassword                    admin: ENC[AES256_GCM,data:x9F2...]
```

### How the Keys Work

When the framework first runs, it generates an age key pair for your cluster:

```
  install/<cluster>/argo.txt    ← contains BOTH public and private key
                                   NEVER committed — stays on your laptop only
```

The **public key** is written into `clusters/<cluster>/cluster.yaml` and used to encrypt secrets.
The **private key** stays in `install/<cluster>/argo.txt` and is what lets you (and ArgoCD)
decrypt them. ArgoCD gets the private key injected as a Kubernetes secret during bootstrap.

### James's Key Is Always a Recipient

`hack/common.sh` hardcodes James's personal age public key:

```bash
COMMON_PUBLIC_KEYS=(
    age1ky5amdnkwzj03gwal0cnk7ue7vsd0n64pxm50nxgycssp7vgpqvq9s7lyw  # jharmison@redhat.com
)
```

This means every secret you encrypt is also encrypted for James — he can always decrypt your
secrets. This is intentional (he supports multiple clusters), but you should be aware of it.
If you want to add your own personal recovery key so you can decrypt secrets independently of
the cluster key, see [Adding Your Own Age Key](../steve-doc/RUNBOOK.md#adding-your-own-age-key)
in the runbook.

### The Workflow

```
  make secrets     ← encrypts all secrets.yaml → secrets.enc.yaml
  make encrypt     ← same as above
  make decrypt     ← decrypts secrets.enc.yaml → secrets.yaml (for editing)

  Rule: commit secrets.enc.yaml, never commit secrets.yaml
```

The `.gitignore` excludes `secrets.yaml` and `secrets.yml` to prevent accidental commits.

---

## Directory Reference

```
openshift-setup/
│
├── .env                         ← Root secrets. NEVER committed (gitignored). Contains:
│                                   PULL_SECRET, GH_TOKEN, ACME_EMAIL,
│                                   ARGO_GIT_URL (must be YOUR fork's SSH URL)
│
├── Makefile                     ← All make targets. Entry point for everything.
├── openshift-setup.sh           ← Shell alternative to `make shell`
├── install-config.yaml.tpl      ← Template for cluster install config
│
├── hack/                        ← Shell scripts that power Makefile targets
│   ├── common.sh                   Shared functions, age public keys, AWS helpers
│   ├── install.sh                  Runs openshift-install
│   ├── cluster-yaml.sh             Generates cluster.yaml, sets up OAuth interactively
│   ├── bootstrap.sh                Applies bootstrap kustomization to cluster
│   ├── update-applications.sh      Re-generates ArgoCD Application YAMLs
│   ├── gen-bootstrap.sh            Templates the bootstrap/ manifests for this cluster
│   ├── start.sh                    Starts all cluster EC2 instances
│   ├── stop.sh                     Stops all cluster EC2 instances
│   ├── encrypt.sh                  Encrypts secrets.yaml → secrets.enc.yaml
│   ├── decrypt.sh                  Decrypts secrets.enc.yaml → secrets.yaml
│   └── destroy.sh                  Destroys the cluster
│
├── bootstrap/                   ← Applied once via `oc apply -k` to seed ArgoCD
│   ├── subscription.yaml           Installs OpenShift GitOps operator
│   ├── template/
│   │   ├── app-of-apps.yaml.tpl    Root ArgoCD Application template
│   │   ├── age-secret.yaml.tpl     Injects the age private key into the cluster
│   │   ├── ssh-keys.yaml.tpl       Injects the ArgoCD SSH key for GitHub
│   │   └── kustomization.yaml.tpl  Kustomize config referencing the above
│
├── applications-templates/      ← ArgoCD Application YAML templates (one per chart)
│   ├── aws-nvidia-gpu-machinesets.yaml.tpl
│   ├── nvidia-gpu-enablement.yaml.tpl
│   ├── openshift-ai.yaml.tpl
│   └── ... (one per available chart)
│
├── charts/                      ← Helm charts — DO NOT EDIT for per-cluster changes
│   ├── aws-nvidia-gpu-machinesets/   Creates GPU MachineSets on AWS
│   ├── nvidia-gpu-enablement/        NFD + NVIDIA GPU Operator
│   ├── openshift-ai/                 Red Hat OpenShift AI (RHOAI)
│   ├── cert-manager/                 LetsEncrypt TLS certificates
│   ├── oauth/                        Cluster authentication (htpasswd or GitHub)
│   ├── config/                       ClusterVersion, pull secret, KubeletConfig
│   ├── monitoring/                   Cluster monitoring configuration
│   └── ...                           (many more optional components)
│
├── clusters/                    ← Per-cluster state. COMMITTED to your fork.
│   └── <cluster>.<domain>/
│       ├── cluster.yaml             Cluster metadata (written by framework)
│       ├── applications/            Generated ArgoCD Application YAMLs (don't edit)
│       └── values/
│           └── <chart-name>/
│               ├── values.yaml      Your Helm value overrides for this cluster
│               └── secrets.enc.yaml SOPS-encrypted secrets (safe to commit)
│
├── install/                     ← Local artifacts. NEVER committed (gitignored). BACK THIS UP.
│   └── <cluster>.<domain>/
│       ├── auth/kubeconfig          Cluster admin credentials
│       ├── auth/kubeconfig-orig     Backup of original kubeconfig
│       ├── argo_ed25519             ArgoCD SSH private key (GitHub auth)
│       ├── argo_ed25519.pub         ArgoCD SSH public key (added as GitHub deploy key)
│       ├── argo.txt                 age private key for SOPS decryption
│       ├── id_ed25519               SSH key injected into cluster nodes
│       ├── openshift-install        Downloaded OCP installer binary
│       └── oc / kubectl             Downloaded OCP client binaries
│
├── demos/                       ← Pre-canned demo scenario definitions
│   ├── gpuaas.yaml                  GPU-as-a-Service (2 GPU types, Kueue, RHOAI)
│   └── maas.yaml
│
└── steve-doc/                   ← Your documentation (this folder)
    ├── README.md                    Notes and James's Slack guidance
    ├── ARCHITECTURE.md              This file
    └── RUNBOOK.md                   Step-by-step operational guide
```

---

## The Make Targets

Run all of these from **inside** `make shell` unless noted.

| Target | What it does |
|---|---|
| `make` | Default: runs `bootstrap` (provision + configure) |
| `make shell` | Enter the tooling container (run this OUTSIDE the container) |
| `make bootstrap` | Download binaries, install cluster, apply bootstrap, configure ArgoCD |
| `make install` | Only provision the cluster (skips bootstrap) |
| `make update-applications` | Regenerate ArgoCD Application YAMLs from templates + values |
| `make encrypt` | Encrypt all `secrets.yaml` → `secrets.enc.yaml` |
| `make decrypt` | Decrypt all `secrets.enc.yaml` → `secrets.yaml` |
| `make start` | Start all cluster EC2 instances (AWS) |
| `make stop` | Stop all cluster EC2 instances (saves cost) |
| `make destroy` | Destroy the cluster and all AWS resources |
| `make cluster-yaml` | Regenerate `cluster.yaml` from AWS (rarely needed manually) |
| `make demo` | Process a demo YAML file and generate its applications |

---

## Available Applications (Helm Charts)

These are the components available to install on your cluster. Enable them by creating a values
file in `clusters/<cluster>/values/<name>/`. See [RUNBOOK.md — Adding Applications](RUNBOOK.md#adding-optional-applications).

### Bootstrapped by Default

These are in `ARGO_APPLICATIONS` in `Makefile` and are always set up:

| Chart | What it installs |
|---|---|
| `config` | ClusterVersion pinning, pull secret update, KubeletConfig |
| `oauth` | Cluster login (htpasswd users or GitHub OAuth) |
| `cert-manager` | LetsEncrypt TLS certs for API and app routes |
| `monitoring` | Cluster monitoring stack configuration |

### GPU Support (add when needed)

| Chart | What it installs |
|---|---|
| `aws-nvidia-gpu-machinesets` | GPU EC2 instances (MachineSets) with auto-scaling |
| `nvidia-gpu-enablement` | Node Feature Discovery + NVIDIA GPU Operator (drivers, device plugin) |

### OpenShift AI

| Chart | What it installs |
|---|---|
| `openshift-ai` | RHOAI operator, DataScienceCluster, dashboard, model serving |

### Optional Additional Components

| Chart | What it installs |
|---|---|
| `keycloak-auth` | Keycloak identity provider (alternative to `oauth`) |
| `odf-operator` | OpenShift Data Foundation (Ceph-based shared storage) |
| `aws-efs-csi-setup` | AWS Elastic File System storage |
| `kueue-operator` + `kueue` | Job queue management for batch/AI workloads |
| `kserve-vllm-model` | KServe + vLLM model serving runtime |
| `cloudnative-pg` | PostgreSQL operator |
| `namespace` | Managed namespace creation with labels |
| `rbac` | Cluster and namespace role bindings |
| `lvm-storage` | LVM-based local storage |
| `local-storage-operator` | Local storage operator |
| `registry-local-storage` | Image registry backed by local storage |
| `registry-objectbucketclaim` | Image registry backed by ODF object storage |
| `rhcl` | Red Hat Connectivity Link (Kuadrant API management) |
