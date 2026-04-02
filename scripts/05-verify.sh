#!/usr/bin/env bash
# scripts/05-verify.sh
# Checks the health of all Flux resources and Mattermost pods
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "05 — Deployment Verification"

require_tool kubectl
require_tool flux

# ── 1. Flux Kustomizations ───────────────────────────────────
log_step "Flux Kustomizations"
flux get kustomizations -A

# ── 2. HelmReleases ─────────────────────────────────────────
log_step "Flux HelmReleases"
flux get helmreleases -A

# ── 3. Namespace pods ────────────────────────────────────────
log_step "Pods — mattermost namespace"
kubectl get pods -n mattermost -o wide 2>/dev/null || echo "(namespace not yet created)"

log_step "Pods — mattermost-operator namespace"
kubectl get pods -n mattermost-operator -o wide 2>/dev/null || echo "(namespace not yet created)"

log_step "Pods — metallb-system namespace"
kubectl get pods -n metallb-system -o wide 2>/dev/null || echo "(namespace not yet created)"

log_step "Pods — ingress-nginx namespace"
kubectl get pods -n ingress-nginx -o wide 2>/dev/null || echo "(namespace not yet created)"

# ── 4. Mattermost CR ────────────────────────────────────────
log_step "Mattermost Custom Resource"
kubectl get mattermost -n mattermost 2>/dev/null || echo "(Mattermost CR not yet created)"

# ── 5. Ingress ───────────────────────────────────────────────
log_step "Ingress Resources"
kubectl get ingress -A 2>/dev/null

# ── 6. Certificates ─────────────────────────────────────────
log_step "TLS Certificates (cert-manager)"
kubectl get certificates -A 2>/dev/null || echo "(no certificates found yet)"
kubectl get certificaterequests -A 2>/dev/null | head -5

# ── 7. Summary ───────────────────────────────────────────────
log_section "Access Summary"

INGRESS_IP=$(kubectl get svc \
  -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

echo ""
echo "  Mattermost URL  : https://${DOMAIN}"
echo "  Ingress LB IP   : ${INGRESS_IP}"
echo ""
echo "If INGRESS_IP shows 'pending', MetalLB may still be assigning."
echo "Check: kubectl get svc -n ingress-nginx"
echo ""
echo "DNS: Ensure an A record for ${DOMAIN} points to ${SERVER_IP}"
echo ""
echo "For kind local access (no real domain):"
echo "  Add to /etc/hosts:  ${INGRESS_IP}  ${DOMAIN}"
