# Linkerd Multicluster Setup - GitOps Approach

## Executive Summary

Linkerd 2.18+ (edge-25.4.4+) introduced a declarative, GitOps-compatible approach to managing multicluster links. This replaces the imperative `linkerd multicluster link` command with a fully declarative workflow using Link CRs and kubeconfig secrets stored in version control.

## Current State vs. Recommended State

### Current Approach (Legacy)

Your current [README.md](../cluster-tools/tools/linkerd-multicluster/README.md) documents the legacy approach:

```bash
# Manual, imperative link creation
linkerd --context=internal multicluster link \
  --cluster-name internal \
  --gateway-addresses tfx-internal.gerega.net:30143 \
  --service-account-name linkerd-service-mirror-remote-access-production \
  | kubectl --context=production apply -f -
```

**Problems with this approach:**

- Not GitOps-friendly (requires manual kubectl apply)
- No version control for Link resources
- Difficult to track what's deployed
- Manual process prone to drift
- No ArgoCD management

### Recommended Approach (Modern GitOps)

Use the declarative workflow introduced in Linkerd 2.18:

1. Generate Link CRs and secrets using `linkerd multicluster link-gen`
2. Store manifests in git under `cluster-tools/tools/linkerd-multicluster/templates/`
3. Reference links in the multicluster Helm `controllers` field
4. Let ArgoCD manage the entire lifecycle

## Implementation Plan

### Architecture Reminder

- **in-cluster-local**: Telemetry hub with gateway enabled (NodePort 30143)
- **production**: Links to internal for telemetry export
- **nonproduction**: Links to internal for telemetry export

### Security Approach

This implementation uses **External Secrets Operator** with **Vault** to securely manage kubeconfig credentials:

- Kubeconfigs are generated using `linkerd multicluster link-gen`
- Credentials are stored in Vault (never committed to git)
- ExternalSecret resources sync credentials from Vault to clusters
- Only the Link CRs are stored in git (no sensitive data)

### Step 1: Generate and Store Kubeconfigs in Vault

Run the provided script to generate kubeconfigs and store them securely in Vault:

**Bash:**

```bash
# Ensure you're logged into Vault
vault login

# Run the script to generate and store kubeconfigs
bash cluster-tools/tools/linkerd-multicluster/scripts/store-kubeconfig-in-vault.sh
```

**PowerShell:**

```powershell
# Ensure you're logged into Vault
vault login

# Run the script to generate and store kubeconfigs
.\cluster-tools\tools\linkerd-multicluster\scripts\store-kubeconfig-in-vault.ps1
```

**What this script does:**

1. Generates kubeconfig for production → internal link using `linkerd multicluster link-gen`
2. Generates kubeconfig for nonproduction → internal link
3. Stores both kubeconfigs in Vault at `secrets-k8/linkerd-multicluster/`
   - `production-to-internal`
   - `nonproduction-to-internal`

**Manual alternative (if you prefer):**

```bash
# Generate kubeconfig for production
KUBECONFIG_DATA=$(linkerd --context=internal multicluster link-gen \
  --cluster-name internal \
  --gateway-addresses tfx-internal.gerega.net:30143 \
  --service-account-name linkerd-service-mirror-remote-access-production | \
  grep -A 1000 "kind: Secret" | grep "kubeconfig:" | head -1 | awk '{print $2}')

# Store in Vault
vault kv put secrets-k8/linkerd-multicluster/production-to-internal kubeconfig="${KUBECONFIG_DATA}"

# Repeat for nonproduction...
```

### Step 2: Link CRs and ExternalSecrets Created

The following resources are already created in the Helm chart templates:

**Link CRs** (stored in git):

- `templates/link-to-internal-from-production.yaml` - Link CR for production cluster
- `templates/link-to-internal-from-nonproduction.yaml` - Link CR for nonproduction cluster

**ExternalSecrets** (stored in git):

- `templates/external-secret-production.yaml` - Syncs kubeconfig from Vault to production cluster
- `templates/external-secret-nonproduction.yaml` - Syncs kubeconfig from Vault to nonproduction cluster

These templates use Helm conditionals based on `clusterName` to deploy only to the correct cluster.

### Step 3: Update Helm Values to Use Controllers Field

Update the cluster-specific values files to reference the links:

**File: `cluster-tools/tools/linkerd-multicluster/config/production-values.yaml`**

```yaml
# Cluster identifier for conditional templates
clusterName: production

linkerd-multicluster:
  # Production cluster will link to internal for telemetry
  # No gateway needed on production (only internal needs gateway)
  gateway:
    enabled: false

  # Configure controller to manage the link
  controllers:
    - link:
        ref:
          name: in-cluster-local  # References the Link CR name

  # Grant access to internal cluster
  remoteMirrorServiceAccountName: linkerd-service-mirror-remote-access-in-cluster-local
```

**File: `cluster-tools/tools/linkerd-multicluster/config/nonproduction-values.yaml`**

```yaml
# Cluster identifier for conditional templates
clusterName: nonproduction

linkerd-multicluster:
  # Nonproduction cluster will link to internal for telemetry
  # No gateway needed on nonproduction (only internal needs gateway)
  gateway:
    enabled: false

  # Configure controller to manage the link
  controllers:
    - link:
        ref:
          name: in-cluster-local  # References the Link CR name

  # Grant access to internal cluster
  remoteMirrorServiceAccountName: linkerd-service-mirror-remote-access-in-cluster-local
```

**File: `cluster-tools/tools/linkerd-multicluster/config/in-cluster-local-values.yaml`**

