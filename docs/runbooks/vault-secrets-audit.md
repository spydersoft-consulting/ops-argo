# Vault contents vs actual usage (ExternalSecrets + Terraform)

Audit of `hcvault.mattgerega.net` against what's actually declared in the
cluster repos (ops-prod-cluster, ops-nonprod-cluster, ops-internal-cluster,
ops-argo) and in `ops-automation/terraform`. Snapshot taken **2026-07-27**.
Re-run the greps below before acting on this if it's been more than a
few weeks — Vault content and repo state both drift.

## Architecture

The `ClusterSecretStore` (`ops-prod-cluster/cluster-resources/vault-backend.yaml`,
mirrored in `ops-nonprod-cluster`) is scoped to `path: "secrets-k8"` only, via
AppRole. **ExternalSecrets can never see `secrets-infra`** — that mount is
read/written exclusively by OpenTofu (via `hcvault/approle/terraform-approle`)
for CI/infra secrets. Two separate audiences, audited separately below.

Some `secrets-k8` paths are also consumed directly by Grafana Alloy
(`monitoring-plan` repo, `.alloy` configs) rather than through an
ExternalSecret — those don't show up in a `kind: ExternalSecret` grep but are
still live.

## How this was generated

```sh
export VAULT_ADDR=https://hcvault.mattgerega.net

# recursive kv listing (no jq/python available in this shell, plain bash recursion)
list_recursive() {
  local mount=$1 path=$2 full="${mount}${path}"
  vault kv list -format=table "$full" 2>/dev/null | tail -n +3 | while IFS= read -r item; do
    [ -z "$item" ] && continue
    if [[ "$item" == */ ]]; then list_recursive "$mount" "${path}${item}"; else echo "${path}${item}"; fi
  done
}
list_recursive "secrets-k8/" ""
list_recursive "secrets-infra/" ""

# per-key metadata (created/updated/version) to spot stale entries
vault kv metadata get -format=json "secrets-k8/<path>"
```

Cross-referenced against:

```sh
grep -rn 'key: secrets-k8' <all cluster repos>/*.yaml
grep -rn 'resource "vault_kv_secret_v2"\|data "vault_kv_secret_v2"' ops-automation/terraform --exclude-dir=.terraform
```

## `secrets-k8` (64 keys) — ExternalSecrets + Alloy

### Actively referenced (44 keys)

Everything not listed below has a live `ExternalSecret` (or, for the
`monitoring/*` paths noted, an Alloy config) pointing at it. Full list
omitted here for brevity — see the grep command above to regenerate.

### Orphaned — legacy, no consumer found, untouched since 2023

Strong delete candidates:

| Key | Last updated |
|---|---|
| `bitbucket` | 2023-01-27 |
| `hass` | 2023-06-06 |
| `proget` | 2023-02-22 |
| `proget-cr-config` | 2023-02-07 |
| `sendgrid` | 2023-01-27 |
| `wordpress/db` | 2023-01-27 (superseded by `wordpress/database`, which *is* used) |
| `monitoring/test` | 2023-01-31 |
| `identity/production/connections` | 2023-12-01 (identity-server ES never references a `connections` field) |
| `techradar/production/data` / `techradar/test/data` / `techradar/stage/data` | 2024-01-24 |

### Orphaned — no ES/Alloy consumer, but more recent — verify before deleting

| Key | Last updated |
|---|---|
| `ha-dashboard/test/auth` | 2025-03-12 |
| `ha-frontend/test/auth` | 2025-03-12 |
| `n8n/postgres` | 2025-06-20 |
| `wordpress/anthropic` | 2025-10-02 |
| `wordpress/openai` | 2025-10-02 |
| `rabbitmq/nonproduction` | 2024-02-22 |

### `stage/*` keys with no matching manifests yet

Vault has these seeded, but no `apps/**/stage` (or similarly named)
directory exists in `ops-prod-cluster`/`ops-nonprod-cluster` referencing
them. Several were touched as recently as **2026-07-10**, so this looks
like an in-flight "stage" environment being prepped ahead of the
manifests landing — **not** stale cruft, don't delete without checking
current plans first:

