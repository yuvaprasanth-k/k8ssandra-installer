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
#   Remove only some components:
#     sudo bash scripts/k8ssandra-cleanup.sh --scope monitoring
#     sudo bash scripts/k8ssandra-cleanup.sh --scope medusa
#     sudo bash scripts/k8ssandra-cleanup.sh --scope medusa,seaweedfs
#
#   Full teardown using the same config file as the installer
#   (reads SSH_USER, SSH_KEY, SSH_PORT):
#     sudo bash scripts/k8ssandra-cleanup.sh --scope full --config cluster.env
#
#   Full teardown with explicit SSH user/key:
#     sudo bash scripts/k8ssandra-cleanup.sh --scope full \
#       --ssh-user automaton --ssh-key /home/automaton/.ssh/id_ed25519
#
# Options:
#   --scope      (required) one of:
#                  k8ssandra   remove the whole K8ssandra stack + addons, keep Kubernetes
#                  full        tear down Kubernetes on every node
#                or one or more of these, comma-separated (e.g. medusa,seaweedfs):
#                  monitoring  Prometheus + Grafana (and the Cassandra dashboards)
#                  medusa      Medusa from the K8ssandraCluster (rolling restart of Cassandra),
#                              its schedules, jobs and credentials secret.
#                              Backup data in the bucket is NOT deleted.
#                  seaweedfs   SeaweedFS and its volume — DELETES the backups stored in it.
#                              Refused while Medusa still points at SeaweedFS (add medusa).
#   --cluster-name / --namespace   K8ssandraCluster (default cassandra-cluster / k8ssandra-operator)
#   --config     Installer config file (cluster.env); flags override it
#   --ssh-user   SSH user for worker nodes (default: ec2-user)
#   --ssh-key    Path to SSH private key (default: ssh's own defaults for root)
#   --ssh-port   SSH port (default 22)
#   --yes        Skip the confirmation prompt for --scope full
#
# For --scope full, SSH + sudo to every worker is checked BEFORE anything
# is removed, so a wrong key never leaves the cluster half-deleted.
# ============================================================

set -euo pipefail

# ── Colour helpers ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Config file first (so command-line flags can override it) ──
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  if [[ "${ARGS[$i]}" == "--config" ]]; then
    CONFIG_FILE="${ARGS[$((i + 1))]:-}"
    [[ -f "$CONFIG_FILE" ]] || error "Config file not found: ${CONFIG_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
  fi
done

# ── Parse arguments ──
SCOPE=""
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"
ASSUME_YES=false
CLUSTER_NAME="${CLUSTER_NAME:-cassandra-cluster}"
NAMESPACE="${NAMESPACE:-k8ssandra-operator}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --scope)    SCOPE="$2";    shift 2 ;;
    --config)   shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY="$2";  shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2";    shift 2 ;;
    --yes|-y)   ASSUME_YES=true; shift ;;
    *) error "Unknown argument: $1" ;;
  esac
done

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 -p "$SSH_PORT")
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

