#!/usr/bin/env bash
# Populate GitHub Environment secrets + GCP Secret Manager for ai-Ev1lC0rP/omi-corp.
# Never pushes to BasedHardware/omi. Does not invent secret values — reads files you provide.
#
# Layout (default: ./omi-corp-secrets next to this script's CWD):
#   github/development/GCP_CREDENTIALS                 # raw SA JSON
#   github/development/GCP_FIRESTORE_READONLY_CREDENTIALS
#   github/development/TELEGRAM_BOT_TOKEN              # optional
#   github/development/TELEGRAM_CHAT_ID                # optional
#   github/development/GCP_SERVICE_ACCOUNT             # optional, base64 probe signer
#   github/prod/<same names>
#   gcp/<SECRET_NAME>                                  # one file per Secret Manager key
#
# Usage:
#   export OMICORP_SECRETS_DIR="$HOME/omi-corp-secrets"
#   scripts/omi-corp/setup-secrets.sh [--dry-run] [--github-only] [--gcp-only] [--env development|prod|both]
set -euo pipefail

REPO="${OMICORP_REPO:-ai-Ev1lC0rP/omi-corp}"
SECRETS_DIR="${OMICORP_SECRETS_DIR:-${PWD}/omi-corp-secrets}"
GCLOUD_BIN="${GCLOUD_BIN:-}"
DRY_RUN=0
DO_GITHUB=1
DO_GCP=1
ENV_FILTER=both

GITHUB_REQUIRED=(GCP_CREDENTIALS GCP_FIRESTORE_READONLY_CREDENTIALS)
GITHUB_OPTIONAL=(TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID GCP_SERVICE_ACCOUNT)

# Union of backend-secrets chart remoteKeys (dev + prod).
GCP_SECRET_KEYS=(
  ADMIN_KEY
  ANTHROPIC_API_KEY
  BETA_PROMOTION_TOKEN
  DD_API_KEY
  DEEPGRAM_API_KEY
  ENCRYPTION_SECRET
  FAL_KEY
  GEMINI_API_KEY
  GITHUB_TOKEN
  GOOGLE_APPLICATION_CREDENTIALS
  GOOGLE_CLIENT_SECRET
  GOOGLE_MAPS_API_KEY
  GROQ_API_KEY
  HUGGINGFACE_TOKEN
  LANGCHAIN_API_KEY
  MARKETPLACE_APP_REVIEWERS
  MCP_OAUTH_CHATGPT_CLIENT_SECRET
  MCP_OAUTH_CLIENTS_JSON
  METRICS_SECRET
  MODULATE_API_KEY
  OMI_LLM_GATEWAY_SERVICE_TOKEN
  OPENAI_API_KEY
  OPENROUTER_API_KEY
  PINECONE_API_KEY
  RAPID_API_KEY
  REDIS_DB_PASSWORD
  SERVICE_ACCOUNT_JSON
  STRIPE_API_KEY
  STRIPE_WEBHOOK_SECRET
  TWILIO_API_KEY_SECRET
  TWILIO_AUTH_TOKEN
  TYPESENSE_API_KEY
  X_OAUTH_CLIENT_SECRET
)

usage() {
  cat <<'EOF' >&2
Usage: setup-secrets.sh [--dry-run] [--github-only] [--gcp-only] [--env development|prod|both]

Env:
  OMICORP_SECRETS_DIR   directory of secret files (default: ./omi-corp-secrets)
  OMICORP_REPO          GitHub repo (default: ai-Ev1lC0rP/omi-corp)
  OMICORP_GCP_PROJECT   GCP project for Secret Manager
  GCLOUD_BIN            optional path to gcloud

Do not paste shell comments (# ...) on the same line as this command.
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --github-only) DO_GCP=0 ;;
    --gcp-only) DO_GITHUB=0 ;;
    --env)
      ENV_FILTER="${2:?}"
      shift
      ;;
    -h|--help) usage 0 ;;
    \#*)
      # Ignore accidental paste of "# comment" tokens from docs.
      echo "Ignoring comment token: $1" >&2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage 1
      ;;
  esac
  shift
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

resolve_gcloud() {
  if [[ -n "$GCLOUD_BIN" && -x "$GCLOUD_BIN" ]]; then
    echo "$GCLOUD_BIN"
    return 0
  fi
  if command -v gcloud >/dev/null 2>&1; then
    command -v gcloud
    return 0
  fi
  for candidate in \
    "$HOME/google-cloud-sdk/bin/gcloud" \
    /opt/homebrew/share/google-cloud-sdk/bin/gcloud \
    /usr/local/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

selected_envs() {
  case "$ENV_FILTER" in
    both) echo development; echo prod ;;
    development|prod) echo "$ENV_FILTER" ;;
    *)
      echo "--env must be development, prod, or both" >&2
      exit 1
      ;;
  esac
}

ensure_github_environment() {
  local env_name="$1"
  if gh api "repos/${REPO}/environments/${env_name}" >/dev/null 2>&1; then
    echo "GitHub environment exists: ${env_name}"
    return 0
  fi
  echo "Creating GitHub environment: ${env_name}"
  run gh api --method PUT "repos/${REPO}/environments/${env_name}" --silent
}

