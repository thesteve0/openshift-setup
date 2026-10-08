# Troubleshooting

A running log of errors I've hit and how to fix them.

---

## Empty kubeconfig wipes out cluster access and breaks bootstrap

### Symptoms

- `make` (running `bootstrap` inside the container) prints `Applying bootstrap` followed by a long string of dots and then exits with error code 1 after ~30 minutes
- `oc` commands inside the container return `Missing or incomplete configuration info`
- The cluster login page only shows htpasswd auth instead of GitHub OAuth
- The OAuth URL (`https://oauth-openshift.apps.<cluster>/...`) shows an invalid/self-signed certificate

### Root cause

The `kubeconfig` and `kubeconfig-orig` files in `install/<cluster>/auth/` are empty (0 bytes):

```bash
ls -la install/stardew-vision.sandbox5291.opentlc.com/auth/
# -rw-r--r--. 1 stpousty  0 Apr  8 17:20 kubeconfig
# -rw-r--r--. 1 stpousty  0 Apr  8 17:20 kubeconfig-orig
```

This happens because of a Make dependency chain that re-triggers `hack/install.sh` unexpectedly. The `kubeconfig` target depends on (among other things) `install/<cluster>/bootstrap/kustomization.yaml`. If that file gets regenerated with a newer timestamp than `kubeconfig` — which can happen when you run `make` after destroying and recreating the age or SSH keys — Make considers `kubeconfig` out of date and re-runs `hack/install.sh`.

Inside `install.sh`, the script checks `cluster_validate` (which uses `kubeconfig-orig` — which may not yet exist) and then falls through to `metadata_validate`. Since `metadata.json` exists from the previous install, the script concludes the cluster is already installed, prints `Skipping install`, and runs `touch "${INSTALL_DIR}/auth/kubeconfig"`. This overwrites the real credentials with an empty file.

The Makefile then creates `kubeconfig-orig` by copying from the now-empty `kubeconfig`, so both are wiped.

With empty kubeconfigs, every `oc` command fails, `oc apply -k` in `hack/bootstrap.sh` never succeeds, and ArgoCD is never bootstrapped — which means OAuth, cert-manager, and everything else never syncs.

### How to recover

The `kubeadmin-password` file is NOT touched by this process, so you can log back in.

Inside `make shell`:

```bash
# 1. Read the kubeadmin password
cat install/stardew-vision.sandbox5291.opentlc.com/auth/kubeadmin-password

# 2. Log in and write directly to the kubeconfig location
KUBECONFIG=install/stardew-vision.sandbox5291.opentlc.com/auth/kubeconfig \
  oc login https://api.stardew-vision.sandbox5291.opentlc.com:6443 \
  -u kubeadmin \
  -p <password-from-above> \
  --insecure-skip-tls-verify=true

# 3. Copy to kubeconfig-orig (what hack/common.sh actually uses for oc commands)
cp install/stardew-vision.sandbox5291.opentlc.com/auth/kubeconfig \
   install/stardew-vision.sandbox5291.opentlc.com/auth/kubeconfig-orig

# 4. Verify cluster access is restored
oc get nodes
```

Then, before re-running bootstrap, make sure all files in `clusters/<cluster>/` are committed and pushed — including any `secrets.enc.yaml` files. `hack/bootstrap.sh` calls `cluster_files_updated` which will refuse to proceed if anything is uncommitted or unpushed.

```bash
# Outside the container, from the repo root:
git add clusters/
git commit -m "add cluster config and encrypted secrets"
git push
```

Then inside the container:

```bash
make bootstrap
```

### After bootstrap completes

- ArgoCD will sync all applications (config, oauth, cert-manager, monitoring)
- GitHub OAuth will appear on the login page within a minute or two
- The cert-manager ACME DNS-01 challenge takes a few extra minutes — the invalid cert on the OAuth URL will resolve on its own once it completes

---

## GitHub OAuth login returns "An Authentication Error occurred"

### Symptoms

