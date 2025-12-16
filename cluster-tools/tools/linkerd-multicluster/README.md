# Linkerd Multi-cluster Setup

This tool installs Linkerd multi-cluster components to enable secure cross-cluster communication between clusters that share a common trust anchor.

## Architecture

- **internal cluster**: Acts as the telemetry collection hub, receives connections from production and nonproduction
- **production cluster**: Connects to internal for telemetry export
- **nonproduction cluster**: Connects to internal for telemetry export

## Prerequisites

1. All clusters must have Linkerd control plane installed with a shared trust anchor
2. Clusters must be labeled with `spydersoft.io/linkerd-multicluster: "true"` in ArgoCD
3. LoadBalancer service support (for gateway)
4. `linkerd` CLI installed locally for linking operations

## Deployment

The ApplicationSet will automatically deploy linkerd-multicluster to any cluster with the label `spydersoft.io/linkerd-multicluster: "true"`.

### Add label to clusters in ArgoCD:

```bash
# Label internal cluster
kubectl label secret -n argocd <internal-cluster-secret> spydersoft.io/linkerd-multicluster=true

# Label production cluster
kubectl label secret -n argocd <production-cluster-secret> spydersoft.io/linkerd-multicluster=true

# Label nonproduction cluster
kubectl label secret -n argocd <nonproduction-cluster-secret> spydersoft.io/linkerd-multicluster=true
```

## Post-Installation: Linking Clusters

After the multi-cluster components are deployed, you need to manually link the clusters:

### 1. Link production to internal

```bash
# Switch to production cluster context
kubectl config use-context production

# Link to internal cluster
linkerd --context=internal multicluster link-gen --cluster-name internal --gateway-addresses tfx-internal.gerega.net:30143 --service-account-name linkerd-service-mirror-remote-access-production | kubectl --context=production apply -f -
```

### 2. Link nonproduction to internal

```bash
# Switch to nonproduction cluster context
kubectl config use-context nonproduction

# Link to internal cluster
linkerd --context=internal multicluster link-gen --cluster-name internal --gateway-addresses tfx-internal.gerega.net:30143 --service-account-name linkerd-service-mirror-remote-access-nonproduction | kubectl --context=nonproduction apply -f -
```

### 3. Verify links

```bash
# Check from production
kubectl config use-context production
linkerd multicluster check

# Check from nonproduction
kubectl config use-context nonproduction
linkerd multicluster check

# Check from internal
kubectl config use-context internal
linkerd multicluster check
```

## Exporting Services

To make services available across clusters, label them with `mirror.linkerd.io/exported=true`:

```bash
# Example: Export Grafana Alloy service from internal to production
kubectl label svc -n grafana alloy mirror.linkerd.io/exported=true
```

The service will then be mirrored to linked clusters as `<service-name>-<cluster-name>`.

## Configuration

Each cluster has its own configuration file:

- `config/in-cluster-local-values.yaml` - Internal cluster (telemetry hub)
- `config/production-values.yaml` - Production cluster
- `config/nonproduction-values.yaml` - Nonproduction cluster

### Key Configuration Options

- `gateway`: Enable/disable the gateway (true by default)
- `remoteMirrorServiceAccountName`: Comma-separated list of clusters allowed to mirror services
- `gatewayPort`: Port for the gateway service (default: 4143)
- `enableServiceMonitor`: Enable Prometheus ServiceMonitor for gateway metrics

## Verification

```bash
# Check gateway status
kubectl get svc -n linkerd-multicluster

# Check service mirrors
kubectl get svc --all-namespaces -l mirror.linkerd.io/mirrored-service

# Check gateway logs
kubectl logs -n linkerd-multicluster -l component=linkerd-gateway
```

## Troubleshooting

### Gateway not accessible

- Verify LoadBalancer has assigned an external IP: `kubectl get svc -n linkerd-multicluster linkerd-gateway`
- Check gateway logs for errors
- Verify firewall rules allow traffic on port 4143

### Services not mirroring

- Ensure service has the correct export label: `mirror.linkerd.io/exported=true`
- Check service-mirror controller logs: `kubectl logs -n linkerd-multicluster -l component=linkerd-service-mirror`
- Verify link is established: `linkerd multicluster check`

### Certificate errors

- Verify all clusters share the same trust anchor
- Check certificate validity: `linkerd check --proxy`

## References

- [Linkerd Multi-cluster Documentation](https://linkerd.io/2-edge/features/multicluster/)
- [Installing Multi-cluster Components](https://linkerd.io/2-edge/tasks/installing-multicluster/)