set_github_env_secret_from_file() {
  local env_name="$1"
  local secret_name="$2"
  local path="$3"
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  echo "Setting GitHub env secret ${env_name}/${secret_name} from ${path}"
  run gh secret set "$secret_name" --repo "$REPO" --env "$env_name" <"$path"
  return 0
}

upsert_gcp_secret_from_file() {
  local gcloud="$1"
  local project="$2"
  local secret_name="$3"
  local path="$4"
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  echo "Upserting GCP Secret Manager ${secret_name} from ${path}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run "$gcloud" secrets describe "$secret_name" --project="$project"
    run "$gcloud" secrets versions add "$secret_name" --project="$project" --data-file="$path"
    return 0
  fi
  if ! "$gcloud" secrets describe "$secret_name" --project="$project" >/dev/null 2>&1; then
    "$gcloud" secrets create "$secret_name" --project="$project" --replication-policy=automatic
  fi
  "$gcloud" secrets versions add "$secret_name" --project="$project" --data-file="$path"
}

scaffold_missing() {
  local env_name path
  mkdir -p "${SECRETS_DIR}/github/development" "${SECRETS_DIR}/github/prod" "${SECRETS_DIR}/gcp"
  for env_name in development prod; do
    for name in "${GITHUB_REQUIRED[@]}" "${GITHUB_OPTIONAL[@]}"; do
      path="${SECRETS_DIR}/github/${env_name}/${name}"
      if [[ ! -e "$path" ]]; then
        : >"$path"
        echo "Created empty placeholder: ${path}"
      fi
    done
  done
  local key
  for key in "${GCP_SECRET_KEYS[@]}"; do
    path="${SECRETS_DIR}/gcp/${key}"
    if [[ ! -e "$path" ]]; then
      : >"$path"
      echo "Created empty placeholder: ${path}"
    fi
  done
  cat <<EOF
Fill non-empty files under:
  ${SECRETS_DIR}/github/{development,prod}/
  ${SECRETS_DIR}/gcp/
Empty files are skipped. Re-run this script after filling values.
EOF
}

echo "Repo: ${REPO}"
echo "Secrets dir: ${SECRETS_DIR}"

if [[ ! -d "$SECRETS_DIR" ]]; then
  echo "Secrets directory missing; scaffolding empty placeholders."
  scaffold_missing
  exit 0
fi

if [[ "$DO_GITHUB" -eq 1 ]]; then
  require_cmd gh
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    echo "gh is not authenticated for github.com. Run: gh auth login -h github.com" >&2
    exit 1
  fi
  local_env=
  for local_env in $(selected_envs); do
    ensure_github_environment "$local_env"
    missing=0
    for name in "${GITHUB_REQUIRED[@]}"; do
      path="${SECRETS_DIR}/github/${local_env}/${name}"
      if [[ ! -s "$path" ]]; then
        echo "MISSING required: ${path}" >&2
        missing=1
        continue
      fi
      set_github_env_secret_from_file "$local_env" "$name" "$path"
    done
    for name in "${GITHUB_OPTIONAL[@]}"; do
      path="${SECRETS_DIR}/github/${local_env}/${name}"
      if [[ -s "$path" ]]; then
        set_github_env_secret_from_file "$local_env" "$name" "$path"
      else
        echo "Skipping optional empty/missing: ${path}"
      fi
    done
    if [[ "$missing" -eq 1 ]]; then
      echo "Required GitHub secrets missing for env=${local_env}" >&2
      exit 1
    fi
  done
fi

if [[ "$DO_GCP" -eq 1 ]]; then
  if ! gcloud_path="$(resolve_gcloud)"; then
    echo "gcloud not found. Install Google Cloud SDK or set GCLOUD_BIN=/path/to/gcloud" >&2
    echo "Skipping GCP Secret Manager until gcloud is available." >&2
    exit 1
  fi
  project="${OMICORP_GCP_PROJECT:-$("$gcloud_path" config get-value project 2>/dev/null || true)}"
  if [[ -z "$project" || "$project" == "(unset)" ]]; then
    echo "Set OMICORP_GCP_PROJECT or: gcloud config set project <your-project-id>" >&2
    exit 1
  fi
  echo "GCP project: ${project}"
  echo "Using gcloud: ${gcloud_path}"
  created=0
  skipped=0
  for key in "${GCP_SECRET_KEYS[@]}"; do
    path="${SECRETS_DIR}/gcp/${key}"
    if [[ -s "$path" ]]; then
      upsert_gcp_secret_from_file "$gcloud_path" "$project" "$key" "$path"
      created=$((created + 1))
    else
      echo "Skipping empty/missing GCP secret file: ${path}"
      skipped=$((skipped + 1))
    fi
  done
  echo "GCP secrets written=${created} skipped=${skipped}"
fi

echo "Done. Origin for this fork is ${REPO}; do not push to BasedHardware/omi."
