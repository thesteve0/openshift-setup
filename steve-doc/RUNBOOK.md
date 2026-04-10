# Runbook: Operating openshift-setup

Step-by-step procedures for provisioning and managing OpenShift AI clusters.
When a step references a concept you're not familiar with, the link will take you to the
relevant section in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [One-Time Setup: Environment Files](#one-time-setup-environment-files)
    - [Optional: Adding Your Own Age Key](#optional-adding-your-own-age-key)
3. [Entering the Tooling Container](#entering-the-tooling-container)
4. [Provisioning a New Cluster](#provisioning-a-new-cluster)
5. [The Two-Commit Dance](#the-two-commit-dance)
6. [Bootstrapping ArgoCD (Second Make Run)](#bootstrapping-argocd-second-make-run)
7. [Adding GPU Nodes](#adding-gpu-nodes)
8. [Adding OpenShift AI (RHOAI)](#adding-openshift-ai-rhoai)
9. [Adding Optional Applications](#adding-optional-applications)
10. [Day-2 Operations](#day-2-operations)
11. [Destroying a Cluster](#destroying-a-cluster)
12. [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before you start, you need the following. Check each one off.

### On your laptop

- [ ] **Podman** installed and working. Test with: `podman run hello-world`
- [ ] **Git** configured with your name and email
- [ ] This repo cloned and you're on your own fork (not James's original)
- [ ] Your terminal is in the root of the repo

### From Red Hat Demo Platform (RHDP)

Provision a sandbox at:
`https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/sandboxes-gpte.sandbox-open.prod`

After provisioning, RHDP gives you:

- [ ] **AWS_ACCESS_KEY_ID** — your AWS access key
- [ ] **AWS_SECRET_ACCESS_KEY** — your AWS secret key
- [ ] **BASE_DOMAIN** — something like `sandbox1234.opentlc.com`

**CLUSTER_NAME is not from RHDP — you pick it yourself.** It becomes a subdomain under your
`BASE_DOMAIN`. For example, if you choose `mycluster` and your BASE_DOMAIN is
`sandbox1234.opentlc.com`, your cluster lives at `mycluster.sandbox1234.opentlc.com`.
You can run multiple clusters under a single RHDP sandbox by using different cluster names.

See [Route53 and DNS](ARCHITECTURE.md#route53-and-dns-how-your-cluster-gets-a-url) for why these exist.

### From Red Hat Console

- [ ] **Pull Secret** — get it from `https://console.redhat.com/openshift/install/pull-secret`
  This is a long JSON string tied to **your Red Hat account** (not any specific cluster).
  `openshift-install` needs it before it can pull Red Hat container images during the installation
  process. You can get this at any time — you don't need a cluster first, just a Red Hat login.

### From GitHub

- [ ] **Personal Access Token (GH_TOKEN)** — create one at `https://github.com/settings/tokens`
  Needs `repo` scope. This lets the framework automatically configure the deploy key so
  ArgoCD can pull from your private fork.
- [ ] **Your fork's SSH URL** — looks like `git@github.com:YOUR_USERNAME/openshift-setup.git`
  Find it on your fork's GitHub page → Code → SSH.

---

## One-Time Setup: Environment Files

You need two files. Neither is committed to Git (they're in `.gitignore`).

### File 1: `.env` (repo root)

This file holds secrets and settings that apply to all clusters.

Create it at the root of the repo:

```sh
# From the repo root, on your laptop (not inside the container):
cat > .env << 'EOF'
export PULL_SECRET='<paste your pull secret JSON here>'
export ACME_EMAIL=your.name@redhat.com
export GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
export ARGO_GIT_URL=git@github.com:YOUR_USERNAME/openshift-setup.git

# Optional but recommended: set these here so you don't have to
# type them every time you run `make shell`
export CLUSTER_NAME=mycluster
export BASE_DOMAIN=sandbox1234.opentlc.com
EOF
```

> **Tip:** If you set `CLUSTER_NAME` and `BASE_DOMAIN` in `.env`, you can run just `make shell`
> instead of `make shell CLUSTER_NAME=mycluster BASE_DOMAIN=sandbox1234.opentlc.com`.
> The Makefile reads `.env` before applying its defaults.

> **CRITICAL — ARGO_GIT_URL must be your fork's SSH URL.**
> If this is set to James's repo URL (the default in the Makefile), ArgoCD will pull James's
> cluster configurations instead of yours. Set this before your first `make` run and don't change
> it afterward. See [Phase 2: GitOps](ARCHITECTURE.md#phase-2-gitops-configuration-via-argocd).

### File 2: `install/<CLUSTER_NAME>.<BASE_DOMAIN>.env` (per-cluster secrets)

This file holds the AWS credentials and cluster-specific settings.

Choose a name for your cluster (e.g. `mycluster`) and create the file:

```sh
# Replace these values with what RHDP gave you
CLUSTER_NAME=mycluster
BASE_DOMAIN=sandbox1234.opentlc.com

mkdir -p install/${CLUSTER_NAME}.${BASE_DOMAIN}

cat > install/${CLUSTER_NAME}.${BASE_DOMAIN}.env << 'EOF'
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=xxxx...
export AWS_REGION=us-east-2
EOF
```

> **Why `us-east-2`?** GPU instances (especially newer types like g6e) are more available in
> `us-east-2` than other regions. Use this unless you have a reason not to.

**All variables you can set in either file:**

| Variable | Where | What it does |
|---|---|---|
| `PULL_SECRET` | `.env` | Red Hat pull secret for cluster image access |
| `ACME_EMAIL` | `.env` | Email for LetsEncrypt cert registration |
| `GH_TOKEN` | `.env` | GitHub token for auto-configuring ArgoCD deploy keys |
| `ARGO_GIT_URL` | `.env` | **Must be your fork's SSH URL** |
| `CLUSTER_NAME` | `.env` | A name you choose — becomes a subdomain under `BASE_DOMAIN`; setting it here avoids typing it on every `make shell` |
| `BASE_DOMAIN` | `.env` | Your RHDP domain (avoids typing it on every `make shell`) |
| `ARGO_GIT_REVISION` | `.env` | Git branch/tag ArgoCD follows (default: `HEAD`) |
| `ARGO_APPLICATIONS` | `.env` | Space-separated list of apps bootstrapped by default |
| `AWS_ACCESS_KEY_ID` | cluster `.env` | AWS credentials from RHDP — stays here, not in `.env`, because different clusters can use different AWS accounts |
| `AWS_SECRET_ACCESS_KEY` | cluster `.env` | AWS credentials from RHDP |
| `AWS_REGION` | cluster `.env` | AWS region (recommend `us-east-2` for GPUs) |
| `CLUSTER_VERSION` | cluster `.env` | OCP version to install (default in Makefile: `4.20.15`) |
| `CONTROL_PLANE_TYPE` | cluster `.env` | EC2 instance type for control plane (default: `m6i.2xlarge`) |
| `CONTROL_PLANE_COUNT` | cluster `.env` | Number of control plane nodes: `1` or `3` (default: `3`) |
| `WORKER_TYPE` | cluster `.env` | EC2 instance type for workers (default: `m6i.2xlarge`) |
| `WORKER_COUNT` | cluster `.env` | Number of initial worker nodes (default: `3`) |

### Optional: Adding Your Own Age Key

By default, your encrypted secrets have two recipients: the cluster's auto-generated age key
(stored in `install/<cluster>/argo.txt`) and James's personal key (hardcoded in `hack/common.sh`).
If you want to be able to decrypt secrets yourself without the cluster key — for example, if you
need to read a secret from a different machine — add your own personal age key.

**The best time to do this is before the first `make` run**, so your key is baked in from the
start. But if you've already provisioned a cluster, you can add it later — `make encrypt` will
automatically re-encrypt all existing secrets for the updated recipient list.

**Step 1: Generate your personal age key** (on your laptop, outside the container):

```sh
age-keygen -o ~/.config/age/mykey.txt
```

This prints your public key:
```
Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**Step 2: Add your public key to `hack/common.sh`:**

```bash
COMMON_PUBLIC_KEYS=(
    age1ky5amdnkwzj03gwal0cnk7ue7vsd0n64pxm50nxgycssp7vgpqvq9s7lyw  # jharmison@redhat.com
    age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx      # your.name@redhat.com
)
```

Commit the change to `hack/common.sh`.

> **Note:** `hack/common.sh` is in James's part of the repo. If you ever pull upstream changes
> from James, check that your key addition wasn't overwritten.

---

## Entering the Tooling Container

All `make` commands (except `make shell` itself) run **inside** the tooling container. The container
has every tool pre-installed: `oc`, `kubectl`, `aws`, `helm`, `sops`, `age`, `openshift-install`.

From your laptop, at the root of the repo:

```sh
# If CLUSTER_NAME and BASE_DOMAIN are in your .env:
make shell

# Otherwise, pass them on the command line:
make shell CLUSTER_NAME=mycluster BASE_DOMAIN=sandbox1234.opentlc.com
```

This drops you into an interactive bash shell inside the container with:
- The repo mounted at `/workdir`
- Your `.env` and cluster env file sourced automatically
- All tools on `PATH`

Your prompt will change. You'll know you're inside when you see something like `root@...`.

> To exit the container at any time: `exit` or Ctrl-D.

> **Note:** If you open a second terminal window, you're back on your laptop. Run `make shell`
> again to get another container session.

---

## Provisioning a New Cluster

**You must be inside the container** (`make shell` first).

```sh
make
```

This runs the `bootstrap` target which chains several steps. Here's what happens in order:

```
make
  │
  ├── Downloads openshift-install and oc/kubectl binaries
  │   into install/<cluster>/
  │
  ├── Generates SSH key pairs:
  │   ├── install/<cluster>/id_ed25519        (injected into EC2 nodes)
  │   └── install/<cluster>/argo_ed25519      (ArgoCD → GitHub auth)
  │
  ├── Generates age encryption key:
  │   └── install/<cluster>/argo.txt
  │
  ├── Runs openshift-install (~45 minutes)
  │   Creates: EC2 instances, VPC, Route53 records
  │   Writes: install/<cluster>/auth/kubeconfig
  │
  ├── Queries AWS for cluster networking details
  │   Writes: clusters/<cluster>/cluster.yaml
  │
  ├── Prompts you interactively (see below)
  │
  └── Generates ArgoCD Application YAMLs
      Writes: clusters/<cluster>/applications/*.yaml
```

### Interactive Prompts During `make`

After the cluster is up, the script will ask you questions. Here's what to expect:

**GitHub OAuth (cluster login):**
```
Do you want to configure a GitHub OAuth application (y/N)?
```

Answer `Y` to use GitHub org-based login. The script will print the values you need and then
prompt you for the Client ID and Client Secret. **Create the OAuth App in GitHub first**, then
come back and paste the values in.

#### Creating the GitHub OAuth App

1. Go to **github.com → your profile → Settings → Developer settings → OAuth Apps → New OAuth App**
   (or visit `https://github.com/organizations/<YOUR_ORG>/settings/applications` for an org-level app)
2. Fill in the fields — the script prints the exact values to use:

   | Field | Value |
   |---|---|
   | Application name | `mycluster.sandbox1234.opentlc.com` (your full cluster URL) |
   | Homepage URL | `https://console-openshift-console.apps.mycluster.sandbox1234.opentlc.com` |
   | Authorization callback URL | `https://oauth-openshift.apps.mycluster.sandbox1234.opentlc.com/oauth2callback/github` |

3. Click **Register application**
4. On the next page, copy the **Client ID**
5. Click **Generate a new client secret** and copy the secret immediately (GitHub only shows it once)
6. Return to the terminal and paste them when prompted

The script will also ask:
```
Enter your GitHub user accounts for administrator access, separated by spaces:
```
Enter your GitHub username(s). These accounts get `cluster-admin` on the OpenShift cluster.

---

Answer `N` if you just want generated passwords (simpler, good for a quick test):
```
Your generated passwords are:
  admin: <random-32-char-password>
  developer: <random-32-char-password>
```
**Save these.** They're written to `clusters/<cluster>/values/oauth/secrets.yaml` (unencrypted,
on disk only — it will be encrypted in the next step).

After answering the prompts, the script will **stop and complain** about uncommitted files.
This is expected. See the next section.

---

## The Two-Commit Dance

After `make` completes the first run, it exits with an error like:

```
The following files need to be committed or pushed for bootstrap:
  clusters/mycluster.sandbox1234.opentlc.com/cluster.yaml
  clusters/mycluster.sandbox1234.opentlc.com/applications/cert-manager.yaml
  clusters/mycluster.sandbox1234.opentlc.com/values/oauth/secrets.enc.yaml
  ...
```

> **Why does this happen?**
> ArgoCD runs *on the cluster* and pulls its configuration from GitHub. When ArgoCD starts up for
> the first time, it immediately tries to read `clusters/<cluster>/applications/` from your GitHub
> repo. If those files aren't pushed yet, ArgoCD has nothing to apply and the bootstrap fails.
> The framework checks this for you before trying to apply the bootstrap.

**Exit the container** (type `exit`) and do this on your laptop:

```sh
git add clusters/
git add install/         # Note: .gitignore protects sensitive files; this is safe
git status               # Review what's being committed
git commit -m "Add cluster mycluster configuration"
git push
```

Then re-enter the container:

```sh
make shell CLUSTER_NAME=mycluster BASE_DOMAIN=sandbox1234.opentlc.com
```

---

## Bootstrapping ArgoCD (Second Make Run)

> **Prerequisite:** You must have completed [The Two-Commit Dance](#the-two-commit-dance) —
> the cluster files must be committed **and pushed** to GitHub before this step. ArgoCD runs
> on the cluster and immediately tries to pull its configuration from your GitHub repo. If the
> files aren't pushed, it has nothing to apply.

**Inside the container**, run `make` again:

```sh
make
```

This time, the cluster already exists, so the install step is skipped. The framework runs
`bootstrap.sh` which:

1. Verifies all cluster files are committed and pushed to GitHub
2. Applies the bootstrap kustomization to the cluster:
   ```
   oc apply -k install/<cluster>/bootstrap
   ```
   This installs the OpenShift GitOps operator and creates:
   - The ArgoCD instance in `openshift-gitops` namespace
   - The age private key as a Kubernetes secret (so ArgoCD can decrypt your SOPS secrets)
   - The SSH key as a Kubernetes secret (so ArgoCD can pull from your GitHub fork)
   - The `app-of-apps` ArgoCD Application (points at your `clusters/<cluster>/applications/`)

3. ArgoCD starts up and immediately begins syncing all the Application objects it finds.
   This takes a few minutes — ArgoCD is installing operators, waiting for them to be ready, etc.

**You're done.** The cluster is running and ArgoCD is managing its configuration.

> ### Accessing Your Cluster
>
> | | URL |
> |---|---|
> | **OpenShift Console** | `https://console-openshift-console.apps.<cluster>.<domain>` |
> | **ArgoCD UI** | `https://openshift-gitops-server-openshift-gitops.apps.<cluster>.<domain>` |
>
> **Credentials:**
> - **GitHub OAuth:** log in with your GitHub account
> - **Generated passwords:** use the `admin` / `developer` passwords printed during provisioning
>   (also in `clusters/<cluster>/values/oauth/secrets.yaml` on disk until you run `make encrypt`)

---

## Adding GPU Nodes

GPU support requires two charts working together:
- **`aws-nvidia-gpu-machinesets`** — provisions the GPU EC2 instances
- **`nvidia-gpu-enablement`** — installs the software to make the cluster recognize and use the GPUs

See [GPU Support charts](ARCHITECTURE.md#gpu-support-add-when-needed) for what each one does.

### Step 1: Choose Your GPU Instance Type

Look at the [AWS EC2 GPU instance types](https://aws.amazon.com/ec2/instance-types/#Accelerated_Computing).
Common choices for AI workloads:

| Instance | GPU | GPU Memory | Use case |
|---|---|---|---|
| `g4dn.2xlarge` | 1x T4 | 16 GB | Cost-effective inference |
| `g6.2xlarge` | 1x L4 | 24 GB | Mid-range inference |
| `g6e.2xlarge` | 1x L40s | 48 GB | High-end inference / fine-tuning |
| `g6e.4xlarge` | 1x L40s | 48 GB | L40s with more CPU/RAM |

> GPU instances are more available in `us-east-2` than other regions. Set `AWS_REGION=us-east-2`
> in your cluster env file.

### Step 2: Create the GPU MachineSet Values File

```sh
# Inside the container. Replace values with your choices.
CLUSTER_URL=mycluster.sandbox1234.opentlc.com

mkdir -p clusters/${CLUSTER_URL}/values/aws-nvidia-gpu-machinesets

cat > clusters/${CLUSTER_URL}/values/aws-nvidia-gpu-machinesets/values.yaml << 'EOF'
instanceType: g6e.2xlarge    # Your chosen instance type
desiredReplicas: 2           # How many GPU nodes to provision initially
EOF
```

The chart's [default values](../charts/aws-nvidia-gpu-machinesets/values.yaml) cover everything
else (taints, node labels, autoscaling config). You only need to set what you want to change.

> **What are taints?** GPU nodes get a `nvidia.com/gpu=NoSchedule` taint applied automatically.
> This prevents non-GPU workloads from landing on expensive GPU nodes. Only pods that explicitly
> tolerate this taint (like RHOAI model servers) will be scheduled there.

### Step 3: Enable the GPU Enablement Chart

The `nvidia-gpu-enablement` chart installs Node Feature Discovery (detects GPU hardware) and the
NVIDIA GPU Operator (installs drivers, device plugin). You signal that you want it by creating
an empty values file:

```sh
mkdir -p clusters/${CLUSTER_URL}/values/nvidia-gpu-enablement
touch clusters/${CLUSTER_URL}/values/nvidia-gpu-enablement/values.yaml
```

An empty file is enough — the chart's
[defaults](../charts/nvidia-gpu-enablement/values.yaml) are pre-configured for OpenShift.

### Step 4: Regenerate the ArgoCD Application YAMLs

```sh
make update-applications
```

This reads your new values directories and generates the ArgoCD Application YAML files in
`clusters/<cluster>/applications/`. You'll see output like:
```
Found aws-nvidia-gpu-machinesets in values from ...
Found nvidia-gpu-enablement in values from ...
```

### Step 5: Commit, Push, and Apply

```sh
# Exit the container
exit

# On your laptop
git add clusters/
git status   # confirm the new values files and application YAMLs are included
git commit -m "Add GPU nodes: g6e.2xlarge x2"
git push

# Re-enter the container
make shell CLUSTER_NAME=mycluster BASE_DOMAIN=sandbox1234.opentlc.com

# Apply (or just wait up to 3 minutes for ArgoCD to pick it up)
make
```

ArgoCD will:
1. Create MachineSets (wave 2) — AWS provisions EC2 GPU instances and they join the cluster
2. Install Node Feature Discovery — detects the GPU hardware on each node
3. Install NVIDIA GPU Operator — installs drivers, the device plugin, and monitoring

This process takes 10-20 minutes. You can watch progress in the ArgoCD UI.

---

## Adding OpenShift AI (RHOAI)

GPU nodes should be running before you add RHOAI if you intend to use model serving — that's
what RHOAI schedules model servers onto. However, the operator, dashboard, and workbenches can
be installed without GPUs.

> **Capacity warning:** The RHOAI operator runs 3 pods × 500m CPU each, plus the dashboard and
> a dozen component operators. Running this alongside ODF and GPU node feature discovery on two
> `m6i.2xlarge` workers (8 vCPU each) **will run out of CPU headroom**. Plan for at least 3
> worker nodes before installing RHOAI. Set `WORKER_COUNT=3` in your cluster env file.

### Step 1: Create the install-operators values file

The `openshift-ai` chart only **configures** RHOAI — it does not install the operator itself.
You need a separate `install-operators` application to create the OLM Subscription that installs
`rhods-operator`. See [needed-new-app-template.md](needed-new-app-template.md) for the full
backstory on why this gap exists.

```sh
CLUSTER_URL=mycluster.sandbox1234.opentlc.com
mkdir -p clusters/${CLUSTER_URL}/values/install-operators

cat > clusters/${CLUSTER_URL}/values/install-operators/values.yaml << 'EOF'
operators:
  rhods-operator:
    channel: fast-3.x        # or stable-3.x for production
    installPlanApproval: Automatic
    namespace: redhat-ods-operator
    operatorGroup:
      enabled: true
EOF
```

To check which channels are available on your cluster before choosing:
```sh
# Inside the container
source hack/common.sh
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
```

- **`fast-3.x`** — new releases land here first; good for dev/test
- **`stable-3.x`** — same releases after additional validation; better for production

### Step 2: Create the OpenShift AI values file

```sh
cat > clusters/${CLUSTER_URL}/values/openshift-ai/values.yaml << 'EOF'
---
channel: fast-3.x    # informational only — actual channel is set in install-operators values
dataScienceCluster:
  version: v2
  components:
    dashboard:
      managementState: Managed
    workbenches:
      workbenchNamespace: rhods-notebooks
      managementState: Managed
    kserve:
      nim:
        managementState: Removed
      rawDeploymentServiceConfig: Headless
      managementState: Managed
    modelregistry:
      registriesNamespace: rhoai-model-registries
      managementState: Managed
    ray:
      managementState: Managed
    trainingoperator:
      managementState: Managed
EOF
```

See [charts/openshift-ai/values.yaml](../charts/openshift-ai/values.yaml) for all available
options and additional components to enable.

### Step 3: Regenerate, Commit, Push, Apply

```sh
make update-applications
exit

git add clusters/
git commit -m "Add OpenShift AI with install-operators"
git push

make shell CLUSTER_NAME=mycluster BASE_DOMAIN=sandbox1234.opentlc.com
make
```

### What to expect

ArgoCD syncs in two waves:

1. **Wave 1 — `install-operators`**: Creates the OLM Subscription. The `rhods-operator`
   installs via OLM — allow **5-10 minutes**.
2. **Wave 4 — `openshift-ai`**: Once the operator is running and CRDs are registered, this
   syncs and creates the DataScienceCluster. All RHOAI components deploy — allow another
   **5-10 minutes**.

Watch operator installation:
```sh
# Inside the container
source hack/common.sh
watch -n 10 'oc get subscription -n redhat-ods-operator; echo; oc get csv -n redhat-ods-operator'
```

### Accessing the RHOAI dashboard

In RHOAI 3.x, the dashboard is exposed via a **Gateway** (not a direct OpenShift Route):

`https://data-science-gateway.apps.<cluster>.<domain>/`

It also appears as **"Red Hat OpenShift AI"** in the application grid (⊞ icon, top-right of
the OpenShift console).

> **Note on ArgoCD OutOfSync:** The `rhods-operator` and `rhods-dashboard` Deployments will
> permanently show `OutOfSync` in ArgoCD. The chart tries to pin both to 1 replica, but OLM
> and the RHOAI operator reset them to 3 and 2 respectively. This is a cosmetic conflict —
> the cluster is fully functional.

---

## Adding Optional Applications

The pattern is the same for any chart:

1. Create `clusters/<cluster>/values/<chart-name>/values.yaml` with your overrides
2. If the chart needs secrets, create `clusters/<cluster>/values/<chart-name>/secrets.yaml` then run `make encrypt`
3. Run `make update-applications`
4. Commit, push, apply

See [Available Applications](ARCHITECTURE.md#available-applications-helm-charts) for the full list.
Each chart's default values live in `charts/<chart-name>/values.yaml` — read those to understand
what can be configured.

---

## Day-2 Operations

### Stop the Cluster (Save AWS Costs)

This stops all EC2 instances in the cluster. **The cluster is inaccessible while stopped.**
AWS still charges for EBS volumes and Elastic IPs, but not for EC2 compute.

```sh
# Inside the container
make stop
```

### Start the Cluster

```sh
# Inside the container
make start
```

After starting, wait a few minutes for all nodes to become Ready before trying to use the cluster.

### Update a Running Cluster (GitOps)

For most changes, you don't need to run any `make` commands. Just:

1. Edit files in `clusters/<cluster>/values/` or add new ones
2. Commit and push
3. Wait up to 3 minutes — ArgoCD picks up the change and applies it

Use `make update-applications` only when you're adding or removing a whole application (creating
or deleting a values directory), because that changes what's in `clusters/<cluster>/applications/`.

### Encrypt Secrets

If you've created or edited a `secrets.yaml` file:

```sh
# Inside the container
make encrypt
```

This converts all `secrets.yaml` → `secrets.enc.yaml`. Commit the `.enc.yaml` files. The plain
`secrets.yaml` files are gitignored — they stay local only.

See [Secrets Management](ARCHITECTURE.md#secrets-management-sops-and-age-encryption) for how this works.

### Decrypt Secrets (to Edit Them)

```sh
# Inside the container
make decrypt
```

This converts `secrets.enc.yaml` → `secrets.yaml` so you can read and edit them. After editing,
run `make encrypt` again before committing.

### Scale Worker Nodes

To add or remove worker nodes on a running cluster, scale the MachineSet directly. The
`cluster.workerNodes` field in `clusters/<cluster>/cluster.yaml` is **not enforced** — no
chart reads it, so changing it there has no effect on the actual cluster.

```sh
# Inside the container
source hack/common.sh

# See current MachineSets and their replica counts
oc get machineset -n openshift-machine-api

# Scale a specific MachineSet up to 1 (add a node in that AZ)
oc scale machineset <machineset-name> -n openshift-machine-api --replicas=1
```

Each MachineSet corresponds to one availability zone (e.g. `us-east-2a`, `us-east-2b`,
`us-east-2c`). Spreading replicas across AZs gives you better availability. New nodes
take 3-5 minutes to join and become Ready.

### Approve Pending CSRs

After a cluster restart or when adding new nodes, some nodes may be stuck waiting for certificate
approval. If `oc get nodes` shows nodes not reaching `Ready` after 5+ minutes:

```sh
# Inside the container
make approve-csrs
```

---

## Destroying a Cluster

This permanently deletes the cluster and all AWS resources. **This is not reversible.**

```sh
# Inside the container
make destroy
```

This runs `openshift-install destroy cluster` which removes all EC2 instances, load balancers,
Route53 records, VPCs, and other resources that were created during provisioning.

To also remove the local `install/<cluster>/` directory:

```sh
make clean
```

> After destroying, you can also remove the `clusters/<cluster>/` directory from Git and push,
> which removes it from ArgoCD's view (ArgoCD is gone anyway, but it keeps your repo clean).

---

## Troubleshooting

### "The following files need to be committed or pushed for bootstrap"

You hit [the two-commit dance](#the-two-commit-dance). Exit the container, `git add clusters/`,
commit, push, then re-enter and run `make` again.

### ArgoCD is syncing but nothing is changing

Check that `ARGO_GIT_URL` in your `.env` points to **your fork**, not James's repo. ArgoCD was
configured with this URL at bootstrap time. If it's wrong, ArgoCD is watching the wrong repo.

To check what URL ArgoCD was configured with:
```sh
oc get secret argocd-repo-creds-github -n openshift-gitops -o yaml
```
The `url` field (base64-encoded) should be your fork's SSH URL.

### "Unable to authenticate to github.com with your ArgoCD key"

The deploy key wasn't configured. This usually means `GH_TOKEN` wasn't set (or was wrong) when
you ran `make` the first time. Fix it manually:

```sh
# Inside the container — get the public key
cat install/<cluster>/argo_ed25519.pub
```

Go to your GitHub fork → Settings → Deploy keys → Add deploy key. Paste the public key.
Name it something like `mycluster.sandbox1234.opentlc.com`. Read-only access is sufficient.

Then re-run `make` to retry the bootstrap.

### Cluster is up but nodes aren't Ready after a restart

Run `make approve-csrs` inside the container. OpenShift requires that new node certificates
be manually approved as a security measure. This is common after `make start`.

### `make shell` fails: "Error: image ... not found"

The tooling container image needs to be pulled. Check your internet/VPN connection and try:
```sh
podman pull quay.io/jharmison/openshift-setup:latest
```

### The install failed midway through (`openshift-install` timeout)

Set `RECOVER_INSTALL=true` in your cluster env file and re-run `make`. This tells the framework
to resume the existing install rather than starting over:
```sh
echo "export RECOVER_INSTALL=true" >> install/<cluster>.env
make shell CLUSTER_NAME=... BASE_DOMAIN=...
# inside container:
make
```

### I can't decrypt my secrets anymore

The private key for decryption lives in `install/<cluster>/argo.txt`. If you've lost this file,
you cannot decrypt the secrets encrypted for your cluster's age key. However, James's personal
key is also always a recipient — he can decrypt and re-encrypt for a new key if needed.
This is why backing up `install/<cluster>/` is important.