[[ -z "$SCOPE" ]] && error "Missing --scope. Use: k8ssandra | full | monitoring,medusa,seaweedfs"
if [[ "$SCOPE" != "k8ssandra" && "$SCOPE" != "full" ]]; then
  for S in ${SCOPE//,/ }; do
    [[ "$S" =~ ^(monitoring|medusa|seaweedfs)$ ]] || \
      error "Unknown scope '$S'. Use k8ssandra or full alone, or any of: monitoring,medusa,seaweedfs"
  done
fi
has_scope() { [[ ",${SCOPE}," == *",$1,"* ]]; }

# ── Must run as root ──
[[ "$EUID" -ne 0 ]] && error "Please run with sudo or as root."

# ── Ensure kubectl, helm, and other tools are on PATH ──
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"
export KUBECONFIG=/etc/kubernetes/admin.conf

# ── Full teardown: prove SSH + sudo to every worker before touching anything ──
if [[ "$SCOPE" == "full" ]]; then
  [[ -z "$SSH_KEY" || -r "$SSH_KEY" ]] || error "SSH key not readable: ${SSH_KEY}"
  mapfile -t PRE_IPS < <(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)
  if [[ ${#PRE_IPS[@]} -gt 0 ]]; then
    info "Checking SSH to ${#PRE_IPS[@]} worker(s) as '${SSH_USER}'${SSH_KEY:+ with key ${SSH_KEY}}..."
    SSH_FAILED=0
    for IP in "${PRE_IPS[@]}"; do
      if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" 'sudo -n true' > /dev/null 2>&1; then
        success "  ${IP}: SSH + sudo OK"
      else
        warn "  ${IP}: SSH or passwordless sudo FAILED"
        SSH_FAILED=1
      fi
    done
    if [[ "$SSH_FAILED" -ne 0 ]]; then
      error "Nothing was removed. Pass the right user/key, e.g. --config cluster.env, or --ssh-user automaton --ssh-key /home/automaton/.ssh/id_ed25519"
    fi
  fi
fi

if [[ "$SCOPE" == "full" && "$ASSUME_YES" != "true" ]]; then
  echo -e "${RED}This DESTROYS the whole cluster: all Cassandra data and Kubernetes on every node.${NC}"
  read -rp "Type 'destroy' to continue: " CONFIRM
  [[ "$CONFIRM" == "destroy" ]] || error "Aborted."
fi

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

  # ── Remove SeaweedFS (addon) — deletes its PVC, i.e. the stored backups ──
  if helm status seaweedfs -n seaweedfs &>/dev/null; then
    info "Uninstalling SeaweedFS (backup storage)..."
    helm uninstall seaweedfs -n seaweedfs > /dev/null 2>&1 || true
    kubectl delete namespace seaweedfs --ignore-not-found --timeout=120s || true
    success "SeaweedFS removed."
  fi
  helm repo remove seaweedfs 2>/dev/null || true

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
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
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
  ssh "${SSH_OPTS[@]}" \
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
rm -rf /root/.kube /home/*/.kube 2>/dev/null || true

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
  rm -rf /root/.kube /home/*/.kube 2>/dev/null || true

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
    info "Resetting ${#WORKER_NAMES[@]} worker(s) via SSH (user: ${SSH_USER}, key: ${SSH_KEY:-ssh default})..."
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

# ════════════════════════════════════════════════════════════
# COMPONENT SCOPES — monitoring, medusa, seaweedfs
# ════════════════════════════════════════════════════════════
cleanup_monitoring() {
  info "Removing Prometheus + Grafana..."
  if helm status prometheus-grafana -n "$NAMESPACE" &>/dev/null; then
    helm uninstall prometheus-grafana -n "$NAMESPACE" > /dev/null
    success "Helm release prometheus-grafana removed."
  else
    warn "prometheus-grafana is not installed — skipping."
  fi
  kubectl delete configmap -n "$NAMESPACE" -l grafana_dashboard=1 --ignore-not-found > /dev/null || true
  kubectl delete secret prometheus-grafana -n "$NAMESPACE" --ignore-not-found > /dev/null || true
  helm repo remove prometheus-community &>/dev/null || true
  success "Monitoring removed. (Prometheus CRDs are left in place; Cassandra keeps running.)"
}

medusa_configured() {
  kubectl get k8ssandracluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.medusa}' 2>/dev/null | grep -q .
}

cleanup_medusa() {
  info "Removing Medusa from K8ssandraCluster '${CLUSTER_NAME}'..."
  kubectl delete medusabackupschedule --all -n "$NAMESPACE" --ignore-not-found > /dev/null 2>&1 || true
  success "Backup schedules removed."
  if medusa_configured; then
    kubectl patch k8ssandracluster "$CLUSTER_NAME" -n "$NAMESPACE" --type=json \
      -p '[{"op": "remove", "path": "/spec/medusa"}]' > /dev/null
    success "Medusa removed from the cluster spec — Cassandra pods now restart one at a time without it."
  else
    warn "Medusa is not configured on ${CLUSTER_NAME} — nothing to patch."
  fi
  kubectl delete medusabackupjob --all -n "$NAMESPACE" --ignore-not-found > /dev/null 2>&1 || true
  kubectl delete secret medusa-bucket-key -n "$NAMESPACE" --ignore-not-found > /dev/null || true
  info "Backup data in the bucket was NOT deleted. MedusaBackup records are kept: kubectl get medusabackup -n ${NAMESPACE}"
  info "Watch the restart: kubectl get pods -n ${NAMESPACE} -w   (pods go back to 2/2)"
}

cleanup_seaweedfs() {
  if medusa_configured && kubectl get k8ssandracluster "$CLUSTER_NAME" -n "$NAMESPACE" \
       -o jsonpath='{.spec.medusa.storageProperties.host}' 2>/dev/null | grep -q seaweedfs; then
    error "Medusa still uses SeaweedFS for backups. Remove both together: --scope medusa,seaweedfs"
  fi
  if ! helm status seaweedfs -n seaweedfs &>/dev/null && ! kubectl get namespace seaweedfs &>/dev/null; then
    warn "SeaweedFS is not installed — skipping."
    return 0
  fi
  if [[ "$ASSUME_YES" != "true" ]]; then
    echo -e "${RED}This deletes SeaweedFS and ALL backups stored in it.${NC}"
    read -rp "Type 'delete' to continue: " CONFIRM
    [[ "$CONFIRM" == "delete" ]] || error "Aborted — SeaweedFS left in place."
  fi
  info "Removing SeaweedFS..."
  helm uninstall seaweedfs -n seaweedfs > /dev/null 2>&1 || true
  kubectl delete namespace seaweedfs --ignore-not-found --timeout=180s > /dev/null || true
  helm repo remove seaweedfs &>/dev/null || true
  success "SeaweedFS and its volume removed."
}

# ── Run ──
if [[ "$SCOPE" == "k8ssandra" ]]; then
  cleanup_k8ssandra
elif [[ "$SCOPE" == "full" ]]; then
  cleanup_full
else
  # fixed order: monitoring, then medusa (so it stops using the storage), then seaweedfs
  if has_scope monitoring; then cleanup_monitoring; fi
  if has_scope medusa;     then cleanup_medusa; fi
  if has_scope seaweedfs;  then cleanup_seaweedfs; fi
  echo ""
  success "Cleanup of '${SCOPE}' finished. Kubernetes and Cassandra are still running."
fi
