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