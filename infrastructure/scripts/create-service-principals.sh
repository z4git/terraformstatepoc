#!/usr/bin/env bash
# Creates (or updates, idempotently) the two workload identities the Terraform state workflows sign in as:
#
#   <prefix>-plan   used by .github/workflows/tfstate-infrastructure-plan.yml   (read only)
#   <prefix>-apply  used by .github/workflows/tfstate-infrastructure-deploy.yml (deploys)
#
# For each one it creates an app registration, a service principal, GitHub OIDC federated credentials
# (no client secrets are ever created) and the subscription-scope role assignments. Roles on the state
# storage account are NOT set here: infrastructure/bicep/modules/storage.bicep assigns those from the
# TERRAFORM_PLAN_PRINCIPAL_ID / TERRAFORM_APPLY_PRINCIPAL_ID repository variables printed by this script.
#
# Full walkthrough, including doing it by hand: docs/service-principal-setup.md
#
# Usage:
#   infrastructure/scripts/create-service-principals.sh --repo org/repo [options]
#
# Options:
#   --repo <org/repo>        GitHub owner and repository (required)
#   --subscription <id>      Target subscription (default: the az CLI's current subscription)
#   --parameter-file <path>  Parameter file the names are derived from
#                            (default: infrastructure/parameterfiles/tfstate-infrastructure.json)
#   --name-prefix <prefix>   Override the app registration name prefix
#                            (default: sp-<applicationName>-tfstate-<environmentName>-<environmentNumber>)
#   --default-branch <name>  Branch the deploy workflow runs on (default: main)
#   --owner-id <id>          GitHub owner database ID, for immutable-ID subject claims
#   --repo-id <id>           GitHub repository database ID, for immutable-ID subject claims
#                            (both are looked up with the gh CLI when it is available; when known, a second
#                            federated credential with subject repo:org@<owner-id>/repo@<repo-id>:... is
#                            added alongside the plain one, because GitHub can emit either form)
#   --no-immutable-subjects  Do not add the immutable-ID federated credentials
#   --apply-role <role>      "Owner" (default) or "Contributor+UAA" (Contributor + User Access Administrator)
#   --environments           Also add federated credentials for GitHub Environments
#                            (repo:org/repo:environment:<plan|apply environment>)
#   --plan-environment <n>   GitHub Environment name for plan  (default: tfstate-plan,  needs --environments)
#   --apply-environment <n>  GitHub Environment name for apply (default: tfstate-apply, needs --environments)
#   --set-github-variables   Write the repository variables with the gh CLI (needs gh auth login)
#   --dry-run                Print what would be done, change nothing
#   -h, --help               This help
#
# Requires: az (logged in with permission to create app registrations and role assignments), jq.
# Safe to re-run: every step checks first and only creates what is missing.

set -euo pipefail

REPO=""
SUBSCRIPTION_ID=""
PARAMETER_FILE=""
NAME_PREFIX=""
DEFAULT_BRANCH="main"
OWNER_ID=""
REPO_ID=""
IMMUTABLE_SUBJECTS="true"
APPLY_ROLE="Owner"
WITH_ENVIRONMENTS="false"
PLAN_ENVIRONMENT="tfstate-plan"
APPLY_ENVIRONMENT="tfstate-apply"
SET_GITHUB_VARIABLES="false"
DRY_RUN="false"

ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"
WHATIF_ROLE_NAME="${WHATIF_ROLE_NAME:-Terraform Plan What-If Operator}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROLE_TEMPLATE="$REPO_ROOT/infrastructure/rbac/terraform-plan-whatif-role.json"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)                  REPO="${2:-}"; shift 2 ;;
    --subscription)          SUBSCRIPTION_ID="${2:-}"; shift 2 ;;
    --parameter-file)        PARAMETER_FILE="${2:-}"; shift 2 ;;
    --name-prefix)           NAME_PREFIX="${2:-}"; shift 2 ;;
    --default-branch)        DEFAULT_BRANCH="${2:-}"; shift 2 ;;
    --owner-id)              OWNER_ID="${2:-}"; shift 2 ;;
    --repo-id)               REPO_ID="${2:-}"; shift 2 ;;
    --no-immutable-subjects) IMMUTABLE_SUBJECTS="false"; shift ;;
    --apply-role)            APPLY_ROLE="${2:-}"; shift 2 ;;
    --environments)          WITH_ENVIRONMENTS="true"; shift ;;
    --plan-environment)      PLAN_ENVIRONMENT="${2:-}"; WITH_ENVIRONMENTS="true"; shift 2 ;;
    --apply-environment)     APPLY_ENVIRONMENT="${2:-}"; WITH_ENVIRONMENTS="true"; shift 2 ;;
    --set-github-variables)  SET_GITHUB_VARIABLES="true"; shift ;;
    --dry-run)               DRY_RUN="true"; shift ;;
    -h|--help)               usage; exit 0 ;;
    *)                       err "Unknown argument '$1' (try --help)" ;;
  esac
