# App-of-Apps Issue: Malformed Manifest Blocks All Applications

This directory demonstrates how a single malformed YAML manifest can block synchronization of ALL applications in an ArgoCD app-of-apps pattern.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/)

## Quick Start

### 1. Create KIND Cluster with ArgoCD

```bash
# From the repository root
./scripts/create-kind-argocd-sandbox.sh
```

This creates a KIND cluster named `argocd-sandbox` with ArgoCD installed.

### 2. Access ArgoCD UI

```bash
# Get the admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access at https://argocd.localhost (or use port-forward)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open https://localhost:8080 and login with username `admin`.

### 3. Apply the App-of-Apps

```bash
kubectl apply -f app-of-apps-issue/app-project.yaml
kubectl apply -f app-of-apps-issue/app-of-apps.yaml
```

This deploys:

- `guestbook-1`, `guestbook-2`, `guestbook-3` - Valid applications
- `guestbook-4-malformed` - Contains malformed YAML (currently fixed)

## Reproducing the Issue

### Step 1: Break the Manifest

Edit `manifests/guestbook-4-malformed/application.yaml` and introduce invalid YAML:

```yaml
metadata:
  annotations:
    # Remove quotes to break YAML - comma at start is invalid
    owner: , admin@example.com # ❌ INVALID YAML
```

Valid version (current):

```yaml
metadata:
  annotations:
    owner: ", admin@example.com" # ✅ Valid - quoted string
```

### Step 2: Commit and Push

```bash
git add .
git commit -m "break: introduce malformed yaml"
git push
```

### Step 3: Observe the Failure

Wait for ArgoCD to detect the change (or manually refresh), then check:

```bash
# All applications show Unknown status
kubectl get applications -n argocd

# Check the error on app-of-apps
kubectl get application app-of-apps -n argocd -o jsonpath='{.status.conditions[*].message}'
```

**Expected output:**

```
NAME          SYNC STATUS   HEALTH STATUS
app-of-apps   Unknown       Healthy        # ❌ Blocked!
guestbook-1   Synced        Healthy        # Won't update
guestbook-2   Synced        Healthy        # Won't update
guestbook-3   Synced        Healthy        # Won't update
```

**Error message:**

```
Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = FailedPrecondition desc = Failed to unmarshal "application.yaml": <nil>
```

### Step 4: Verify ALL Applications Are Blocked

Even though only `guestbook-4-malformed/application.yaml` is broken, the entire `app-of-apps` cannot sync. This means:

- No new applications can be added
- No existing applications can be updated
- The diff shows intent to DELETE all managed resources

## Solution: ApplicationSet

Apply the ApplicationSet-based solution:

```bash
# Remove the broken app-of-apps
kubectl delete application app-of-apps -n argocd --cascade=orphan

# Apply the ApplicationSet
kubectl apply -f app-of-apps-issue/app-of-apps-set.yaml
```

Now check the status:

```bash
kubectl get applications -n argocd
```

**Expected output:**

```
NAME                           SYNC STATUS   HEALTH STATUS
tenant-guestbook-1             Synced        Healthy   # ✅ Working
tenant-guestbook-2             Synced        Healthy   # ✅ Working
tenant-guestbook-3             Synced        Healthy   # ✅ Working
tenant-guestbook-4-malformed   Unknown       Healthy   # ⚠️ Isolated failure
```

**Key difference:** The malformed manifest only affects its own Application, not the others!

## File Structure

```
app-of-apps-issue/
├── README.md                 # This file
├── app-of-apps.yaml          # Original app-of-apps (problematic)
├── app-of-apps-set.yaml      # ApplicationSet solution
├── app-project.yaml          # ArgoCD AppProject
└── manifests/
    ├── guestbook-1/          # Valid tenant
    ├── guestbook-2/          # Valid tenant
    ├── guestbook-3/          # Valid tenant
    └── guestbook-4-malformed/ # Tenant with malformed YAML
```

## Cleanup

```bash
# Delete the KIND cluster
DELETE=true ./scripts/create-kind-argocd-sandbox.sh
```
