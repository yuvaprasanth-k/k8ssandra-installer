#!/bin/bash
# ============================================================
# k8ssandra-cleanup.sh
# Removes K8ssandra, cert-manager, local-path-provisioner,
# and optionally the full Kubernetes cluster from all nodes.
# Worker nodes are reset automatically over SSH from the
# control plane — no manual steps on workers required.
#
# Usage:
#   K8ssandra resources only (keep Kubernetes):
#     sudo bash scripts/k8ssandra-cleanup.sh --scope k8ssandra
#
#   Full teardown — all nodes automatically:
#     sudo bash scripts/k8ssandra-cleanup.sh --scope full
#
#   Full teardown with custom SSH user/key:
#     sudo bash scripts/k8ssandra-cleanup.sh --scope full \
#       --ssh-user ubuntu --ssh-key /root/.ssh/my-key.pem
#
# Options:
#   --scope      k8ssandra | full  (required)
#   --ssh-user   SSH user for worker nodes (default: ec2-user)
#   --ssh-key    Path to SSH private key   (default: ~/.ssh/id_rsa)
# ============================================================

set -euo pipefail

# ── Colour helpers ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Parse arguments ──
SCOPE=""
SSH_USER="ec2-user"
SSH_KEY="$HOME/.ssh/id_rsa"

while [[ $# -gt 0 ]]; do
  case $1 in
    --scope)    SCOPE="$2";    shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY="$2";  shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "$SCOPE" ]] && error "Missing --scope. Use: --scope k8ssandra  OR  --scope full"
[[ "$SCOPE" != "k8ssandra" && "$SCOPE" != "full" ]] && \
  error "--scope must be 'k8ssandra' or 'full'"

# ── Must run as root ──
[[ "$EUID" -ne 0 ]] && error "Please run with sudo or as root."