- The cluster login page shows GitHub as an option
- GitHub redirects back to the cluster successfully (GitHub's OAuth app shows users incrementing from 0 to 1)
- OpenShift shows "An Authentication Error occurred" on the console page

### Root causes (three separate issues hit in sequence)

**Issue 1: `organizations` set to a personal GitHub account, not an org**

The `values.yaml` had `organizations: [thesteve0]`. OpenShift checks org membership by calling the GitHub API endpoint `/orgs/{org}/members/{username}`. This endpoint only works for real GitHub organizations — it returns a 404 for personal accounts. The OAuth logs confirmed this:

```
AuthenticationError: User thesteve0 is not a member of any allowed organizations [thesteve0] (user is a member of [])
```

The fix: use a real GitHub organization name (e.g. `TechRavenConsulting`) in `organizations`.

**Issue 2: OpenShift requires `organizations` or `teams` for regular github.com**

Removing `organizations` entirely seemed like a fix, but OpenShift validates that when `hostname` is not set (i.e. you're using regular github.com, not GitHub Enterprise), at least one of `organizations` or `teams` must be specified. Setting `hostname: github.com` is also explicitly rejected. The ArgoCD sync failed with:

```
OAuth.config.openshift.io "cluster" is invalid: spec.identityProviders[0].github:
Invalid value: "null": one of organizations or teams must be specified unless hostname is set
```

And then:
```
spec.identityProviders[0].github.hostname: Invalid value: "github.com": cannot equal [*.]github.com
```

The fix: you must use a real GitHub org. `hostname` is only for GitHub Enterprise instances.

**Issue 3: Stale OAuth app authorization missing `read:org` scope**

After setting the correct org (`TechRavenConsulting`), login still failed with `user is a member of []`. This happened because GitHub had cached the OAuth app authorization from a previous login attempt, when OpenShift wasn't checking org membership. That cached authorization only had `user:email` scope — not `read:org` — so GitHub returned an empty org list even though the user was a member.

The fix: revoke the OAuth app authorization in GitHub settings, then log in again. GitHub will re-prompt with the full permission request including `read:org`.

To revoke: `https://github.com/settings/applications` → **Authorized OAuth Apps** → find the app for your cluster URL → **Revoke**.

### How the OAuth app and orgs relate

A common point of confusion: **the GitHub OAuth app and the organization are completely separate things**. You do not need to create a new OAuth app for each org you use.

- The **OAuth app** (client ID + secret) is the credential that lets OpenShift talk to GitHub's auth system. Created once, lives under whoever created it.
- The **organization** in the OpenShift config is just a post-authentication membership filter. After GitHub authenticates the user, OpenShift calls the GitHub API to check if that user is in the listed org.

### Diagnosing GitHub OAuth errors

The browser developer tools won't show the real error — it happens server-side. Check the OAuth pod logs:

```bash
# Inside make shell, after restoring kubeconfig-orig (see above)
source hack/common.sh
oc logs -n openshift-authentication -l app=oauth-openshift --tail=30
```

### Recovering `oc` access when kubeadmin is deleted

The oauth chart has `removeKubeAdmin: true` by default, which runs a PostSync job that deletes the `kubeadmin` secret. If GitHub OAuth breaks after that, you are locked out of `oc login`. Recover using the original admin client certificate from the install state:

```bash
# Inside make shell, from repo root
python3 -c "
import json, base64
with open('install/<cluster>/.openshift_install_state.json') as f:
    d = json.load(f)
kc = d['*kubeconfig.AdminClient']['File']['Data']
print(base64.b64decode(kc).decode())
" > install/<cluster>/auth/kubeconfig-orig

# Verify
KUBECONFIG=install/<cluster>/auth/kubeconfig-orig \
  install/<cluster>/oc --insecure-skip-tls-verify=true whoami
# should return: system:admin
```

This uses certificate-based auth (not a token), so it never expires and is unaffected by OAuth being broken. Use it whenever you need emergency cluster access.

---

## ArgoCD shows "no matches for kind" after a new operator installs CRDs

### Symptoms

An ArgoCD application is `OutOfSync` and the sync error says something like:

```
resource mapping not found for name: "odh-dashboard-config" namespace: "..."
no matches for kind "OdhDashboardConfig" in version "opendatahub.io/v1alpha"
ensure CRDs are installed first
```

...even though the CRD clearly exists (`oc get crd | grep odhdashboard` returns results) and
the resource may already exist in the cluster.

### Root cause

ArgoCD's application controller caches the cluster's API resource list. When a new operator
installs CRDs after ArgoCD has already started, the controller doesn't know about them until
it refreshes its cache. This causes the controller to report "no matches for kind" even though
the CRD is fully registered.

### Fix

Restart the ArgoCD application controller to force a cache refresh:

```bash
# Inside the container
source hack/common.sh
oc rollout restart statefulset openshift-gitops-application-controller -n openshift-gitops
oc rollout restart deployment openshift-gitops-server -n openshift-gitops
```

Wait 2-3 minutes for the controller to come back up. Then trigger a new sync:

```bash
oc patch application.argoproj.io/<app-name> -n openshift-gitops \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

The application should sync successfully on the next attempt.

---

## ArgoCD manifest generation fails with `Error: unknown command "secrets" for "helm"`

### Symptoms

An Application that uses `helm-secrets` value file schemes (e.g. `secrets+age-import://...`)
fails to generate manifests entirely:

```
Failed to load target state: failed to generate manifest for source 1 of 1: rpc error: code = Unknown
desc = failed to execute helm template command: failed running helm: `helm template . ...`
failed exit status 1: Error: unknown command "secrets" for "helm"
```

### Root cause (two issues, both required to hit this)

**Issue 1: no writable `$HOME` for Helm's plugin cache**

The `argocd-repo-server` image bundles Helm v4. Helm v4's plugin manager needs a writable
`$HOME/.cache/helm/wazero-build` directory to load *any* subprocess plugin — including
`helm-secrets`. The repo-server container runs with a read-only root filesystem and no `HOME`
set (defaults to `/`), so plugin loading fails silently — you get a `WARN` in the repo-server
logs, not a hard error, and `helm secrets` simply never gets registered.

**Issue 2: old-style `helm-secrets` tarball only registers as a `getter`, not a CLI subcommand**

Helm v4 changed the plugin format. A plugin now declares an explicit `type` (`cli/v1`,
`getter/v1`, `postrenderer/v1`) in its `plugin.yaml`. The old Helm 2/3-style single tarball
(`helm-secrets-X.tgz`) only gets picked up as `getter/v1` ("legacy") under Helm v4 — it never
registers the `helm secrets <cmd>` CLI subcommand that the PATH-shadowing `helm` wrapper script
(`/usr/local/sbin/helm` → `helm secrets template/install/upgrade/lint/diff`) depends on.
`jkroepke/helm-secrets` ships this as three separate release packages for Helm v4:
`secrets-X.tgz` (cli/v1), `secrets-getter-X.tgz` (getter/v1), `secrets-post-renderer-X.tgz`
(postrenderer/v1).

### Fix

In `bootstrap/argocd.yaml`, under `spec.repo`:

- Add `HOME=/tmp` as an env var on the repo-server container (fixes issue 1).
- Download and extract all three Helm-4-native packages instead of the single legacy tarball
  (fixes issue 2):
  ```
  curl -Lo - https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-${HELM_SECRETS_VERSION}.tgz | tar -C /custom-tools/helm-plugins -xzf-
  curl -Lo - https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-getter-${HELM_SECRETS_VERSION}.tgz | tar -C /custom-tools/helm-plugins -xzf-
  curl -Lo - https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-post-renderer-${HELM_SECRETS_VERSION}.tgz | tar -C /custom-tools/helm-plugins -xzf-
  ```
- The wrapper script's extracted path also changed with the new packaging — update the `cp`
  source from `.../helm-plugins/helm-secrets/scripts/wrapper/helm.sh` to
  `.../helm-plugins/secrets/scripts/wrapper/helm.sh`.

### Verifying

```bash
POD=$(oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-repo-server -o jsonpath='{.items[0].metadata.name}')
oc exec "$POD" -n openshift-gitops -- env HOME=/tmp /usr/local/bin/helm plugin list
# "secrets" should show TYPE cli/v1, not getter/v1
```

Then hard-refresh the affected Application — it should sync without the `unknown command
"secrets"` error.

### Pushing this fix to a cluster that's already bootstrapped

`bootstrap/argocd.yaml` only gets re-applied by `make bootstrap` / `hack/bootstrap.sh`, which
refuses to run again once a cluster is healthy (and does extra GitHub deploy-key / git-push
checks you may not want to trigger). To push just this file's change immediately:

```bash
oc apply -k install/<cluster-url>/bootstrap
```

This rolls a new `repo-server` pod automatically.

---

## RHOAI dashboard (`data-science-gateway`) login: redirect loop → 500 → 403

### Symptoms (in order, as each layer gets fixed)

1. Visiting `https://data-science-gateway.apps.<cluster>/` redirect-loops forever
   (`NS_ERROR_REDIRECT_LOOP` in Firefox) — every request gets a fresh `_oauth2_proxy_csrf`
   cookie and a 302 back to `/`, login is never actually initiated against the real IdP.
2. After a partial fix, the loop stops and you're correctly sent to
   `oauth-openshift.apps.<cluster>/oauth/authorize`, login succeeds, but the browser lands on a
   500 error, or later, a `403 Forbidden` / "Access to ... was denied" page.
3. Even after committing the correct fix, the error comes back intermittently until ArgoCD
   actually resyncs.

### Root cause

RHOAI 3.x's Gateway API-based dashboard (`GatewayConfig` resource, auto-created by the RHOAI
operator — not something this repo templates) deploys an OAuth-proxy-equivalent called
`kube-auth-proxy` into the **`openshift-ingress`** namespace. Recent OpenShift versions
auto-create a default-deny-all `NetworkPolicy` (covering both Ingress and Egress) in every core
platform namespace as a hardening baseline — `openshift-ingress` is one of them. RHOAI's
generated `NetworkPolicy` for `kube-auth-proxy` only declares **Ingress** rules, so under that
default-deny baseline `kube-auth-proxy` has no egress at all:

1. **Can't reach the in-cluster API service** (`172.30.0.1:443`) to auto-discover the OAuth
   login/token endpoints. Discovery fails silently (`context deadline exceeded`), so
   `kube-auth-proxy` just keeps re-initiating login forever → the redirect loop.
2. After allowing egress to the API server, the code-redeem call still fails: it POSTs to
   `https://oauth-openshift.apps.<cluster>/oauth/token`, which resolves to the cluster's
   **public** ingress NLB IP — genuinely external traffic from the pod's point of view, not
   something a `podSelector`-based egress rule can match. The call times out, and Envoy's
   `ext_authz` filter (RHOAI's gateway auth-check, which calls `kube-auth-proxy`'s
   `/oauth2/auth`) treats a failed/timed-out auth check as a hard deny →
   `403 ext_authz_error` shown to the browser.
3. The `NetworkPolicy` fix is managed by the `openshift-ai` ArgoCD Application
   (`argocd.argoproj.io/tracking-id` annotation). Any live `oc apply` edit gets silently
   reverted back to whatever's in git on ArgoCD's next poll (default ~3 min) — so a fix that
   "works" when tested live can appear to regress a few minutes later if it hasn't been
   committed and pushed yet.

### Fix

Added `charts/openshift-ai/templates/kube-auth-proxy-networkpolicy.yaml` — a **supplemental**
`NetworkPolicy` (NetworkPolicies targeting the same pod are additive/unioned, so this doesn't
conflict with the operator-owned one) allowing `kube-auth-proxy` pods
(`app=kube-auth-proxy` in `openshift-ingress`) to egress to:

- `openshift-kube-apiserver` pods on `6443` (OAuth endpoint discovery)
- `openshift-dns` namespace on `5353` (DNS resolution)
- `0.0.0.0/0` on `443` (the public `oauth-openshift` route, for login/token redeem — scoped to
  port 443 only; the ingress NLB's public IPs aren't stable enough to pin to specific `/32`s,
  and opening egress to the whole internet on just this one pod, just on 443, was judged an
  acceptable trade-off)

### Diagnosing this class of problem

Trace the request through each hop, in order:

```bash
# 1. kube-auth-proxy itself — shows OAuth discovery / redeem errors directly
oc logs -n openshift-ingress deployment/kube-auth-proxy --tail=50

# 2. the Istio/Envoy gateway pod — shows the real HTTP status and the ext_authz verdict
POD=$(oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=data-science-gateway -o jsonpath='{.items[0].metadata.name}')
oc logs "$POD" -n openshift-ingress -c istio-proxy --tail=50
# "ext_authz_denied" = no/expired auth cookie (normal, triggers login)
# "ext_authz_error"  = the auth check itself failed/timed out (a real bug — go look at kube-auth-proxy)

# 3. confirm whether egress/NetworkPolicy is actually the blocker
oc exec <kube-auth-proxy-pod> -n openshift-ingress -c kube-auth-proxy -- \
  curl -sk --max-time 5 -o /dev/null -w "HTTP:%{http_code} time:%{time_total}\n" <destination-url>
# HTTP:000 and time ~= --max-time means the connection is being blocked (NetworkPolicy/SG),
# not an application-level bug
```

### Gotcha: live `oc apply` edits to ArgoCD-managed resources don't stick

If a resource carries an `argocd.argoproj.io/tracking-id` annotation, ArgoCD owns it and will
revert any live edit back to git on its next poll. Use `oc apply` for fast live iteration while
debugging, but once a fix is confirmed, commit + push right away, then force an immediate
resync instead of waiting on the ~3 minute poll interval:

```bash
oc annotate application.argoproj.io <app-name> -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```

---

## Benign gRPC noise in apiserver logs: `failed to connect to <node-ip>:2379`

### Symptoms

`openshift-apiserver` and/or `kube-apiserver` pods repeatedly log, roughly every 10 seconds:

```
grpc: addrConn.createTransport failed to connect to {Addr: "<node-ip>:2379", ...}.
Err: connection error: desc = "transport: Error while dialing: dial tcp <node-ip>:2379: operation was canceled"
```

### What it actually is

This looked alarming (etcd connectivity failure) but checked out as cosmetic noise: etcd
health (`etcdctl endpoint health`), direct TCP reachability to `2379`, node resource/pressure,
and all ClusterOperator statuses were fine. It's gRPC's `pickfirstleaf` balancer rapidly
creating and cancelling subchannels — a known chatty pattern, not a real connectivity or etcd
problem. More noticeable on single-control-plane-node clusters since there's only one etcd
member to repeatedly reconnect to. Safe to ignore.