done

command -v az >/dev/null || err "az CLI not found."
command -v jq >/dev/null || err "jq not found."

[ -n "$REPO" ] || err "--repo org/repo is required."
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || err "--repo must look like org/repo (got '$REPO')."
case "$APPLY_ROLE" in
  Owner|Contributor+UAA) ;;
  *) err "--apply-role must be 'Owner' or 'Contributor+UAA' (got '$APPLY_ROLE')." ;;
esac

PARAMETER_FILE="${PARAMETER_FILE:-$REPO_ROOT/infrastructure/parameterfiles/tfstate-infrastructure.json}"
[ -f "$PARAMETER_FILE" ] || err "Parameter file not found: $PARAMETER_FILE"
[ -f "$ROLE_TEMPLATE" ]  || err "Role definition template not found: $ROLE_TEMPLATE"

az account show >/dev/null 2>&1 || err "Not logged in. Run: az login"
if [ -z "$SUBSCRIPTION_ID" ]; then
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
fi
TENANT_ID="$(az account show --subscription "$SUBSCRIPTION_ID" --query tenantId -o tsv)"
SCOPE="/subscriptions/$SUBSCRIPTION_ID"

# Same inputs, same lower-casing as the workflows, so the names line up with the resource names.
APPLICATION_NAME="$(jq -r '.applicationName' "$PARAMETER_FILE" | tr '[:upper:]' '[:lower:]')"
ENVIRONMENT_NAME="$(jq -r '.environmentName' "$PARAMETER_FILE" | tr '[:upper:]' '[:lower:]')"
ENVIRONMENT_NUMBER="$(jq -r '.environmentNumber' "$PARAMETER_FILE")"
NAME_PREFIX="${NAME_PREFIX:-sp-$APPLICATION_NAME-tfstate-$ENVIRONMENT_NAME-$ENVIRONMENT_NUMBER}"

PLAN_APP_NAME="$NAME_PREFIX-plan"
APPLY_APP_NAME="$NAME_PREFIX-apply"

# GitHub can issue the OIDC subject in two shapes, depending on the repository's OIDC settings:
#   repo:org/repo:ref:refs/heads/main                       (plain)
#   repo:org@<owner-id>/repo@<repo-id>:ref:refs/heads/main  (immutable IDs, survives a rename)
# Entra ID matches the subject as a literal string, so a credential for one form does not match the other.
# Both are registered when the database IDs are known; the gh CLI provides them if not given.
if [ "$IMMUTABLE_SUBJECTS" = "true" ] && { [ -z "$OWNER_ID" ] || [ -z "$REPO_ID" ]; } && command -v gh >/dev/null; then
  ids="$(gh api "repos/$REPO" --jq '[.owner.id, .id] | @tsv' 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    OWNER_ID="${OWNER_ID:-$(printf '%s' "$ids" | cut -f1)}"
    REPO_ID="${REPO_ID:-$(printf '%s' "$ids" | cut -f2)}"
  fi