# ── Ensure kubectl, helm, and other tools are on PATH ──
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"
export KUBECONFIG=/etc/kubernetes/admin.conf

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN} K8ssandra Cleanup — scope: ${SCOPE}${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# ════════════════════════════════════════════════════════════
# SCOPE: k8ssandra — remove K8ssandra stack, keep Kubernetes
# ════════════════════════════════════════════════════════════
cleanup_k8ssandra() {
  local NAMESPACE="k8ssandra-operator"

  # ── Remove Prometheus + Grafana (addon) ──
  info "Uninstalling Prometheus + Grafana (Helm)..."
  helm uninstall prometheus-grafana -n "$NAMESPACE" 2>/dev/null || \
    warn "prometheus-grafana Helm release not found — skipping."
  success "Prometheus + Grafana removed."

  # ── Remove Medusa credentials secret (addon) ──
  info "Deleting Medusa S3 credentials secret..."
  kubectl delete secret medusa-bucket-key -n "$NAMESPACE" --ignore-not-found || true
  success "Medusa secret removed."

  # ── Remove prometheus-community Helm repo ──
  helm repo remove prometheus-community 2>/dev/null || true

  # ── Delete K8ssandraCluster CR (removes Cassandra, Reaper, Medusa sidecars) ──
  info "Deleting K8ssandraCluster CR..."
  kubectl delete k8ssandracluster --all -n "$NAMESPACE" \
    --timeout=120s --ignore-not-found || true
  success "K8ssandraCluster deleted."

  # ── Uninstall K8ssandra Operator ──
  info "Uninstalling K8ssandra Operator (Helm)..."
  helm uninstall k8ssandra-operator -n "$NAMESPACE" 2>/dev/null || \
    warn "k8ssandra-operator Helm release not found — skipping."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=60s || true
  success "K8ssandra Operator removed."

  # ── Delete cert-manager ──
  info "Deleting cert-manager..."
  kubectl delete -f \
    "https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml" \
    --ignore-not-found 2>/dev/null || true
  kubectl delete namespace cert-manager --ignore-not-found --timeout=60s || true
  success "cert-manager removed."

  # ── Delete local-path-provisioner ──
  info "Deleting local-path-provisioner..."
  kubectl delete namespace local-path-storage --ignore-not-found --timeout=60s || true
  kubectl delete clusterrole local-path-provisioner-role --ignore-not-found || true
  kubectl delete clusterrolebinding local-path-provisioner-bind --ignore-not-found || true
  kubectl delete storageclass local-path --ignore-not-found || true
  success "local-path-provisioner removed."

  # ── Remove Helm repos ──
  info "Removing Helm repos..."
  helm repo remove k8ssandra 2>/dev/null || true
  success "Helm repos removed."

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} K8ssandra stack (+ addons) removed. Kubernetes is still up.${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  info "Remaining nodes:"
  kubectl get nodes -o wide
}

# ════════════════════════════════════════════════════════════
# Reset a worker node over SSH, then delete it from cluster
# ════════════════════════════════════════════════════════════
reset_worker_via_ssh() {
  local NODE_NAME="$1"
  local NODE_IP="$2"

  info "Draining worker '${NODE_NAME}' (${NODE_IP})..."
  kubectl drain "${NODE_NAME}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=120s 2>/dev/null || \
    warn "Drain had warnings — continuing."
  success "Node '${NODE_NAME}' drained."

  info "Resetting worker '${NODE_NAME}' via SSH..."
  ssh -i "${SSH_KEY}" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      -o ConnectTimeout=15 \
      "${SSH_USER}@${NODE_IP}" \
      "sudo bash -s" <<'REMOTE'
set -e
echo "[WORKER] Running kubeadm reset..."
kubeadm reset -f || true

echo "[WORKER] Cleaning CNI and iptables..."
rm -rf /etc/cni/net.d
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true
ipvsadm --clear 2>/dev/null || true

echo "[WORKER] Removing kubeconfig..."
rm -rf /root/.kube /home/ec2-user/.kube /home/ubuntu/.kube 2>/dev/null || true

echo "[WORKER] Detecting OS..."
if [[ -f /etc/os-release ]]; then . /etc/os-release; OS=$ID; fi

echo "[WORKER] Removing Kubernetes packages..."
if [[ "$OS" == "amzn" ]]; then
  yum remove -y kubelet kubeadm kubectl --disableexcludes=kubernetes 2>/dev/null || true
elif [[ "$OS" == "ubuntu" ]]; then
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  apt-get remove -y kubelet kubeadm kubectl 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
fi

echo "[WORKER] Stopping and removing containerd..."
systemctl stop containerd 2>/dev/null || true
systemctl disable containerd 2>/dev/null || true
if [[ "$OS" == "amzn" ]]; then
  yum remove -y containerd 2>/dev/null || true
elif [[ "$OS" == "ubuntu" ]]; then
  apt-get remove -y containerd.io 2>/dev/null || true
fi
rm -rf /etc/containerd

echo "[WORKER] Removing local storage data..."
rm -rf /opt/local-path-provisioner

echo "[WORKER] Reset complete."
REMOTE

  info "Deleting node '${NODE_NAME}' from cluster..."
  kubectl delete node "${NODE_NAME}" --ignore-not-found
  success "Worker '${NODE_NAME}' fully reset and removed from cluster."
}

# ════════════════════════════════════════════════════════════
# Reset this control plane node locally
# ════════════════════════════════════════════════════════════
reset_control_plane_locally() {
  info "Resetting control plane node ($(hostname))..."

  if [[ -f /etc/os-release ]]; then . /etc/os-release; OS=$ID; fi

  kubeadm reset -f || true
  rm -rf /etc/cni/net.d
  iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true
  ipvsadm --clear 2>/dev/null || true
  rm -rf /root/.kube /home/ec2-user/.kube /home/ubuntu/.kube 2>/dev/null || true

  if [[ "$OS" == "amzn" ]]; then
    yum remove -y kubelet kubeadm kubectl --disableexcludes=kubernetes 2>/dev/null || true
  elif [[ "$OS" == "ubuntu" ]]; then
    apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    apt-get remove -y kubelet kubeadm kubectl 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
  fi

  systemctl stop containerd || true
  systemctl disable containerd || true
  if [[ "$OS" == "amzn" ]]; then
    yum remove -y containerd 2>/dev/null || true
  elif [[ "$OS" == "ubuntu" ]]; then
    apt-get remove -y containerd.io 2>/dev/null || true
  fi
  rm -rf /etc/containerd /opt/local-path-provisioner

  success "Control plane node reset complete."
}

# ════════════════════════════════════════════════════════════
# SCOPE: full — automated teardown of entire cluster
# ════════════════════════════════════════════════════════════
cleanup_full() {
  # ── Step 1: Remove K8ssandra stack ──
  cleanup_k8ssandra

  # ── Step 2: Collect worker node names + IPs before kubectl is gone ──
  info "Collecting worker node information..."
  mapfile -t WORKER_NAMES < <(kubectl get nodes --no-headers \
    --selector='!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  declare -A WORKER_IPS
  for NODE in "${WORKER_NAMES[@]:-}"; do
    [[ -z "$NODE" ]] && continue
    IP=$(kubectl get node "${NODE}" \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    WORKER_IPS["$NODE"]="$IP"
    info "  Found worker: ${NODE} → ${IP}"
  done

  # ── Step 3: Reset each worker via SSH ──
  if [[ ${#WORKER_NAMES[@]} -eq 0 ]]; then
    warn "No worker nodes found — skipping worker reset."
  else
    info "Resetting ${#WORKER_NAMES[@]} worker(s) via SSH (user: ${SSH_USER}, key: ${SSH_KEY})..."
    for NODE in "${WORKER_NAMES[@]}"; do
      [[ -z "$NODE" ]] && continue
      reset_worker_via_ssh "$NODE" "${WORKER_IPS[$NODE]}"
    done
    success "All worker nodes reset."
  fi

  # ── Step 4: Reset the control plane ──
  reset_control_plane_locally

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} Full cluster teardown complete. All nodes are clean.${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ── Run ──
if [[ "$SCOPE" == "k8ssandra" ]]; then
  cleanup_k8ssandra
elif [[ "$SCOPE" == "full" ]]; then
  cleanup_full
fi
