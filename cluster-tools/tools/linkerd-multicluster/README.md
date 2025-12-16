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

## Architecture: Flat Network Mode

This setup uses **flat network mode** (no gateway) for direct pod-to-pod communication between clusters. Since all clusters are on the same network (192.168.1.x), pods can communicate directly without a gateway, providing better performance and simpler configuration.

## Post-Installation: Linking Clusters

After the multi-cluster components are deployed, you need to manually link the clusters using flat network mode:

### 1. Link production to internal

```bash
# Link to internal cluster (flat network mode - no gateway addresses)
/c/Users/mattg/.linkerd2/bin/linkerd --context=internal multicluster link \
  --cluster-name internal \
  --service-account-name linkerd-service-mirror-remote-access-production \
  | kubectl --context=production apply -f -
```

### 2. Link nonproduction to internal

```bash
# Link to internal cluster (flat network mode - no gateway addresses)
/c/Users/mattg/.linkerd2/bin/linkerd --context=internal multicluster link \
  --cluster-name internal \
  --service-account-name linkerd-service-mirror-remote-access-nonproduction \
  | kubectl --context=nonproduction apply -f -
```

### 3. Verify links

```bash
# Check from production
/c/Users/mattg/.linkerd2/bin/linkerd --context=production multicluster check

# Check from nonproduction
/c/Users/mattg/.linkerd2/bin/linkerd --context=nonproduction multicluster check

# Check from internal
/c/Users/mattg/.linkerd2/bin/linkerd --context=internal multicluster check
```

## Exporting Services

In flat network mode, services are exported using the `mirror.linkerd.io/exported=remote-discovery` label:

```bash
# Example: Export Grafana Alloy service from internal for flat network mode
kubectl --context=internal label svc -n grafana alloy mirror.linkerd.io/exported=remote-discovery

# Or for traditional gateway mode (not used in this setup):
# kubectl label svc -n grafana alloy mirror.linkerd.io/exported=true
```

The service will then be mirrored to linked clusters as `<service-name>-<cluster-name>`.

### Flat Network Mode vs Gateway Mode

- **Flat network** (`remote-discovery`): Direct pod-to-pod communication, requires pod network routing between clusters
- **Gateway mode** (`true`): Traffic goes through a gateway, works across networks but requires LoadBalancer or NodePort

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
