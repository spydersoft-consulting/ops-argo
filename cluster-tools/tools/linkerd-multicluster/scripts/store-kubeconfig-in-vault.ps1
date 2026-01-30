# Script to generate linkerd multicluster kubeconfigs and store them in Vault
# This script should be run after the multicluster extension is deployed

[CmdletBinding()]
param(
    [string]$VaultAddr = $env:VAULT_ADDR ?? "https://hcvault.mattgerega.net",
    [string]$VaultPath = "secrets-k8/linkerd-multicluster",
    [string]$InternalContext = "internal",
    [string]$InternalClusterName = "in-cluster-local",
    [string]$GatewayAddress = "tfx-internal.gerega.net:30143"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Linkerd Multicluster Kubeconfig to Vault ===" -ForegroundColor Green
Write-Host ""

# Check if logged into Vault
try {
    $null = vault token lookup 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged into Vault"
    }
} catch {
    Write-Host "Error: Not logged into Vault. Please run 'vault login' first." -ForegroundColor Red
    exit 1
}

Write-Host "This script will:" -ForegroundColor Yellow
Write-Host "1. Generate kubeconfig for production -> internal link"
Write-Host "2. Generate kubeconfig for nonproduction -> internal link"
Write-Host "3. Store them in Vault at: $VaultPath"
Write-Host ""

$continue = Read-Host "Continue? (y/n)"
if ($continue -notmatch '^[Yy]$') {
    exit 0
}

# Function to generate and store kubeconfig
function Store-Kubeconfig {
    param(
        [string]$SourceCluster,
        [string]$ServiceAccountName,
        [string]$VaultKey
    )

    Write-Host "Generating kubeconfig for $SourceCluster -> $InternalClusterName..." -ForegroundColor Green

    # Generate the kubeconfig using linkerd multicluster link-gen
    try {
        $output = linkerd --context=$InternalContext multicluster link-gen `
            --cluster-name $InternalClusterName `
            --gateway-addresses $GatewayAddress `
            --service-account-name $ServiceAccountName 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "linkerd command failed with exit code $LASTEXITCODE"
        }

        # Extract kubeconfig data from the output
        $secretSection = $output -join "`n" | Select-String -Pattern "(?s)kind: Secret.*?kubeconfig: ([A-Za-z0-9+/=]+)" -AllMatches

        if ($secretSection.Matches.Count -eq 0) {
            throw "Could not find kubeconfig in linkerd output"
        }

        $kubeconfigData = $secretSection.Matches[0].Groups[1].Value

        if ([string]::IsNullOrWhiteSpace($kubeconfigData)) {
            throw "Extracted kubeconfig data is empty"
        }

        Write-Host "Storing kubeconfig in Vault at $VaultPath/$VaultKey..." -ForegroundColor Green

        # Store in Vault
        $vaultOutput = vault kv put "$VaultPath/$VaultKey" "kubeconfig=$kubeconfigData" 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Successfully stored $VaultKey in Vault" -ForegroundColor Green
        } else {
            throw "vault command failed with exit code $LASTEXITCODE : $vaultOutput"
        }

    } catch {
        Write-Host "✗ Failed to store ${VaultKey}: $_" -ForegroundColor Red
        return $false
    }

    Write-Host ""
    return $true
}

# Generate and store production kubeconfig
$success = Store-Kubeconfig `
    -SourceCluster "production" `
    -ServiceAccountName "linkerd-service-mirror-remote-access-production" `
    -VaultKey "production-to-internal"

if (-not $success) {
    Write-Host "Failed to process production kubeconfig" -ForegroundColor Red
    exit 1
}

# Generate and store nonproduction kubeconfig
$success = Store-Kubeconfig `
    -SourceCluster "nonproduction" `
    -ServiceAccountName "linkerd-service-mirror-remote-access-nonproduction" `
    -VaultKey "nonproduction-to-internal"

if (-not $success) {
    Write-Host "Failed to process nonproduction kubeconfig" -ForegroundColor Red
    exit 1
}

Write-Host "=== Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Commit and push the multicluster Helm chart updates"
Write-Host "2. ArgoCD will sync and create ExternalSecrets"
Write-Host "3. ExternalSecrets will pull kubeconfigs from Vault"
Write-Host "4. Linkerd multicluster links will be established"
Write-Host ""
Write-Host "Verify with:"
Write-Host "  linkerd --context=production multicluster check"
Write-Host "  linkerd --context=nonproduction multicluster check"
