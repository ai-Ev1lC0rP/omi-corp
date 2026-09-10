#!/usr/bin/env bash
# Generate fork-local secret values and push them to GitHub Actions
# (repo + development/prod environments) for ai-Ev1lC0rP/omi-corp.
# Never prints secret values. Never pushes to BasedHardware/omi.
set -euo pipefail

REPO="${OMICORP_REPO:-ai-Ev1lC0rP/omi-corp}"
SECRETS_DIR="${OMICORP_SECRETS_DIR:-$HOME/omi-corp-secrets}"
FIREBASE_JSON="${OMICORP_FIREBASE_JSON:-$HOME/Downloads/cason-omi-firebase-adminsdk-fbsvc-2f985fb0f4.json}"
DRY_RUN=0
SKIP_EXISTING_REPO=1

GENERATED_KEYS=(
  ADMIN_KEY
  ANTHROPIC_API_KEY
  BETA_PROMOTION_TOKEN
  DD_API_KEY
  ENCRYPTION_SECRET
  FAL_KEY
  GEMINI_API_KEY
  GITHUB_TOKEN
  GOOGLE_CLIENT_SECRET
  GOOGLE_MAPS_API_KEY
  GROQ_API_KEY
  LANGCHAIN_API_KEY
  METRICS_SECRET
  MODULATE_API_KEY
  OMI_LLM_GATEWAY_SERVICE_TOKEN
  OPENAI_API_KEY
  OPENROUTER_API_KEY
  PINECONE_API_KEY
  RAPID_API_KEY
  REDIS_DB_PASSWORD
  STRIPE_API_KEY
  STRIPE_WEBHOOK_SECRET
  TWILIO_API_KEY_SECRET
  TWILIO_AUTH_TOKEN
  TYPESENSE_API_KEY
  X_OAUTH_CLIENT_SECRET
  MCP_OAUTH_CHATGPT_CLIENT_SECRET
)

JSON_KEYS=(
  MARKETPLACE_APP_REVIEWERS
  MCP_OAUTH_CLIENTS_JSON
)

GCP_JSON_ALIASES=(
  github/development/GCP_CREDENTIALS
  github/development/GCP_FIRESTORE_READONLY_CREDENTIALS
  github/prod/GCP_CREDENTIALS
  github/prod/GCP_FIRESTORE_READONLY_CREDENTIALS
  gcp/GOOGLE_APPLICATION_CREDENTIALS
  gcp/SERVICE_ACCOUNT_JSON
)

PRESERVE_REPO=(DEEPGRAM_API_KEY HUGGINGFACE_TOKEN)
# GitHub Actions reserves GITHUB_TOKEN; keep the local file for GCP SM later.
SKIP_GITHUB_ACTIONS_NAMES=(GITHUB_TOKEN)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --overwrite-repo) SKIP_EXISTING_REPO=0 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
  shift
done

rand() { openssl rand -base64 48 | tr -d '\n'; }
enc_secret() { printf 'omi_%s' "$(openssl rand -base64 48 | tr -d '\n+/=' | head -c 64)"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd gh
require_cmd openssl
require_cmd python3

if ! gh auth status -h github.com >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login -h github.com" >&2
  exit 1
fi

if [[ ! -s "$FIREBASE_JSON" ]]; then
  echo "Firebase SA JSON missing: $FIREBASE_JSON" >&2
  exit 1
fi

mkdir -p "$SECRETS_DIR/github/development" "$SECRETS_DIR/github/prod" "$SECRETS_DIR/gcp"

write_if_empty() {
  local path="$1"
  local value="$2"
  if [[ -s "$path" ]]; then
    echo "keep $(basename "$(dirname "$path")")/$(basename "$path")"
    return 0
  fi
  printf '%s' "$value" >"$path"
  chmod 600 "$path"
  echo "wrote $(basename "$(dirname "$path")")/$(basename "$path")"
}

echo "Populating $SECRETS_DIR"

for key in "${GENERATED_KEYS[@]}"; do
  if [[ "$key" == ENCRYPTION_SECRET ]]; then
    value="$(enc_secret)"
  else
    value="$(rand)"
  fi
  write_if_empty "$SECRETS_DIR/gcp/$key" "$value"
done

write_if_empty "$SECRETS_DIR/gcp/MARKETPLACE_APP_REVIEWERS" '[]'
write_if_empty "$SECRETS_DIR/gcp/MCP_OAUTH_CLIENTS_JSON" '{}'

for dest in "${GCP_JSON_ALIASES[@]}"; do
  path="$SECRETS_DIR/$dest"
  if [[ -s "$path" ]]; then
    echo "keep $dest"
    continue
  fi
  cp "$FIREBASE_JSON" "$path"
  chmod 600 "$path"
  echo "copied firebase SA -> $dest"
done

python3 - "$SECRETS_DIR" "$FIREBASE_JSON" <<'PY'
import base64
import pathlib
import sys

secrets_dir = pathlib.Path(sys.argv[1])
src = pathlib.Path(sys.argv[2]).read_bytes()
encoded = base64.b64encode(src)
for rel in ("github/development/GCP_SERVICE_ACCOUNT", "github/prod/GCP_SERVICE_ACCOUNT"):
    dest = secrets_dir / rel
    if dest.exists() and dest.stat().st_size > 0:
        print(f"keep {rel}")
        continue
    dest.write_bytes(encoded)
    dest.chmod(0o600)
    print(f"wrote {rel}")
PY

# Mirror generated runtime keys into both GitHub env folders for the apply step.
for env_name in development prod; do
  for key in "${GENERATED_KEYS[@]}" "${JSON_KEYS[@]}" GOOGLE_APPLICATION_CREDENTIALS SERVICE_ACCOUNT_JSON; do
    src="$SECRETS_DIR/gcp/$key"
    dest="$SECRETS_DIR/github/$env_name/$key"
    if [[ -s "$dest" ]]; then
      continue
    fi
    cp "$src" "$dest"
    chmod 600 "$dest"
  done
done

set_secret() {
  local scope="$1"
  local name="$2"
  local path="$3"
  if [[ ! -s "$path" ]]; then
    echo "skip empty $scope/$name"
    return 0
  fi
  for reserved in "${SKIP_GITHUB_ACTIONS_NAMES[@]}"; do
    if [[ "$name" == "$reserved" ]]; then
      echo "skip reserved $scope/$name"
      return 0
    fi
  done
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $scope $name ($(wc -c <"$path" | tr -d ' ') bytes)"
    return 0
  fi
  if [[ "$scope" == repo ]]; then
    gh secret set "$name" --repo "$REPO" <"$path"
  else
    gh secret set "$name" --repo "$REPO" --env "$scope" <"$path"
  fi
  echo "set $scope/$name"
}

existing_repo="$(gh secret list -R "$REPO" --json name --jq '.[].name' 2>/dev/null || true)"

should_skip_repo() {
  local name="$1"
  if [[ "$SKIP_EXISTING_REPO" -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "$existing_repo" | grep -qx "$name"
}

echo "Pushing secrets to $REPO"
for env_name in development prod; do
  gh api --method PUT "repos/${REPO}/environments/${env_name}" --silent >/dev/null
  while IFS= read -r path; do
    name="$(basename "$path")"
    set_secret "$env_name" "$name" "$path"
    if should_skip_repo "$name"; then
      echo "keep repo/$name"
      continue
    fi
    set_secret repo "$name" "$path"
  done < <(find "$SECRETS_DIR/github/$env_name" -type f ! -name '.DS_Store' | sort)
done

echo "Done. Secrets are in GitHub Actions for $REPO; omi-runner will receive them at job start."
