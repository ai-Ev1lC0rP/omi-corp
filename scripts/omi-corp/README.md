# omi-corp fork helpers

Private-fork tooling for https://github.com/ai-Ev1lC0rP/omi-corp.

Do not push these secrets or deploy credentials to BasedHardware/omi.

## setup-secrets.sh

1. Authenticate: `gh auth login -h github.com`
2. Install / PATH `gcloud` (or set `GCLOUD_BIN`)
3. Scaffold (once):

```bash
cd /Users/ev1lc0rp/Development/omi/.worktrees/omi-corp-self-hosted-ci
export OMICORP_SECRETS_DIR="$HOME/omi-corp-secrets"
./scripts/omi-corp/setup-secrets.sh
```

4. Fill required files under `github/{development,prod}/` and whichever `gcp/*` keys you need. Paste one command at a time — do not paste `#` comments.
5. Apply GitHub secrets first:

```bash
export OMICORP_SECRETS_DIR="$HOME/omi-corp-secrets"
./scripts/omi-corp/setup-secrets.sh --github-only --dry-run
./scripts/omi-corp/setup-secrets.sh --github-only
```

6. Then GCP Secret Manager (needs `gcloud` + real project id):

```bash
export OMICORP_GCP_PROJECT="your-gcp-project-id"
./scripts/omi-corp/setup-secrets.sh --gcp-only --dry-run
./scripts/omi-corp/setup-secrets.sh --gcp-only
```

`--env development|prod|both` narrows GitHub environments.

## Backend CI runners

Backend unit/checks/hermetic workflows use `runs-on: [self-hosted, Linux, X64]`.
Your runner must advertise those labels (GitHub's default self-hosted Linux x64 labels).
