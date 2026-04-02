#!/usr/bin/env bash
# scripts/02a-create-cluster-kind.sh
# Creates a kind cluster for LOCAL DEV/TESTING.
# For real on-prem server: run 02b-setup-kubeadm.sh instead.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "02a — Create kind Cluster (Local Dev)"

require_tool kind
require_tool kubectl

CLUSTER_CONFIG="$ROOT_DIR/kind/kind-cluster.yaml"

# Update cluster name in kind config to match .env
log_step "Patching kind cluster name to: $CLUSTER_NAME"
sed -i.bak "s/^name:.*/name: ${CLUSTER_NAME}/" "$CLUSTER_CONFIG"
rm -f "${CLUSTER_CONFIG}.bak"

# Delete existing cluster if present
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  log_warn "Existing kind cluster '${CLUSTER_NAME}' found."
  read -r -p "Delete and recreate? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    kind delete cluster --name "$CLUSTER_NAME"
    log_ok "Old cluster deleted"
  else
    log_info "Keeping existing cluster. Skipping creation."
    exit 0
  fi
fi

log_step "Creating kind cluster: $CLUSTER_NAME"
kind create cluster \
  --name "$CLUSTER_NAME" \
  --config "$CLUSTER_CONFIG" \
  --wait 120s

log_ok "Cluster created"

# Set kubectl context
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
log_ok "kubectl context: kind-${CLUSTER_NAME}"

# Detect Docker bridge subnet for MetalLB
log_step "Detecting Docker network subnet for MetalLB"
DOCKER_SUBNET=$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | head -1)

if [[ -z "$DOCKER_SUBNET" ]]; then
  log_warn "Could not detect Docker subnet. Using default 172.18.0.200-172.18.0.250"
  METALLB_IP_RANGE="172.18.0.200-172.18.0.250"
else
  # Use the upper end of the subnet for MetalLB
  BASE=$(echo "$DOCKER_SUBNET" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
  METALLB_IP_RANGE="${BASE}.200-${BASE}.250"
fi

log_ok "MetalLB will use IP range: $METALLB_IP_RANGE"

# Write detected range to .env (append if not present)
if grep -q "^METALLB_IP_RANGE=" "$ROOT_DIR/.env" 2>/dev/null; then
  sed -i.bak "s|^METALLB_IP_RANGE=.*|METALLB_IP_RANGE=${METALLB_IP_RANGE}|" "$ROOT_DIR/.env"
  rm -f "$ROOT_DIR/.env.bak"
else
  echo "METALLB_IP_RANGE=${METALLB_IP_RANGE}" >> "$ROOT_DIR/.env"
fi

log_ok "METALLB_IP_RANGE=${METALLB_IP_RANGE} written to .env"
log_ok "kind cluster ready. Proceed with: scripts/03-bootstrap-flux.sh"