`audit/stage/{mongodb,rabbitmq}`, `filestore-api/stage/{postgres,s3}`,
`identity/stage/{admin-frontend,connections,postgres,providers/google}`,
`pitstop/stage/{auth,postgres}`, `techradar/stage/{auth,postgres}`

### Used, but not via ExternalSecrets (don't flag as orphaned)

`monitoring/vault`, `monitoring/targets/internal`, `monitoring/minio`,
`monitoring/garage/metrics` — read directly by Grafana Alloy
(`monitoring-plan/current-alloy-config.alloy` and
`configs/in-cluster-local-merged.alloy`).

## `secrets-infra` (26 keys) — Terraform/OpenTofu only

### Written by Terraform (`vault_kv_secret_v2` resources — TF owns the value)

- `azure/service-principals/terraform-gerega-lab-sp`
- `azure/service-principals/terraform-azuread-sp`
- `azure/applications/grafana`
- `azure/applications/argocd`
- `azure/applications/hcvault`

(all in `ops-automation/terraform/azuread/{vault-infrastructure-secrets,application-vault-autounseal}.tf`)

### Read by Terraform (`data` sources — expected to pre-exist, manually seeded)

`github/{terraform,sonar,pypi,nuget,spydersoft-ado}`, `azure/devops`,
`azure/buildagent/ubuntu`, `hcvault/approle/terraform-approle`,
`garage/terraform-access`, `sonarqube/ado-public-projects`,
`kubernetes/{nonproduction,production}/kubeconfig`,
`mattgerega/authentication/ro_client`, `access/authorized_keys`,
`proxmox/agent`

(mostly in `ops-automation/terraform/devops/vault-infrastructure-secrets.tf`,
plus `gh-spydersoft/data-vault-infrastructure-secrets.tf`)

### No Terraform reference anywhere (checked by name *and* by literal path fragment, to catch indirect refs via a differently-named `local`/data block — none found)

| Key | Last updated |
|---|---|
| `atlassian/api` | 2025-03-13 |
| `azure/compass-pat` | 2025-04-18 |
| `garage/config-secrets` | 2025-12-10 |
| `garage/main-key` | 2026-01-18 |
| `garage/wordpress-key` | 2025-12-10 |
| `homeassistant/mcp` | 2025-12-12 |
| `minio/terraform-access` | 2026-01-18 |
| `proget/docker` | 2024-02-14 |
| `proget/nuget` | 2024-11-07 |
| `sonarqube/analysis/spydersoft-consulting` | 2026-05-03 |

Since none of these ever had an IaC reference to begin with, deleting any
of them (if truly dead) is a pure Vault-side operation — no Terraform
cleanup follows from it. The `proget/*` pair looks like genuine 2023-2024
leftovers if ProGet isn't in use anymore. The rest (`garage/*`, `minio`,
`homeassistant/mcp`, `sonarqube/analysis`, `compass-pat`, `atlassian/api`)
are recent enough (2025-2026) that they're plausibly consumed by scripts,
WordPress plugins, or manual workflows outside these repos — confirm
before deleting.

## Decision: personal/reference-only entries

Some `secrets-infra` values are just for safekeeping (not consumed by any
automation) and don't belong mixed in with IaC-managed secrets — every
future audit like this one will flag them as false-positive orphans.

**Decision (2026-07-27):** use a path prefix, not a separate mount —
e.g. `secrets-infra/personal/<name>`. Lighter than provisioning a whole
new secrets engine/policy/AppRole; relies on convention rather than a
hard access-control boundary, which is an accepted tradeoff here. Once
adopted, this audit's "no Terraform reference anywhere" section should
exclude anything under `personal/` by construction, and any orphan
candidate above that turns out to be personal-reference-only should be
moved under the prefix rather than deleted.

**TODO:** go through the "no Terraform reference anywhere" list above and
tag which ones are actually personal reference material to migrate under
`secrets-infra/personal/`, vs. genuinely dead entries to delete outright.
