#!/usr/bin/env bash
# bootstrap.sh — Master Automation Script
# =========================================
# Run this ONE script to go from zero to a fully deployed Mattermost instance.
#
# Usage:
#   cp .env.example .env
#   nano .env              # fill in your values
#   bash bootstrap.sh
#
# What it does (in order):
#   1. Validates .env
#   2. Installs missing tools (kubectl, helm, flux, kubeseal, kind)
#   3. Creates Kubernetes cluster (kind OR kubeadm, based on CLUSTER_TYPE in .env)
#   4. Bootstraps FluxCD onto the cluster and pushes infrastructure layer to GitHub
#   5. Waits for infrastructure (sealed-secrets, metallb, nginx, cert-manager, operator)
#   6. Seals secrets and pushes apps layer (Mattermost + PostgreSQL)
#   7. Prints access instructions
# =========================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colour helpers (inline — no lib/ dependency yet) ────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}  $*${NC}\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Banner ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │         Mattermost GitOps Bootstrap                 │"
echo "  │         Kind / kubeadm + FluxCD + Sealed Secrets    │"
echo "  └─────────────────────────────────────────────────────┘"
echo -e "${NC}"

# ── Validate .env exists ─────────────────────────────────────
if [[ ! -f ".env" ]]; then
  log_error ".env file not found!"
  echo ""
  echo "  1. Copy the template:   cp .env.example .env"
  echo "  2. Fill in your values: nano .env"
  echo "  3. Re-run:              bash bootstrap.sh"
  exit 1
fi

source ".env"
log_ok ".env loaded (DOMAIN=${DOMAIN}, CLUSTER_TYPE=${CLUSTER_TYPE})"

# ── Make all scripts executable ─────────────────────────────
chmod +x scripts/*.sh scripts/lib/*.sh

# ── Step 1: Install tools ────────────────────────────────────
log_section "Step 1/6 — Install Tools"
bash scripts/01-install-tools.sh

# ── Step 2: Create cluster ───────────────────────────────────
log_section "Step 2/6 — Create Kubernetes Cluster"

case "${CLUSTER_TYPE:-kubeadm}" in
  kind)
    log_info "CLUSTER_TYPE=kind → creating local kind cluster"
    bash scripts/02a-create-cluster-kind.sh
    ;;
  kubeadm)
    log_info "CLUSTER_TYPE=kubeadm → assuming cluster already initialised"
    log_info "If you haven't run kubeadm yet, run: sudo bash scripts/02b-setup-kubeadm.sh"
    log_info "Then re-run: bash bootstrap.sh"
    # Validate we can reach the cluster
    kubectl cluster-info > /dev/null 2>&1 || {
      log_error "Cannot reach cluster. Run kubeadm setup first."
      exit 1
    }
    log_ok "Existing kubeadm cluster detected"
    ;;
  *)
    log_error "Unknown CLUSTER_TYPE='${CLUSTER_TYPE}'. Use 'kind' or 'kubeadm'."
    exit 1
    ;;
esac

# ── Step 3: Bootstrap Flux ───────────────────────────────────
log_section "Step 3/6 — Bootstrap FluxCD"
bash scripts/03-bootstrap-flux.sh

# ── Step 4: Wait for infra + seal secrets ───────────────────
log_section "Step 4/6 — Wait for Infrastructure & Seal Secrets"
bash scripts/04-wait-and-seal.sh

# ── Step 5: Verify ───────────────────────────────────────────
log_section "Step 5/6 — Verify Deployment"
bash scripts/05-verify.sh

# ── Step 6: Access instructions ─────────────────────────────
log_section "Step 6/6 — Access Instructions"
source ".env"   # reload in case METALLB_IP_RANGE was updated

echo ""
echo -e "${BOLD}  Mattermost is deploying at: https://${DOMAIN}${NC}"
echo ""
echo "  It can take 3–5 minutes for all pods to start and TLS cert to issue."
echo ""
echo -e "${BOLD}  DNS Setup Required:${NC}"
echo "    Create an A record:  ${DOMAIN}  →  ${SERVER_IP}"
echo "    (at your DNS provider — Namecheap, Cloudflare, etc.)"
echo ""
echo -e "${BOLD}  For kind local dev (no real DNS):${NC}"
echo "    Add to /etc/hosts:   127.0.0.1  ${DOMAIN}"
echo "    Then access via:     http://${DOMAIN}  (HTTP only without real cert)"
echo ""
echo -e "${BOLD}  Watch deployment live:${NC}"
echo "    kubectl get pods -n mattermost --watch"
echo "    flux get all -A"
echo ""
echo -e "${GREEN}${BOLD}  Bootstrap complete! 🎉${NC}"
echo ""