fi
if [ "$IMMUTABLE_SUBJECTS" = "true" ] && [ -n "$OWNER_ID" ] && [ -n "$REPO_ID" ]; then
  REPO_IMMUTABLE="${REPO%%/*}@$OWNER_ID/${REPO##*/}@$REPO_ID"
else
  REPO_IMMUTABLE=""
  IMMUTABLE_SUBJECTS="false"
fi

cat <<EOF

Repository        : $REPO
Subscription      : $SUBSCRIPTION_ID
Tenant            : $TENANT_ID
Plan identity     : $PLAN_APP_NAME
Apply identity    : $APPLY_APP_NAME
Apply role        : $APPLY_ROLE
Default branch    : $DEFAULT_BRANCH
Immutable subject : ${REPO_IMMUTABLE:-not registered (gh CLI unavailable, or --no-immutable-subjects)}
Environments      : $WITH_ENVIRONMENTS$( [ "$WITH_ENVIRONMENTS" = "true" ] && echo " ($PLAN_ENVIRONMENT / $APPLY_ENVIRONMENT)" )
Dry run           : $DRY_RUN

EOF

# Returns the appId of an app registration with this display name, creating it if there is none.
ensure_app() {
  local display_name="$1" app_id
  app_id="$(az ad app list --display-name "$display_name" --query "[?displayName=='$display_name'].appId | [0]" -o tsv 2>/dev/null || true)"
  if [ -n "$app_id" ] && [ "$app_id" != "null" ]; then
    info "App registration '$display_name' already exists ($app_id)." >&2
  else
    info "Creating app registration '$display_name'." >&2
    if [ "$DRY_RUN" = "true" ]; then
      printf 'DRY-RUN: az ad app create --display-name %q --sign-in-audience AzureADMyOrg\n' "$display_name" >&2
      app_id="00000000-0000-0000-0000-000000000000"
    else
      app_id="$(az ad app create --display-name "$display_name" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
    fi
  fi
  echo "$app_id"
}

# Returns the service principal object ID for an appId, creating the service principal if there is none.
ensure_sp() {
  local app_id="$1" object_id
  object_id="$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)"
  if [ -n "$object_id" ]; then
    info "Service principal for $app_id already exists ($object_id)." >&2
  else
    info "Creating service principal for $app_id." >&2
    if [ "$DRY_RUN" = "true" ]; then
      printf 'DRY-RUN: az ad sp create --id %q\n' "$app_id" >&2
      object_id="00000000-0000-0000-0000-000000000000"
    else
      object_id="$(az ad sp create --id "$app_id" --query id -o tsv)"
    fi
  fi
  echo "$object_id"
}

# Adds a federated credential unless one with the same subject already exists on the app.
ensure_federated_credential() {
  local app_id="$1" name="$2" subject="$3" description="$4" existing
  existing="$(az ad app federated-credential list --id "$app_id" --query "[?subject=='$subject'].name | [0]" -o tsv 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    info "Federated credential for '$subject' already exists (name: $existing)."
    return
  fi
  info "Adding federated credential '$name' for subject '$subject'."
  local parameters
  parameters="$(jq -n \
    --arg name "$name" --arg issuer "$ISSUER" --arg subject "$subject" \
    --arg description "$description" --arg audience "$AUDIENCE" \
    '{name: $name, issuer: $issuer, subject: $subject, description: $description, audiences: [$audience]}')"
  if [ "$DRY_RUN" = "true" ]; then
    echo "DRY-RUN: az ad app federated-credential create --id $app_id --parameters '$parameters'"
  else
    az ad app federated-credential create --id "$app_id" --parameters "$parameters" -o none
  fi
}

