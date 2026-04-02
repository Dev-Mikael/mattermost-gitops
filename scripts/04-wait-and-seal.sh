#!/usr/bin/env bash
# scripts/04-wait-and-seal.sh
# 1. Waits for the infrastructure Flux Kustomization to be Ready
# 2. Waits specifically for Sealed Secrets controller to be Running
# 3. Generates plain-text Kubernetes Secrets from .env values
# 4. Seals them with kubeseal
# 5. Commits the sealed secrets to Git
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "04 — Seal Secrets"

require_tool kubectl
require_tool kubeseal
require_tool git

# ── 1. Wait for infrastructure Kustomization ────────────────
log_step "Waiting for 'infrastructure' Kustomization to be Ready (up to 10 min)"
# Force immediate reconciliation
flux reconcile kustomization infrastructure --with-source --timeout=10m || true

# Poll until Ready
for i in $(seq 1 30); do
  STATUS=$(kubectl get kustomization infrastructure \
    -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$STATUS" == "True" ]]; then
    log_ok "Infrastructure Kustomization is Ready"
    break
  fi
  log_info "Waiting... attempt $i/30 (status: ${STATUS:-Pending})"
  sleep 20
done

[[ "$STATUS" != "True" ]] && {
  log_error "Infrastructure Kustomization did not become Ready in time."
  log_error "Check: flux get kustomizations && kubectl get helmreleases -A"
  exit 1
}

# ── 2. Wait for Sealed Secrets controller pod ───────────────
log_step "Waiting for Sealed Secrets controller to be Ready"
wait_for_pods "flux-system" "app.kubernetes.io/name=sealed-secrets" 180

# ── 3. Create temp directory for plain secrets ──────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log_step "Generating plain-text Kubernetes Secrets (in temp dir, never committed)"

# Secret 1: PostgreSQL credentials
cat > "$TMPDIR/db-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-db-credentials
  namespace: mattermost
type: Opaque
stringData:
  DB_CONNECTION_STRING: "postgres://mmuser:${DB_PASSWORD}@mattermost-db-postgresql.mattermost.svc.cluster.local:5432/mattermost?sslmode=disable"
  POSTGRES_PASSWORD: "${DB_PASSWORD}"
EOF

# Secret 2: PostgreSQL auth (for the Bitnami Helm chart)
cat > "$TMPDIR/postgres-auth.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-db-postgresql
  namespace: mattermost
type: Opaque
stringData:
  postgres-password: "${DB_PASSWORD}"
  password: "${DB_PASSWORD}"
EOF

log_ok "Plain secrets generated in temp dir"

# ── 4. Fetch Sealed Secrets public cert ─────────────────────
log_step "Fetching Sealed Secrets public certificate"
CERT_FILE="$TMPDIR/sealed-secrets.pem"

kubeseal \
  --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=flux-system \
  > "$CERT_FILE"

log_ok "Certificate fetched: $CERT_FILE"

# ── 5. Seal the secrets ─────────────────────────────────────
SECRETS_DIR="$ROOT_DIR/apps/mattermost/secrets"
mkdir -p "$SECRETS_DIR"

log_step "Sealing secrets → $SECRETS_DIR"

kubeseal \
  --format yaml \
  --cert "$CERT_FILE" \
  < "$TMPDIR/db-credentials.yaml" \
  > "$SECRETS_DIR/sealed-db-credentials.yaml"

log_ok "sealed-db-credentials.yaml created"

kubeseal \
  --format yaml \
  --cert "$CERT_FILE" \
  < "$TMPDIR/postgres-auth.yaml" \
  > "$SECRETS_DIR/sealed-postgres-auth.yaml"

log_ok "sealed-postgres-auth.yaml created"

# ── 6. Update the kustomization to include secrets dir ──────
# (already referenced in apps/mattermost/kustomization.yaml)

# ── 7. Commit everything (apps layer + sealed secrets) ──────
log_step "Committing apps layer and sealed secrets to Git"
cd "$ROOT_DIR"

git add \
  apps/ \
  clusters/production/apps.yaml

git diff --cached --quiet && {
  log_info "Nothing new to commit"
} || {
  git commit -m "feat: add apps layer with Mattermost + sealed secrets"
  git push origin "${GITHUB_BRANCH}"
  log_ok "Apps layer committed and pushed"
}

# ── 8. Force Flux to pick up the new commit ─────────────────
log_step "Triggering Flux reconciliation"
flux reconcile source git flux-system
flux reconcile kustomization apps --with-source || true

log_section "04 Complete — Sealed Secrets deployed"
echo ""
echo "Sealed secrets are now in:"
echo "  $SECRETS_DIR/"
echo ""
echo "Next step:"
echo "  bash scripts/05-verify.sh"
echo ""
echo "Or watch deployment live:"
echo "  kubectl get pods -n mattermost --watch"