```yaml
# Cluster identifier for conditional templates
clusterName: in-cluster-local

linkerd-multicluster:
  # Internal cluster acts as the telemetry hub
  # Gateway enabled with NodePort for cross-cluster service mirroring
  gateway:
    enabled: true
    port: 4143
    serviceType: NodePort
    nodePort: 30143
    probe:
      port: 4191
      nodePort: 30191

  # No controllers needed on internal (it's the target, not the source)
  # Internal receives connections, doesn't initiate them

  # Grant access to service accounts from production and nonproduction clusters
  # These will be created when those clusters link to internal
  remoteMirrorServiceAccountName: linkerd-service-mirror-remote-access-production,linkerd-service-mirror-remote-access-nonproduction
```

### Step 4: Commit to Git and Let ArgoCD Deploy

```bash
# Add the new templates
git add cluster-tools/tools/linkerd-multicluster/templates/link-*.yaml

# Update the values files
git add cluster-tools/tools/linkerd-multicluster/config/*.yaml

# Commit
git commit -m "feat: migrate linkerd multicluster to declarative GitOps approach"

# Push
git push
```

ArgoCD will automatically:

- Deploy the Link CRs to the appropriate clusters
- Create the kubeconfig secrets
- Configure the multicluster controllers to manage the links
- Maintain the desired state

### Step 5: Cleanup Legacy Links (Optional)

If you have existing links created with the old imperative method, you may want to clean them up:

```bash
# Check for existing links
kubectl --context=production get links -n linkerd-multicluster
kubectl --context=nonproduction get links -n linkerd-multicluster

# If they exist and you want to migrate, delete them
# ArgoCD will recreate them using the new approach
kubectl --context=production delete link in-cluster-local -n linkerd-multicluster
kubectl --context=nonproduction delete link in-cluster-local -n linkerd-multicluster
```

## Benefits of This Approach

1. **Full GitOps**: All multicluster configuration is in version control
2. **ArgoCD Managed**: Automatic sync, drift detection, and rollback capabilities
3. **Declarative**: No manual kubectl apply commands needed
4. **Auditable**: Git history shows all changes to multicluster links
5. **Reproducible**: Can recreate entire setup from git
6. **Scalable**: Easy to add new cluster links by following the same pattern
7. **Modern**: Uses Linkerd 2.18+ declarative features

## Verification

After deployment, verify the links are established:

```bash
# Check Link resources
kubectl --context=production get links -n linkerd-multicluster
kubectl --context=nonproduction get links -n linkerd-multicluster

# Check multicluster status
linkerd --context=production multicluster check
linkerd --context=nonproduction multicluster check

# Check for mirrored services
kubectl --context=production get svc --all-namespaces -l mirror.linkerd.io/mirrored-service
kubectl --context=nonproduction get svc --all-namespaces -l mirror.linkerd.io/mirrored-service
```

## Migration Checklist

- [ ] Generate Link manifests using `link-gen` for production → internal
- [ ] Generate Link manifests using `link-gen` for nonproduction → internal
- [ ] Wrap Link manifests in Helm conditionals for cluster-specific deployment
- [ ] Update production-values.yaml with `clusterName` and `controllers` field
- [ ] Update nonproduction-values.yaml with `clusterName` and `controllers` field
- [ ] Update in-cluster-local-values.yaml with `clusterName` field
- [ ] Commit all changes to git
- [ ] Push to trigger ArgoCD sync
- [ ] Verify links are established
- [ ] Clean up old imperative links (optional)
- [ ] Update README.md to document new approach

## References

- [Linkerd Multicluster GitOps Approach](https://linkerd.io/2.19/tasks/installing-multicluster/)
- [Linkerd 2.18 Release Notes](https://linkerd.io/2.19/tasks/troubleshooting/#l5d-multicluster-managed-controllers)
- [Linkerd Multicluster Helm Chart](https://github.com/linkerd/linkerd2/tree/main/multicluster/charts/linkerd-multicluster)

## Troubleshooting

### Controllers Not Managing Links

If you see the warning "extension is managing controllers" (`l5d-multicluster-managed-controllers`) failing, it means you have legacy service mirror controllers:

1. Ensure the `controllers` field is properly configured in your values
2. Delete old Link resources created with the imperative command
3. Let ArgoCD recreate them with the new approach
4. The new controllers will use Lease objects for management

### Link Resources Not Created

Check ArgoCD application status:

```bash
kubectl get application -n argocd linkerd-multicluster-production
kubectl describe application -n argocd linkerd-multicluster-production
```

Verify the Helm conditionals are working:

```bash
helm template cluster-tools/tools/linkerd-multicluster \
  -f cluster-tools/tools/linkerd-multicluster/config/production-values.yaml \
  | grep -A 20 "kind: Link"
```

### Probe Health Check Errors (Expected with NodePort)

When using NodePort gateway mode, you may see errors in service mirror logs like:

```text
Connection closed error=logical service probe-gateway-internal.linkerd-multicluster.svc.cluster.local:30191:
route default.undefined-port: forbidden TCP route
```

This is **expected behavior** with NodePort mode and does not affect service mirroring functionality. The probe endpoint (port 30191) has Linkerd authorization policy restrictions that prevent direct access, but the actual gateway traffic (port 30143) works correctly.

**Verification that service mirroring is working:**

```bash
# Check for mirrored services (should see services with -internal suffix)
kubectl --context=production get svc -A | grep internal
kubectl --context=nonproduction get svc -A | grep internal

# Verify Link status
kubectl --context=production get link -n linkerd-multicluster
kubectl --context=nonproduction get link -n linkerd-multicluster
```

If you see mirrored services created (e.g., `loki-gateway-internal`, `mimir-gateway-internal`), then multicluster is working correctly despite the probe errors.
