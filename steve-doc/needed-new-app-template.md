# Missing Application Template: install-operators

## The problem

When trying to add OpenShift AI (RHOAI) to a freshly provisioned cluster, the `openshift-ai`
ArgoCD application fails to sync with errors like:

```
namespaces "redhat-ods-applications" not found
resource mapping not found for name: "default-dsc" namespace: "redhat-ods-operator":
  no matches for kind "DataScienceCluster" in version "datasciencecluster.opendatahub.io/v2"
  ensure CRDs are installed first
```

This happens because the `openshift-ai` chart contains **only configuration resources** — it
assumes the RHOAI operator is already running. Every template references CRDs
(`DataScienceCluster`, `OdhDashboardConfig`, etc.) and namespaces (`redhat-ods-applications`,
`redhat-ods-operator`) that are created by the operator itself. Without the operator, the
CRDs don't exist and every sync fails.

## Why this gap exists — the git history tells the story

We traced the evolution of the `openshift-ai` chart through three commits:

### Commit 1: `2f2b975` — "Added OpenShift AI" (August 2024)

The chart was self-contained. It included `templates/subscription.yaml` and
`templates/operatorgroup.yaml` directly, using `{{ .Values.channel }}` to configure
which OLM channel to install from. The operator installation was baked into the chart.

### Commit 2: `d4f6c3d` — "add: support for the chart for deploying RHOAI" (March 5, 2026)

James removed the inline subscription and operatorgroup templates and replaced them with
a Helm **subchart dependency** on `install-operators`:

```yaml
# charts/openshift-ai/Chart.yaml
dependencies:
  - name: install-operators
    version: 0.1.0
    repository: file://../install-operators
    alias: installOpenShiftAiOperator
    condition: installOpenShiftAiOperator.enabled
```

The `values.yaml` was updated to configure the subchart:

```yaml
installOpenShiftAiOperator:
  enabled: true
  operators:
    rhods-operator:
      channel: stable
      namespace: redhat-ods-operator
      operatorGroup:
        enabled: true
```

This is the same pattern used by the `rhcl` chart (which uses `install-operators` as a
subchart and successfully installs the `rhcl-operator`). We verified this pattern works
with ArgoCD.

### Commit 3: `a751243` — "fix: remove operator install from openshift-ai configuration entirely, just split the charts" (March 6, 2026)

One day later, James removed the subchart dependency entirely. The commit message says
"just split the charts" — meaning the intent was to make operator installation a separate
ArgoCD `Application` rather than a subchart embedded in `openshift-ai`.

This left the `openshift-ai` chart as pure config with no installation mechanism. The
`channel` key in `values/openshift-ai/values.yaml` (seen in both James's cluster and ours)
is now **dead config** — no template in the chart uses it.

### The incomplete follow-through

After splitting the charts, the expected next step was to create
`applications-templates/install-operators.yaml.tpl` so the framework would generate a
standalone ArgoCD `Application` for operator installation. **This was never done.**

James's reference cluster (`cluster.internal.rhai-tmm.dev`) also has no `install-operators`
application and no `values/install-operators/` directory — the gap exists in his cluster too.

The `install-operators` chart's own `values.yaml` has `rhods-operator` commented out as an
example, which is a strong hint that this was always the intended path:

```yaml
# charts/install-operators/values.yaml
operators: {}
# rhods-operator:
#   channel: fast-3.x
#   installPlanApproval: Manual
#   ...
```

We confirmed on the live cluster that no `rhods-operator` subscription exists, no operator
pods are running, and the `openshift-ai` ArgoCD application is `OutOfSync/Missing` as a
result.

## The fix

We completed the "split the charts" intent by adding the missing pieces.

### 1. Add the application template

Created `applications-templates/install-operators.yaml.tpl` at sync wave 1 (before
`openshift-ai` at wave 4):

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: install-operators
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  destination:
    name: in-cluster
    namespace: redhat-ods-operator
  project: default
  source:
    path: charts/install-operators
    repoURL: ${ARGO_GIT_URL}
    targetRevision: ${ARGO_GIT_REVISION}
    helm:
      valueFiles: []
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff:
        duration: 10s
        factor: 3
        maxDuration: 30m
```

### 2. Create the cluster values file

Created `clusters/<cluster>/values/install-operators/values.yaml`:

```yaml
operators:
  rhods-operator:
    channel: fast-3.x      # check available channels first (see below)
    installPlanApproval: Automatic
    namespace: redhat-ods-operator
    operatorGroup:
      enabled: true
```

To see available channels on your cluster before choosing:

```bash
# Inside make shell
source hack/common.sh
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' \
  --insecure-skip-tls-verify=true
```

Notable available channels as of April 2026: `fast-3.x`, `stable-3.x`, `stable-2.x`
variants, and EUS channels. `fast-3.x` gets new releases sooner; `stable-3.x` is better
for production.

### 3. Generate the application, commit, and push

```bash
# Inside the container
make update-applications

# Outside the container
git add applications-templates/install-operators.yaml.tpl \
        clusters/<cluster>/values/install-operators/ \
        clusters/<cluster>/applications/install-operators.yaml
git commit -m "add install-operators app and rhods-operator subscription"
git push
```

ArgoCD syncs `install-operators` at wave 1. The operator installs via OLM (allow 5-10
minutes). Once the CRDs are registered, `openshift-ai` at wave 4 syncs successfully.

To watch progress inside the container:

```bash
source hack/common.sh
watch -n 10 'oc get subscription -n redhat-ods-operator --insecure-skip-tls-verify=true; \
             echo; \
             oc get csv -n redhat-ods-operator --insecure-skip-tls-verify=true'
```

## Upstream contribution

The `applications-templates/install-operators.yaml.tpl` file should be contributed back to
`jharmison-redhat/openshift-setup`. It completes James's stated intent from commit `a751243`
and makes the framework self-contained for fresh cluster provisioning with RHOAI (or any
other operator installed via the `install-operators` chart).