# Assigns a role at subscription scope unless the principal already has it there.
ensure_role_assignment() {
  local object_id="$1" role="$2" existing
  existing="$(az role assignment list --assignee "$object_id" --role "$role" --scope "$SCOPE" \
    --query "[?scope=='$SCOPE'] | length(@)" -o tsv 2>/dev/null || echo 0)"
  if [ "${existing:-0}" != "0" ]; then
    info "'$role' is already assigned at the subscription scope."
    return
  fi
  info "Assigning '$role' at $SCOPE."
  run az role assignment create --assignee-object-id "$object_id" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$SCOPE" -o none
}

# Creates the what-if custom role from infrastructure/rbac/terraform-plan-whatif-role.json.
ensure_whatif_role() {
  local existing definition_file
  existing="$(az role definition list --name "$WHATIF_ROLE_NAME" --scope "$SCOPE" --query "[0].roleName" -o tsv 2>/dev/null || true)"
  definition_file="$(mktemp)"
  jq --arg name "$WHATIF_ROLE_NAME" --arg scope "$SCOPE" \
    'del(.["//"]) | .Name = $name | .AssignableScopes = [$scope]' "$ROLE_TEMPLATE" > "$definition_file"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    info "Custom role '$WHATIF_ROLE_NAME' already exists; updating its actions."
    run az role definition update --role-definition "$definition_file" -o none
  else
    info "Creating custom role '$WHATIF_ROLE_NAME'."
    run az role definition create --role-definition "$definition_file" -o none
    # Role definitions are eventually consistent; the assignment right after can 404 without this.
    [ "$DRY_RUN" = "true" ] || sleep 20
  fi
  rm -f "$definition_file"
}

info "Plan identity"
PLAN_APP_ID="$(ensure_app "$PLAN_APP_NAME")"
PLAN_OBJECT_ID="$(ensure_sp "$PLAN_APP_ID")"
ensure_federated_credential "$PLAN_APP_ID" "github-pull-request" \
  "repo:$REPO:pull_request" "tfstate-infrastructure-plan.yml on pull requests"
if [ "$IMMUTABLE_SUBJECTS" = "true" ]; then
  ensure_federated_credential "$PLAN_APP_ID" "github-pull-request-ids" \
    "repo:$REPO_IMMUTABLE:pull_request" "tfstate-infrastructure-plan.yml on pull requests (immutable IDs)"
fi
if [ "$WITH_ENVIRONMENTS" = "true" ]; then
  ensure_federated_credential "$PLAN_APP_ID" "github-environment-plan" \
    "repo:$REPO:environment:$PLAN_ENVIRONMENT" "tfstate-infrastructure-plan.yml in the $PLAN_ENVIRONMENT environment"
  if [ "$IMMUTABLE_SUBJECTS" = "true" ]; then
    ensure_federated_credential "$PLAN_APP_ID" "github-environment-plan-ids" \
      "repo:$REPO_IMMUTABLE:environment:$PLAN_ENVIRONMENT" "tfstate-infrastructure-plan.yml in the $PLAN_ENVIRONMENT environment (immutable IDs)"
  fi
fi
ensure_role_assignment "$PLAN_OBJECT_ID" "Reader"
ensure_whatif_role
ensure_role_assignment "$PLAN_OBJECT_ID" "$WHATIF_ROLE_NAME"

echo
info "Apply identity"
APPLY_APP_ID="$(ensure_app "$APPLY_APP_NAME")"
APPLY_OBJECT_ID="$(ensure_sp "$APPLY_APP_ID")"
ensure_federated_credential "$APPLY_APP_ID" "github-branch-$DEFAULT_BRANCH" \
  "repo:$REPO:ref:refs/heads/$DEFAULT_BRANCH" "tfstate-infrastructure-deploy.yml on $DEFAULT_BRANCH"
if [ "$IMMUTABLE_SUBJECTS" = "true" ]; then
  ensure_federated_credential "$APPLY_APP_ID" "github-branch-$DEFAULT_BRANCH-ids" \
    "repo:$REPO_IMMUTABLE:ref:refs/heads/$DEFAULT_BRANCH" "tfstate-infrastructure-deploy.yml on $DEFAULT_BRANCH (immutable IDs)"
fi
if [ "$WITH_ENVIRONMENTS" = "true" ]; then
  ensure_federated_credential "$APPLY_APP_ID" "github-environment-apply" \
    "repo:$REPO:environment:$APPLY_ENVIRONMENT" "tfstate-infrastructure-deploy.yml in the $APPLY_ENVIRONMENT environment"
  if [ "$IMMUTABLE_SUBJECTS" = "true" ]; then
    ensure_federated_credential "$APPLY_APP_ID" "github-environment-apply-ids" \
      "repo:$REPO_IMMUTABLE:environment:$APPLY_ENVIRONMENT" "tfstate-infrastructure-deploy.yml in the $APPLY_ENVIRONMENT environment (immutable IDs)"
  fi
fi
if [ "$APPLY_ROLE" = "Owner" ]; then
  ensure_role_assignment "$APPLY_OBJECT_ID" "Owner"
else
  ensure_role_assignment "$APPLY_OBJECT_ID" "Contributor"
  ensure_role_assignment "$APPLY_OBJECT_ID" "User Access Administrator"
fi

echo
info "GitHub repository variables (Settings -> Secrets and variables -> Actions -> Variables)"
cat <<EOF

  AZURE_TENANT_ID                = $TENANT_ID
  AZURE_SUBSCRIPTION_ID          = $SUBSCRIPTION_ID
  AZURE_PLAN_CLIENT_ID           = $PLAN_APP_ID
  AZURE_APPLY_CLIENT_ID          = $APPLY_APP_ID
  TERRAFORM_PLAN_PRINCIPAL_ID    = $PLAN_OBJECT_ID
  TERRAFORM_APPLY_PRINCIPAL_ID   = $APPLY_OBJECT_ID

EOF

if [ "$SET_GITHUB_VARIABLES" = "true" ]; then
  command -v gh >/dev/null || err "gh CLI not found (needed for --set-github-variables)."
  info "Setting the variables with the gh CLI on $REPO."
  run gh variable set AZURE_TENANT_ID           --repo "$REPO" --body "$TENANT_ID"
  run gh variable set AZURE_SUBSCRIPTION_ID     --repo "$REPO" --body "$SUBSCRIPTION_ID"
  run gh variable set AZURE_PLAN_CLIENT_ID      --repo "$REPO" --body "$PLAN_APP_ID"
  run gh variable set AZURE_APPLY_CLIENT_ID     --repo "$REPO" --body "$APPLY_APP_ID"
  run gh variable set TERRAFORM_PLAN_PRINCIPAL_ID  --repo "$REPO" --body "$PLAN_OBJECT_ID"
  run gh variable set TERRAFORM_APPLY_PRINCIPAL_ID --repo "$REPO" --body "$APPLY_OBJECT_ID"
else
  echo "  Or with the gh CLI:"
  echo
  echo "    gh variable set AZURE_TENANT_ID --repo $REPO --body $TENANT_ID"
  echo "    gh variable set AZURE_SUBSCRIPTION_ID --repo $REPO --body $SUBSCRIPTION_ID"
  echo "    gh variable set AZURE_PLAN_CLIENT_ID --repo $REPO --body $PLAN_APP_ID"
  echo "    gh variable set AZURE_APPLY_CLIENT_ID --repo $REPO --body $APPLY_APP_ID"
  echo "    gh variable set TERRAFORM_PLAN_PRINCIPAL_ID --repo $REPO --body $PLAN_OBJECT_ID"
  echo "    gh variable set TERRAFORM_APPLY_PRINCIPAL_ID --repo $REPO --body $APPLY_OBJECT_ID"
  echo
fi

cat <<'EOF'
Next: merge a change under infrastructure/ to main so tfstate-infrastructure-deploy.yml runs. The Bicep
deployment assigns the storage account and container roles (Storage Blob Data Reader / Contributor,
Storage Account Contributor) to the two principal IDs above, and adds them to the state access alert's
allow-list. Until that run finishes, the identities only have the subscription-scope roles set here.
EOF
