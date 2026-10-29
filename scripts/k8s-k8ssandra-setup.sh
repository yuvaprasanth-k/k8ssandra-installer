#!/usr/bin/env bash
# ==============================================================================
# k8s-k8ssandra-setup.sh  (v2.0.0)
#
# End-to-end installer: Kubernetes (kubeadm) + K8ssandra + Apache Cassandra on
# EC2 or any Linux VMs — or K8ssandra only on an EXISTING Kubernetes cluster.
#
# ONE COMMAND, FULLY AUTOMATED (run on the control-plane node):
#
#   sudo bash k8s-k8ssandra-setup.sh --role all \
#     --workers 10.0.1.11,10.0.1.12,10.0.1.13 \
#     --ssh-user ec2-user --ssh-key /home/ec2-user/.ssh/cluster-key.pem
#
#   This prepares the control plane, initialises Kubernetes, installs the CNI,
#   joins every worker over SSH (in parallel), waits for all nodes to be Ready,
#   installs storage + cert-manager + K8ssandra Operator, deploys Cassandra,
#   waits for the datacenter to be Ready, and (optionally) installs addons.
#
# ROLES
#   all            Control plane + auto-join workers + K8ssandra (+ addons)
#   control-plane  Control plane only (+ auto-join workers if --workers given)
#   add-workers    Join more workers to an existing cluster (run on control plane)
#   worker         Join THIS node (manual mode, needs --join-command)
#   k8ssandra      K8ssandra + Cassandra only, on any existing cluster
#                  (kubeadm, EKS, ...; uses --kubeconfig / $KUBECONFIG)
#
# CONFIGURATION
#   Every option can be set three ways (highest priority first):
#     1. command-line flag            --dc-size 6
#     2. config file                  --config cluster.env   (DC_SIZE=6)
#     3. environment variable         DC_SIZE=6 sudo -E bash ...
#   See config/cluster.env.example for every setting with comments.
#   Run with --help for the full flag list, --print-config to see the effective
#   settings, and --render-only to print the K8ssandraCluster YAML without
#   installing anything.
# ==============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ── Colour / log helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi
ts()      { date '+%H:%M:%S'; }
info()    { echo -e "${CYAN}[$(ts) INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[$(ts) OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[$(ts) WARN]${NC}  $*" >&2; }
error()   { echo -e "${RED}[$(ts) ERROR]${NC} $*" >&2; exit 1; }
header()  {
  echo -e "\n${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN} $*${NC}"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
}
on_error() {
  local rc=$? line=$1 cmd=$2
  echo -e "${RED}[$(ts) FAILED]${NC} line ${line}: ${cmd} (exit ${rc})" >&2
  [[ -n "${LOG_FILE:-}" ]] && echo -e "${RED}           Full log: ${LOG_FILE}${NC}" >&2
  exit "$rc"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

usage() {
  cat <<'EOF'
Usage: k8s-k8ssandra-setup.sh --role <role> [options]

Roles:
  all | control-plane | add-workers | worker | k8ssandra   (see header of script)

General:
  --config FILE                 Load settings from an env file (KEY=value lines)
  --yes                         Don't ask for confirmation
  --print-config                Print effective settings and exit
  --render-only                 Print the K8ssandraCluster manifest and exit
  --log-file FILE               Log file (default /var/log/k8ssandra-setup.log)
  -h, --help                    Show this help

Nodes / SSH (roles all, control-plane, add-workers):
  --workers "IP1,IP2,..."       Worker private IPs/hostnames to join over SSH
  --ssh-user USER               SSH user on workers (default ec2-user)
  --ssh-key FILE                SSH private key (default: ssh's own defaults)
  --ssh-port PORT               SSH port (default 22)
  --worker-ready-timeout SEC    Wait for workers to be Ready (default 900)
  --join-command "CMD"          (role worker) the 'kubeadm join ...' command

Kubernetes:
  --k8s-version X.Y             Kubernetes minor version (default 1.36)
  --pod-cidr CIDR               Pod network (default 192.168.0.0/16)
  --service-cidr CIDR           Service network (default 10.96.0.0/12)
  --advertise-address IP        API server address (default: node private IP)
  --control-plane-endpoint EP   DNS/IP:port for the API (e.g. an NLB), optional
  --schedule-on-control-plane   Allow Cassandra pods on the control plane
  --kubeconfig FILE             (role k8ssandra) kubeconfig of existing cluster
  --cni calico|custom|none      CNI to install (default calico)
  --cni-manifest FILE|URL       Manifest applied when --cni custom
  --calico-version vX.Y.Z       (default v3.33.0)
  --calico-encap VXLAN|IPIP     Overlay mode (default VXLAN, needs UDP 4789)

Storage:
  --storage-class NAME          local-path | ebs-gp3 | <existing class> (default local-path)
  --storage-size SIZE           Per-node data volume (default 20Gi)
  --local-path-dir DIR          Host dir for local-path (default /opt/local-path-provisioner)
  --local-path-version vX       (default v0.0.37)
  --ebs-csi-version VER         aws-ebs-csi-driver chart version (default: latest)

K8ssandra stack:
  --helm-version vX.Y.Z         Helm to install if missing (default v3.22.1)
  --cert-manager-version vX     (default v1.21.3; skipped if already installed)
  --operator-version X.Y.Z      k8ssandra-operator chart version (default 1.33.0, "" = latest)
  --namespace NS                Operator/cluster namespace (default k8ssandra-operator)
  --cluster-scoped              Install operator in cluster-scoped mode

Cassandra:
  --cluster-name NAME           K8ssandraCluster name (default cassandra-cluster)
  --cassandra-version X.Y.Z     (default 4.1.8; 5.0.x also supported)
  --cassandra-image IMAGE       Override server image (optional)
  --dc-name NAME                (default dc1)
  --dc-size N                   Cassandra nodes in the DC (default 3)
  --heap-size SIZE              JVM heap (default 2048M)
  --cpu N / --memory SIZE       Pod requests (memory also set as limit), e.g. 2 / 8Gi
  --racks none|zone|a,b,c       Rack layout: none, one rack per AZ (auto), or list of AZs
  --soft-anti-affinity          Allow >1 Cassandra pod per node (needs --cpu/--memory)
  --cluster-manifest FILE       Apply YOUR K8ssandraCluster YAML instead of the generated one
  --skip-cluster                Install the operator but don't create a cluster
  --cluster-ready-timeout SEC   Wait for the DC to be Ready (default 1800, 0 = don't wait)

Addons (run after the cluster is Ready):
  --addons LIST                 Comma list: monitoring,reaper,medusa
  Medusa settings come from the config file / environment (never the command
  line): MEDUSA_BUCKET, MEDUSA_REGION, MEDUSA_CREDENTIALS_TYPE,
  MEDUSA_ACCESS_KEY, MEDUSA_SECRET_KEY.
EOF
}

# ── Pass 1: find --config / --help before anything else ──────────────────────
CONFIG_FILE=""
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  case "${ARGS[$i]}" in
    --config) CONFIG_FILE="${ARGS[$((i + 1))]:-}" ;;
    -h|--help) usage; exit 0 ;;
  esac
done
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || error "Config file not found: $CONFIG_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

# ── Pass 2: command-line flags (override config file + environment) ──────────
need_val() { [[ $# -ge 2 && -n "${2:-}" && "${2:0:2}" != "--" ]] || error "Option $1 needs a value."; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)                    shift 2 ;;
    --role)                      need_val "$@"; ROLE="$2"; shift 2 ;;
    --yes|-y)                    ASSUME_YES=true; shift ;;
    --print-config)              PRINT_CONFIG=true; shift ;;
    --render-only)               RENDER_ONLY=true; shift ;;
    --log-file)                  need_val "$@"; LOG_FILE="$2"; shift 2 ;;
    --workers)                   need_val "$@"; WORKERS="$2"; shift 2 ;;
    --ssh-user)                  need_val "$@"; SSH_USER="$2"; shift 2 ;;
    --ssh-key)                   need_val "$@"; SSH_KEY="$2"; shift 2 ;;
    --ssh-port)                  need_val "$@"; SSH_PORT="$2"; shift 2 ;;
    --worker-ready-timeout)      need_val "$@"; WORKER_READY_TIMEOUT="$2"; shift 2 ;;
    --join-command)              need_val "$@"; JOIN_COMMAND="$2"; shift 2 ;;
    --k8s-version)               need_val "$@"; K8S_VERSION="$2"; shift 2 ;;
    --pod-cidr)                  need_val "$@"; POD_CIDR="$2"; shift 2 ;;
    --service-cidr)              need_val "$@"; SERVICE_CIDR="$2"; shift 2 ;;
    --advertise-address)         need_val "$@"; ADVERTISE_ADDRESS="$2"; shift 2 ;;
    --control-plane-endpoint)    need_val "$@"; CONTROL_PLANE_ENDPOINT="$2"; shift 2 ;;
    --schedule-on-control-plane) SCHEDULE_ON_CONTROL_PLANE=true; shift ;;
    --kubeconfig)                need_val "$@"; KUBECONFIG_PATH="$2"; shift 2 ;;
    --cni)                       need_val "$@"; CNI="$2"; shift 2 ;;
    --cni-manifest)              need_val "$@"; CNI_MANIFEST="$2"; shift 2 ;;
    --calico-version)            need_val "$@"; CALICO_VERSION="$2"; shift 2 ;;
    --calico-encap)              need_val "$@"; CALICO_ENCAP="$2"; shift 2 ;;
    --storage-class)             need_val "$@"; STORAGE_CLASS="$2"; shift 2 ;;
    --storage-size)              need_val "$@"; STORAGE_SIZE="$2"; shift 2 ;;
    --local-path-dir)            need_val "$@"; LOCAL_PATH_DIR="$2"; shift 2 ;;
    --local-path-version)        need_val "$@"; LOCAL_PATH_VERSION="$2"; shift 2 ;;
    --ebs-csi-version)           need_val "$@"; EBS_CSI_VERSION="$2"; shift 2 ;;
    --helm-version)              need_val "$@"; HELM_VERSION="$2"; shift 2 ;;
    --cert-manager-version)      need_val "$@"; CERT_MANAGER_VERSION="$2"; shift 2 ;;
    --operator-version)          OPERATOR_VERSION="${2:-}"; shift 2 ;;
    --namespace)                 need_val "$@"; NAMESPACE="$2"; shift 2 ;;
    --cluster-scoped)            CLUSTER_SCOPED=true; shift ;;
    --cluster-name)              need_val "$@"; CLUSTER_NAME="$2"; shift 2 ;;
    --cassandra-version)         need_val "$@"; CASSANDRA_VERSION="$2"; shift 2 ;;
    --cassandra-image)           need_val "$@"; CASSANDRA_IMAGE="$2"; shift 2 ;;
    --dc-name)                   need_val "$@"; DC_NAME="$2"; shift 2 ;;
    --dc-size)                   need_val "$@"; DC_SIZE="$2"; shift 2 ;;
    --heap-size)                 need_val "$@"; HEAP_SIZE="$2"; shift 2 ;;
    --cpu)                       need_val "$@"; CASSANDRA_CPU="$2"; shift 2 ;;
    --memory)                    need_val "$@"; CASSANDRA_MEMORY="$2"; shift 2 ;;
    --racks)                     need_val "$@"; RACKS="$2"; shift 2 ;;
    --soft-anti-affinity)        SOFT_ANTI_AFFINITY=true; shift ;;
    --cluster-manifest)          need_val "$@"; CLUSTER_MANIFEST="$2"; shift 2 ;;
    --skip-cluster)              SKIP_CLUSTER=true; shift ;;
    --cluster-ready-timeout)     need_val "$@"; CLUSTER_READY_TIMEOUT="$2"; shift 2 ;;
    --addons)                    need_val "$@"; ADDONS="$2"; shift 2 ;;
    *) error "Unknown argument: $1  (see --help)" ;;
  esac
done

# ── Defaults (applied only where nothing above set a value) ──────────────────
: "${ROLE:=}"
: "${ASSUME_YES:=false}"
: "${PRINT_CONFIG:=false}"
: "${RENDER_ONLY:=false}"
: "${LOG_FILE:=/var/log/k8ssandra-setup.log}"
# nodes / ssh
: "${WORKERS:=}"
: "${SSH_USER:=ec2-user}"
: "${SSH_KEY:=}"
: "${SSH_PORT:=22}"
: "${WORKER_READY_TIMEOUT:=900}"
: "${JOIN_COMMAND:=}"
# kubernetes
: "${K8S_VERSION:=1.36}"
: "${POD_CIDR:=192.168.0.0/16}"
: "${SERVICE_CIDR:=10.96.0.0/12}"
: "${ADVERTISE_ADDRESS:=}"
: "${CONTROL_PLANE_ENDPOINT:=}"
: "${SCHEDULE_ON_CONTROL_PLANE:=false}"
: "${KUBECONFIG_PATH:=}"
: "${CNI:=calico}"
: "${CNI_MANIFEST:=}"
: "${CALICO_VERSION:=v3.33.0}"
: "${CALICO_ENCAP:=VXLAN}"
# storage
: "${STORAGE_CLASS:=local-path}"
: "${STORAGE_SIZE:=20Gi}"
: "${LOCAL_PATH_DIR:=/opt/local-path-provisioner}"
: "${LOCAL_PATH_VERSION:=v0.0.37}"
: "${EBS_CSI_VERSION:=}"
# k8ssandra stack
: "${HELM_VERSION:=v3.22.1}"
: "${CERT_MANAGER_VERSION:=v1.21.3}"
: "${OPERATOR_VERSION=1.33.0}"   # '=' not ':=' so an explicit empty value means "latest"
: "${NAMESPACE:=k8ssandra-operator}"
: "${CLUSTER_SCOPED:=false}"
# cassandra
: "${CLUSTER_NAME:=cassandra-cluster}"
: "${CASSANDRA_VERSION:=4.1.8}"
: "${CASSANDRA_IMAGE:=}"
: "${DC_NAME:=dc1}"
: "${DC_SIZE:=3}"
: "${HEAP_SIZE:=2048M}"
: "${CASSANDRA_CPU:=}"
: "${CASSANDRA_MEMORY:=}"
: "${RACKS:=none}"
: "${SOFT_ANTI_AFFINITY:=false}"
: "${CLUSTER_MANIFEST:=}"
: "${SKIP_CLUSTER:=false}"
: "${CLUSTER_READY_TIMEOUT:=1800}"
# addons
: "${ADDONS:=}"
: "${MEDUSA_BUCKET:=}"
: "${MEDUSA_REGION:=us-east-1}"
: "${MEDUSA_CREDENTIALS_TYPE:=credential-based}"
: "${MEDUSA_ACCESS_KEY:=}"
: "${MEDUSA_SECRET_KEY:=}"

WORK_DIR="/tmp/k8ssandra-setup.$$"
CRI_SOCKET="unix:///run/containerd/containerd.sock"
STORAGE_CLASS_NAME="$STORAGE_CLASS"          # real class name used in the PVC spec
[[ "$STORAGE_CLASS" == "ebs-gp3" ]] && STORAGE_CLASS_NAME="ebs-gp3"

# Split worker list on commas / spaces
WORKER_LIST=()
if [[ -n "$WORKERS" ]]; then
  read -r -a WORKER_LIST <<< "${WORKERS//,/ }"
fi

# ══════════════════════════════════════════════════════════════════════════════
# VALIDATION
# ══════════════════════════════════════════════════════════════════════════════
is_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
ip_to_int() { local IFS=.; read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
# returns 0 if two CIDRs overlap
cidr_overlap() {
  local n1=${1%/*} p1=${1#*/} n2=${2%/*} p2=${2#*/} p m
  p=$(( p1 < p2 ? p1 : p2 ))
  m=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  (( ($(ip_to_int "$n1") & m) == ($(ip_to_int "$n2") & m) ))
}

validate_config() {
  case "$ROLE" in
    all|control-plane|add-workers|worker|k8ssandra) ;;
    "") [[ "$RENDER_ONLY" == "true" || "$PRINT_CONFIG" == "true" ]] || error "Missing --role. See --help." ;;
    *) error "--role must be one of: all, control-plane, add-workers, worker, k8ssandra" ;;
  esac
  [[ "$K8S_VERSION" =~ ^1\.[0-9]+$ ]]           || error "--k8s-version must look like 1.36 (minor version only)."
  is_cidr "$POD_CIDR"                            || error "Invalid --pod-cidr: $POD_CIDR"
  is_cidr "$SERVICE_CIDR"                        || error "Invalid --service-cidr: $SERVICE_CIDR"
  if cidr_overlap "$POD_CIDR" "$SERVICE_CIDR"; then error "Pod CIDR $POD_CIDR overlaps service CIDR $SERVICE_CIDR."; fi
  [[ "$CNI" =~ ^(calico|custom|none)$ ]]         || error "--cni must be calico, custom or none."
  if [[ "$CNI" == "custom" && -z "$CNI_MANIFEST" ]]; then error "--cni custom needs --cni-manifest."; fi
  CALICO_ENCAP="${CALICO_ENCAP^^}"
  [[ "$CALICO_ENCAP" =~ ^(VXLAN|IPIP)$ ]]        || error "--calico-encap must be VXLAN or IPIP."
  [[ "$DC_SIZE" =~ ^[1-9][0-9]*$ ]]              || error "--dc-size must be a positive integer."
  [[ "$DC_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || error "--dc-name must be lowercase letters, digits and '-'."
  [[ "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || error "--cluster-name must be lowercase letters, digits and '-'."
  [[ "$WORKER_READY_TIMEOUT" =~ ^[0-9]+$ && "$CLUSTER_READY_TIMEOUT" =~ ^[0-9]+$ ]] || error "Timeouts must be numbers (seconds)."
  if [[ "$SOFT_ANTI_AFFINITY" == "true" && ( -z "$CASSANDRA_CPU" || -z "$CASSANDRA_MEMORY" ) ]]; then
    error "--soft-anti-affinity requires --cpu and --memory (K8ssandra rejects it without resources)."
  fi
  if [[ -n "$CLUSTER_MANIFEST" && ! -f "$CLUSTER_MANIFEST" ]]; then error "--cluster-manifest file not found: $CLUSTER_MANIFEST"; fi
  if [[ -n "$ADDONS" ]]; then
    local a
    for a in ${ADDONS//,/ }; do
      [[ "$a" =~ ^(monitoring|reaper|medusa)$ ]] || error "Unknown addon '$a' (use monitoring,reaper,medusa)."
    done
    if [[ ",$ADDONS," == *",medusa,"* ]]; then
      [[ -n "$MEDUSA_BUCKET" ]] || error "Addon medusa needs MEDUSA_BUCKET (set it in the config file)."
      if [[ "$MEDUSA_CREDENTIALS_TYPE" == "credential-based" && ( -z "$MEDUSA_ACCESS_KEY" || -z "$MEDUSA_SECRET_KEY" ) ]]; then
        error "Addon medusa needs MEDUSA_ACCESS_KEY / MEDUSA_SECRET_KEY, or MEDUSA_CREDENTIALS_TYPE=role-based."
      fi
    fi
  fi
  if [[ "$ROLE" == "worker" ]]; then
    [[ -n "$JOIN_COMMAND" ]] || error "Role worker needs --join-command (or JOIN_COMMAND in the config file)."
    [[ "$JOIN_COMMAND" =~ ^kubeadm\ join\ [^\ ]+:[0-9]+\  ]] || error "--join-command must start with 'kubeadm join <host>:<port> ...'"
    [[ "$JOIN_COMMAND" != *[\;\&\|\`\$\<\>]* ]] || error "--join-command contains shell metacharacters — refusing to run it."
  fi
  if [[ "$ROLE" == "add-workers" && ${#WORKER_LIST[@]} -eq 0 ]]; then error "Role add-workers needs --workers."; fi
  if [[ "$ROLE" == "all" && ${#WORKER_LIST[@]} -eq 0 && "$SCHEDULE_ON_CONTROL_PLANE" != "true" ]]; then
    error "Role all needs --workers (or --schedule-on-control-plane for a single-node lab)."
  fi
  if [[ "$ROLE" == "all" && "$SOFT_ANTI_AFFINITY" != "true" ]]; then
    local capacity=${#WORKER_LIST[@]}
    [[ "$SCHEDULE_ON_CONTROL_PLANE" == "true" ]] && capacity=$((capacity + 1))
    if (( capacity < DC_SIZE )); then
      error "DC size $DC_SIZE needs $DC_SIZE schedulable nodes (one Cassandra pod per node) but only $capacity will exist. Add workers, lower --dc-size, or use --soft-anti-affinity."
    fi
  fi
  return 0
}

print_config() {
  local mask_ak="" mask_sk=""
  [[ -n "$MEDUSA_ACCESS_KEY" ]] && mask_ak="${MEDUSA_ACCESS_KEY:0:4}****"
  [[ -n "$MEDUSA_SECRET_KEY" ]] && mask_sk="****"
  cat <<EOF
# Effective configuration (k8s-k8ssandra-setup.sh v${SCRIPT_VERSION})
ROLE=${ROLE}
WORKERS="${WORKERS}"
SSH_USER=${SSH_USER}  SSH_KEY=${SSH_KEY:-<ssh default>}  SSH_PORT=${SSH_PORT}
K8S_VERSION=${K8S_VERSION}  POD_CIDR=${POD_CIDR}  SERVICE_CIDR=${SERVICE_CIDR}
ADVERTISE_ADDRESS=${ADVERTISE_ADDRESS:-<auto>}  CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT:-<none>}
SCHEDULE_ON_CONTROL_PLANE=${SCHEDULE_ON_CONTROL_PLANE}
CNI=${CNI}  CALICO_VERSION=${CALICO_VERSION}  CALICO_ENCAP=${CALICO_ENCAP}  CNI_MANIFEST=${CNI_MANIFEST}
STORAGE_CLASS=${STORAGE_CLASS}  STORAGE_SIZE=${STORAGE_SIZE}  LOCAL_PATH_DIR=${LOCAL_PATH_DIR}  LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION}
HELM_VERSION=${HELM_VERSION}  CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION}  OPERATOR_VERSION=${OPERATOR_VERSION:-<latest>}
NAMESPACE=${NAMESPACE}  CLUSTER_SCOPED=${CLUSTER_SCOPED}
CLUSTER_NAME=${CLUSTER_NAME}  CASSANDRA_VERSION=${CASSANDRA_VERSION}  CASSANDRA_IMAGE=${CASSANDRA_IMAGE}
DC_NAME=${DC_NAME}  DC_SIZE=${DC_SIZE}  HEAP_SIZE=${HEAP_SIZE}  CPU=${CASSANDRA_CPU}  MEMORY=${CASSANDRA_MEMORY}
RACKS=${RACKS}  SOFT_ANTI_AFFINITY=${SOFT_ANTI_AFFINITY}  CLUSTER_MANIFEST=${CLUSTER_MANIFEST}  SKIP_CLUSTER=${SKIP_CLUSTER}
CLUSTER_READY_TIMEOUT=${CLUSTER_READY_TIMEOUT}  WORKER_READY_TIMEOUT=${WORKER_READY_TIMEOUT}
ADDONS=${ADDONS}
MEDUSA_BUCKET=${MEDUSA_BUCKET}  MEDUSA_REGION=${MEDUSA_REGION}  MEDUSA_CREDENTIALS_TYPE=${MEDUSA_CREDENTIALS_TYPE}
MEDUSA_ACCESS_KEY=${mask_ak}  MEDUSA_SECRET_KEY=${mask_sk}
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# GENERIC HELPERS
# ══════════════════════════════════════════════════════════════════════════════
require_root() { [[ "$EUID" -eq 0 ]] || error "This role must run as root (use sudo)."; }

# retry <attempts> <sleep-seconds> <command...>
retry() {
  local n=$1 s=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    (( i < n )) && { warn "Attempt $i/$n failed: $* — retrying in ${s}s"; sleep "$s"; }
  done
  return 1
}

# EC2 instance metadata (IMDSv2 with IMDSv1 fallback). Empty output if not on EC2.
imds() {
  local path=$1 token
  token=$(curl -sf -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
  if [[ -n "$token" ]]; then
    curl -sf -m 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null || true
  else
    curl -sf -m 2 "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null || true
  fi
}

primary_ip() {
  local ip
  ip=$(imds local-ipv4)
  [[ -z "$ip" ]] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "$ip"
}

detect_os() {
  [[ -f /etc/os-release ]] || error "Cannot detect OS (/etc/os-release missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="$ID"; OS_VERSION="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"
  case "$OS_ID" in
    amzn|rhel|rocky|almalinux|centos|fedora)
      OS_FAMILY=rpm
      PKG=$(command -v dnf || command -v yum) ;;
    ubuntu|debian)
      OS_FAMILY=deb ;;
    *) error "Unsupported OS: $OS_ID (supported: Amazon Linux 2/2023, RHEL-family, Ubuntu, Debian)." ;;
  esac
  if [[ "$OS_ID" == "ubuntu" && "${OS_VERSION%%.*}" =~ ^[0-9]+$ ]] && (( ${OS_VERSION%%.*} < 22 )); then
    warn "Ubuntu ${OS_VERSION} is out of standard support and too old for current Kubernetes — use Ubuntu 24.04 (or 22.04/26.04)."
  fi
  if [[ "$OS_ID" == "amzn" && "$OS_VERSION" == "2" ]]; then
    warn "Amazon Linux 2 reached end of support on 2026-06-30 — consider Amazon Linux 2023."
  fi
}

# Kubernetes 1.35+ refuses to run on cgroups v1 (KEP-5573). Ubuntu 20.04 and Amazon Linux 2
# boot with cgroups v1; Ubuntu 22.04+/Amazon Linux 2023 use v2.
k8s_needs_cgroup_v2() { (( ${K8S_VERSION#1.} >= 35 )); }
cgroup_v1_help() {
  cat >&2 <<EOF
  Kubernetes ${K8S_VERSION} needs cgroups v2, but $1 uses cgroups v1
  (typical of Ubuntu 20.04 and Amazon Linux 2). Fix, either:
    - Recommended: use Ubuntu 22.04/24.04 or Amazon Linux 2023 instances, or
    - Lab only:    re-run with --k8s-version 1.34 (end of life since 2026-10-27).
EOF
}
check_cgroups_local() {
  if k8s_needs_cgroup_v2 && [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" != "cgroup2fs" ]]; then
    cgroup_v1_help "this node ($(hostname))"
    error "cgroups v1 detected — stopping before anything is installed."
  fi
  return 0
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) error "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

setup_kubeconfig_env() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    export KUBECONFIG="$KUBECONFIG_PATH"
  elif [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf
    elif [[ -r "$HOME/.kube/config" ]]; then export KUBECONFIG="$HOME/.kube/config"
    fi
  fi
}

confirm() {
  [[ "$ASSUME_YES" == "true" || ! -t 0 ]] && return 0
  local ans
  read -rp "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || error "Aborted by user."
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — NODE PREPARATION (every node)
# ══════════════════════════════════════════════════════════════════════════════
phase_node_prep() {
  header "PHASE 1: Node preparation ($(hostname), ${OS_ID} ${OS_VERSION}, ${ARCH})"

  info "Disabling swap..."
  swapoff -a
  sed -i.bak -E '/^[^#].*\sswap\s/ s/^/#/' /etc/fstab
  success "Swap disabled."

  info "Loading kernel modules and sysctl settings..."
  printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
  modprobe overlay
  modprobe br_netfilter
  cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system > /dev/null
  success "Kernel settings applied."

  info "Installing containerd and Kubernetes v${K8S_VERSION} packages..."
  if [[ "$OS_FAMILY" == "rpm" ]]; then
    local p
    for p in containerd conntrack-tools socat iptables iptables-nft tar; do
      "$PKG" install -y "$p" > /dev/null 2>&1 || true
    done
    command -v containerd > /dev/null || error "containerd could not be installed from the OS repositories."
    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    "$PKG" install -y kubelet kubeadm kubectl --disableexcludes=kubernetes > /dev/null
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null
    apt-get install -y ca-certificates curl gnupg conntrack socat > /dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
      | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -y > /dev/null
    apt-mark unhold kubelet kubeadm kubectl > /dev/null 2>&1 || true
    apt-get install -y containerd.io kubelet kubeadm kubectl > /dev/null
    apt-mark hold kubelet kubeadm kubectl > /dev/null
  fi
  success "Packages installed: $(kubeadm version -o short), containerd $(containerd --version | awk '{print $3}')"

  if [[ -f /etc/kubernetes/kubelet.conf || -f /etc/kubernetes/admin.conf ]] && systemctl is-active --quiet containerd; then
    success "Node already in a cluster — leaving containerd/kubelet config untouched."
    return 0
  fi

  info "Configuring containerd (systemd cgroups, matching pause image)..."
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
    || warn "SystemdCgroup not found in containerd config — relying on kubelet's cgroup-driver detection."
  local pause
  pause=$(kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" 2>/dev/null | grep '/pause:' || true)
  if [[ -n "$pause" ]]; then
    sed -i -E "s#^([[:space:]]*)(sandbox_image|sandbox) = .*#\1\2 = \"${pause}\"#" /etc/containerd/config.toml
  fi
  systemctl daemon-reload
  systemctl enable containerd > /dev/null 2>&1
  systemctl restart containerd
  success "containerd running."

  # kubelet: pin node IP and (on EC2) self-label with zone/region so racks can map to AZs
  local node_ip zone region labels="" extra
  node_ip=$(primary_ip)
  zone=$(imds placement/availability-zone)
  region=$(imds placement/region)
  [[ -n "$zone" ]]   && labels="topology.kubernetes.io/zone=${zone}"
  [[ -n "$region" ]] && labels="${labels:+$labels,}topology.kubernetes.io/region=${region}"
  extra="--node-ip=${node_ip}${labels:+ --node-labels=${labels}}"
  if [[ "$OS_FAMILY" == "deb" ]]; then
    echo "KUBELET_EXTRA_ARGS=\"${extra}\"" > /etc/default/kubelet
  else
    echo "KUBELET_EXTRA_ARGS=\"${extra}\"" > /etc/sysconfig/kubelet
  fi
  systemctl enable kubelet > /dev/null 2>&1
  success "kubelet configured (node IP ${node_ip}${zone:+, zone ${zone}})."
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — CONTROL PLANE + CNI
# ══════════════════════════════════════════════════════════════════════════════
check_network_overlap() {
  local mac vpc_cidrs c
  mac=$(imds mac)
  [[ -z "$mac" ]] && return 0
  vpc_cidrs=$(imds "network/interfaces/macs/${mac}/vpc-ipv4-cidr-blocks")
  for c in $vpc_cidrs; do
    if cidr_overlap "$POD_CIDR" "$c"; then error "Pod CIDR $POD_CIDR overlaps the VPC CIDR $c — choose another --pod-cidr."; fi
    if cidr_overlap "$SERVICE_CIDR" "$c"; then error "Service CIDR $SERVICE_CIDR overlaps the VPC CIDR $c — choose another --service-cidr."; fi
  done
  [[ -n "$vpc_cidrs" ]] && success "Pod/service CIDRs don't overlap the VPC ($(echo "$vpc_cidrs" | tr '\n' ' '))."
  return 0
}

phase_control_plane() {
  header "PHASE 2: Control plane"
  export KUBECONFIG=/etc/kubernetes/admin.conf

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    warn "Kubernetes is already initialised on this node — skipping kubeadm init."
  else
    check_network_overlap
    local addr=${ADVERTISE_ADDRESS:-$(primary_ip)}
    [[ -n "$addr" ]] || error "Could not determine this node's IP — pass --advertise-address."
    info "Running kubeadm init (advertise ${addr}, pods ${POD_CIDR}, services ${SERVICE_CIDR})..."
    local init_args=(
      --apiserver-advertise-address="$addr"
      --pod-network-cidr="$POD_CIDR"
      --service-cidr="$SERVICE_CIDR"
      --cri-socket="$CRI_SOCKET"
    )
    [[ -n "$CONTROL_PLANE_ENDPOINT" ]] && init_args+=(--control-plane-endpoint="$CONTROL_PLANE_ENDPOINT")
    kubeadm init "${init_args[@]}" 2>&1 | tee /var/log/kubeadm-init.log
    success "kubeadm init complete."
  fi

  # kubeconfig for root and the invoking sudo user
  mkdir -p /root/.kube
  install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
  local u home
  for u in "${SUDO_USER:-}" ec2-user ubuntu; do
    [[ -z "$u" || "$u" == "root" ]] && continue
    home=$(getent passwd "$u" | cut -d: -f6 || true)
    [[ -n "$home" && -d "$home" ]] || continue
    mkdir -p "$home/.kube"
    install -m 0600 -o "$u" -g "$(id -gn "$u")" /etc/kubernetes/admin.conf "$home/.kube/config"
    chown "$u:$(id -gn "$u")" "$home/.kube"
  done
  success "kubectl configured."

  install_cni

  info "Waiting for the control-plane node to be Ready..."
  kubectl wait --for=condition=Ready "node/$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')" --timeout=300s \
    || warn "Control plane not Ready yet — check: kubectl get nodes; kubectl -n kube-system get pods"

  if [[ "$SCHEDULE_ON_CONTROL_PLANE" == "true" ]]; then
    kubectl taint nodes -l node-role.kubernetes.io/control-plane node-role.kubernetes.io/control-plane:NoSchedule- > /dev/null 2>&1 || true
    success "Control-plane taint removed (workloads may run on it)."
  fi
}

install_cni() {
  case "$CNI" in
    none)
      warn "CNI=none — install a CNI yourself; nodes stay NotReady until you do."
      return 0 ;;
    custom)
      info "Applying custom CNI manifest: ${CNI_MANIFEST}"
      kubectl apply --server-side --force-conflicts -f "$CNI_MANIFEST" > /dev/null
      success "Custom CNI applied."
      return 0 ;;
  esac

  info "Installing Calico ${CALICO_VERSION} (${CALICO_ENCAP} overlay, pod CIDR ${POD_CIDR})..."
  local f="$WORK_DIR/calico.yaml"
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o "$f"
  # Set the pod CIDR explicitly
  sed -i -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
         -e "s|#   value: \"192.168.0.0/16\"|  value: \"${POD_CIDR}\"|" "$f"
  grep -q "value: \"${POD_CIDR}\"" "$f" || warn "Could not set CALICO_IPV4POOL_CIDR in the manifest — Calico will auto-detect it."
  if [[ "$CALICO_ENCAP" == "VXLAN" ]]; then
    # Documented manifest switch from IP-in-IP/BGP to VXLAN (no BGP, only UDP 4789 between nodes)
    sed -i -e 's|calico_backend: "bird"|calico_backend: "vxlan"|' \
           -e '/name: CALICO_IPV4POOL_IPIP$/{n;s|"Always"|"Never"|}' \
           -e '/name: CALICO_IPV4POOL_VXLAN$/{n;s|"Never"|"Always"|}' \
           -e '/- --bird-live$/d' -e '/- --bird-ready$/d' "$f"
    grep -q 'calico_backend: "vxlan"' "$f" || error "Could not switch Calico to VXLAN — try --calico-encap IPIP."
  fi
  kubectl apply --server-side --force-conflicts -f "$f" > /dev/null
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s \
    || warn "calico-node not fully rolled out yet."
  success "Calico installed. Security group must allow $( [[ "$CALICO_ENCAP" == "VXLAN" ]] && echo "UDP 4789" || echo "IP protocol 4 (IP-in-IP) and TCP 179 (BGP)") between all nodes."
}

# ══════════════════════════════════════════════════════════════════════════════
# WORKER JOIN — manual (role worker) and automatic over SSH
# ══════════════════════════════════════════════════════════════════════════════
phase_worker_join() {
  header "PHASE 2: Joining cluster as worker ($(hostname))"
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    warn "This node is already part of a cluster — skipping kubeadm join."
    return 0
  fi
  local join_args
  read -r -a join_args <<< "$JOIN_COMMAND"
  kubeadm "${join_args[@]:1}" --cri-socket="$CRI_SOCKET"
  success "Worker $(hostname) joined the cluster."
}

ssh_opts() {
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
  [[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
  return 0
}

preflight_ssh() {
  ssh_opts
  [[ -z "$SSH_KEY" || -r "$SSH_KEY" ]] || error "SSH key not readable: $SSH_KEY"
  info "Checking SSH + sudo access to ${#WORKER_LIST[@]} worker(s)..."
  local w failed=0
  for w in "${WORKER_LIST[@]}"; do
    local cg
    if cg=$(ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@${w}" 'sudo -n true && stat -fc %T /sys/fs/cgroup' 2> /dev/null); then
      if k8s_needs_cgroup_v2 && [[ "$cg" != "cgroup2fs" ]]; then
        warn "  ${w}: reachable, but uses cgroups v1"
        cgroup_v1_help "worker ${w}"
        failed=1
      else
        success "  ${w}: reachable, passwordless sudo OK"
      fi
    else
      warn "  ${w}: SSH or passwordless sudo FAILED (user ${SSH_USER}, port ${SSH_PORT})"
      failed=1
    fi
  done
  (( failed == 0 )) || error "Fix the workers above (SSH key/user/port ${SSH_PORT}, sudo, or OS) and re-run."
}

node_name_for_ip() {
  kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{' '}{.status.addresses[?(@.type=='InternalIP')].address}{'\n'}{end}" \
    | awk -v ip="$1" '$2 == ip {print $1}'
}

join_one_worker() {
  local w=$1 env_file=$2 rdir="k8ssandra-setup"
  ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@${w}" "mkdir -p ~/${rdir} && chmod 700 ~/${rdir}"
  scp "${SSH_OPTS[@]}" -P "$SSH_PORT" -q "$SCRIPT_PATH" "${SSH_USER}@${w}:${rdir}/k8s-k8ssandra-setup.sh"
  scp "${SSH_OPTS[@]}" -P "$SSH_PORT" -q "$env_file"    "${SSH_USER}@${w}:${rdir}/worker.env"
  # shellcheck disable=SC2029  # ~ must expand on the remote side
  ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@${w}" \
    "sudo bash ~/${rdir}/k8s-k8ssandra-setup.sh --role worker --config ~/${rdir}/worker.env --yes; rc=\$?; rm -f ~/${rdir}/worker.env; exit \$rc"
}

join_workers() {
  [[ ${#WORKER_LIST[@]} -gt 0 ]] || return 0
  header "Joining ${#WORKER_LIST[@]} worker(s) over SSH"
  export KUBECONFIG=/etc/kubernetes/admin.conf
  ssh_opts

  local todo=() w
  for w in "${WORKER_LIST[@]}"; do
    if [[ -n "$(node_name_for_ip "$w")" ]]; then
      success "  ${w} is already in the cluster — skipping."
    else
      todo+=("$w")
    fi
  done

  if [[ ${#todo[@]} -gt 0 ]]; then
    local join_cmd env_file
    join_cmd=$(kubeadm token create --print-join-command --ttl 2h)
    env_file="$WORK_DIR/worker.env"
    (
      umask 077
      {
        printf 'K8S_VERSION=%q\n' "$K8S_VERSION"
        printf 'JOIN_COMMAND=%q\n' "$join_cmd"
        printf 'LOG_FILE=%q\n' "/var/log/k8ssandra-setup.log"
      } > "$env_file"
    )

    local pids=() logs=() i
    for w in "${todo[@]}"; do
      local log="/var/log/k8ssandra-setup-worker-${w}.log"
      info "  Starting join of ${w} (log: ${log})"
      join_one_worker "$w" "$env_file" > "$log" 2>&1 &
      pids+=("$!"); logs+=("$log")
    done
    local failed=()
    for i in "${!pids[@]}"; do
      if wait "${pids[$i]}"; then
        success "  ${todo[$i]} joined."
      else
        warn "  ${todo[$i]} FAILED — last lines of ${logs[$i]}:"
        tail -n 15 "${logs[$i]}" >&2 || true
        failed+=("${todo[$i]}")
      fi
    done
    rm -f "$env_file"
    [[ ${#failed[@]} -eq 0 ]] || error "Worker join failed for: ${failed[*]}. Fix and re-run — already-joined nodes are skipped."
  fi

  wait_for_workers
}

wait_for_workers() {
  local expected=${#WORKER_LIST[@]} deadline=$((SECONDS + WORKER_READY_TIMEOUT)) ready=0 w name
  info "Waiting up to ${WORKER_READY_TIMEOUT}s for ${expected} worker(s) to be Ready..."
  while (( SECONDS < deadline )); do
    ready=0
    for w in "${WORKER_LIST[@]}"; do
      name=$(node_name_for_ip "$w")
      [[ -z "$name" ]] && continue
      [[ "$(kubectl get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]] && ready=$((ready + 1))
    done
    (( ready >= expected )) && { success "All ${expected} worker(s) Ready."; kubectl get nodes -o wide; return 0; }
    sleep 10
  done
  kubectl get nodes -o wide >&2 || true
  error "Only ${ready}/${expected} workers Ready after ${WORKER_READY_TIMEOUT}s. Check CNI pods: kubectl -n kube-system get pods -o wide"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — K8SSANDRA STACK
# ══════════════════════════════════════════════════════════════════════════════
ensure_helm() {
  if command -v helm > /dev/null; then
    success "Helm present: $(helm version --short 2>/dev/null)"
    return 0
  fi
  [[ "$EUID" -eq 0 ]] || error "Helm is not installed and installing it needs root (or install Helm yourself)."
  detect_arch
  info "Installing Helm ${HELM_VERSION}..."
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o "$WORK_DIR/helm.tgz"
  tar -xzf "$WORK_DIR/helm.tgz" -C "$WORK_DIR"
  install -m 0755 "$WORK_DIR/linux-${ARCH}/helm" /usr/local/bin/helm
  success "Helm installed: $(helm version --short)"
}

find_repo_file() {   # tolerate renamed copies like "manifests (1)/local-path-provisioner (1).yaml"
  local dir_glob=$1 file_glob=$2 f
  for f in "$REPO_DIR"/$dir_glob/$file_glob; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 0
}

install_storage() {
  case "$STORAGE_CLASS" in
    local-path)
      info "Installing local-path-provisioner ${LOCAL_PATH_VERSION} (data in ${LOCAL_PATH_DIR} on each node)..."
      local src f="$WORK_DIR/local-path.yaml"
      src=$(find_repo_file "manifests*" "local-path-provisioner*.yaml")
      if [[ -n "$src" ]]; then
        cp "$src" "$f"
      else
        curl -fsSL "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" -o "$f"
      fi
      sed -i -E -e "s#(rancher/local-path-provisioner:)v[0-9.]+#\1${LOCAL_PATH_VERSION}#" \
                -e "s#/opt/local-path-provisioner#${LOCAL_PATH_DIR}#g" "$f"
      kubectl apply -f "$f" > /dev/null
      kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
      success "StorageClass 'local-path' ready. NOTE: data lives on node disks — losing a node loses that replica."
      ;;
    ebs-gp3)
      info "Installing AWS EBS CSI driver + encrypted gp3 StorageClass 'ebs-gp3'..."
      warn "Nodes need an IAM role with AmazonEBSCSIDriverPolicy and IMDS hop limit >= 2."
      helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver --force-update > /dev/null
      helm repo update aws-ebs-csi-driver > /dev/null
      local ver_args=()
      [[ -n "$EBS_CSI_VERSION" ]] && ver_args=(--version "$EBS_CSI_VERSION")
      helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
        -n kube-system ${ver_args[@]+"${ver_args[@]}"} --wait --timeout 10m > /dev/null
      kubectl apply -f - > /dev/null <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: gp3
  fsType: ext4
  encrypted: "true"
EOF
      success "StorageClass 'ebs-gp3' ready (encrypted, reclaimPolicy Retain)."
      ;;
    *)
      kubectl get storageclass "$STORAGE_CLASS" > /dev/null 2>&1 \
        || error "StorageClass '$STORAGE_CLASS' does not exist. Existing: $(kubectl get sc -o name | tr '\n' ' ')"
      success "Using existing StorageClass '$STORAGE_CLASS'."
      ;;
  esac
}

install_cert_manager() {
  if kubectl get crd certificates.cert-manager.io > /dev/null 2>&1; then
    success "cert-manager already installed — skipping."
    return 0
  fi
  info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" > /dev/null
  local d
  for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
    kubectl -n cert-manager rollout status "deploy/$d" --timeout=300s > /dev/null
  done
  success "cert-manager ready."
}

install_operator() {
  info "Installing K8ssandra Operator ${OPERATOR_VERSION:-(latest)} in namespace ${NAMESPACE}..."
  helm repo add k8ssandra https://helm.k8ssandra.io/stable --force-update > /dev/null
  helm repo update k8ssandra > /dev/null
  local args=(upgrade --install k8ssandra-operator k8ssandra/k8ssandra-operator
              -n "$NAMESPACE" --create-namespace --wait --timeout 10m)
  [[ -n "$OPERATOR_VERSION" ]] && args+=(--version "$OPERATOR_VERSION")
  [[ "$CLUSTER_SCOPED" == "true" ]] && args+=(--set global.clusterScoped=true)
  # the cert-manager webhook can take a little while to accept requests
  retry 5 20 helm "${args[@]}" > /dev/null || error "K8ssandra Operator install failed."
  success "K8ssandra Operator ${OPERATOR_VERSION:-(latest)} installed."
}

# Rack list: none -> empty; zone -> distinct zones of schedulable nodes; "a,b,c" -> as given
resolve_racks() {
  RACK_ZONES=()
  case "$RACKS" in
    none|"") return 0 ;;
    zone)
      local sel='!node-role.kubernetes.io/control-plane'
      [[ "$SCHEDULE_ON_CONTROL_PLANE" == "true" ]] && sel=''
      mapfile -t RACK_ZONES < <(kubectl get nodes ${sel:+-l "$sel"} \
        -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u)
      [[ ${#RACK_ZONES[@]} -gt 0 ]] || error "--racks zone: no node has a topology.kubernetes.io/zone label. Label nodes or pass --racks a,b,c."
      ;;
    *) read -r -a RACK_ZONES <<< "${RACKS//,/ }" ;;
  esac
  return 0
}

render_cluster_manifest() {
  local soft_aa="" res="" racks="" image="" z
  [[ -n "$CASSANDRA_IMAGE" ]] && image="    serverImage: \"${CASSANDRA_IMAGE}\""
  [[ "$SOFT_ANTI_AFFINITY" == "true" ]] && soft_aa="        softPodAntiAffinity: true"
  if [[ -n "$CASSANDRA_CPU" || -n "$CASSANDRA_MEMORY" ]]; then
    res="        resources:
          requests:"
    [[ -n "$CASSANDRA_CPU" ]]    && res+="
            cpu: \"${CASSANDRA_CPU}\""
    [[ -n "$CASSANDRA_MEMORY" ]] && res+="
            memory: \"${CASSANDRA_MEMORY}\"
          limits:
            memory: \"${CASSANDRA_MEMORY}\""
  fi
  if [[ ${#RACK_ZONES[@]} -gt 0 ]]; then
    racks="        racks:"
    for z in "${RACK_ZONES[@]}"; do
      racks+="
          - name: ${z}
            nodeAffinityLabels:
              topology.kubernetes.io/zone: ${z}"
    done
  fi
  {
    cat <<EOF
# Generated by k8s-k8ssandra-setup.sh v${SCRIPT_VERSION} on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
spec:
  cassandra:
    serverVersion: "${CASSANDRA_VERSION}"
EOF
    [[ -n "$image" ]] && echo "$image"
    cat <<EOF
    datacenters:
      - metadata:
          name: ${DC_NAME}
        size: ${DC_SIZE}
EOF
    [[ -n "$soft_aa" ]] && echo "$soft_aa"
    [[ -n "$res" ]]     && echo "$res"
    [[ -n "$racks" ]]   && echo "$racks"
    cat <<EOF
        storageConfig:
          cassandraDataVolumeClaimSpec:
            storageClassName: ${STORAGE_CLASS_NAME}
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: ${STORAGE_SIZE}
        config:
          jvmOptions:
            heapSize: ${HEAP_SIZE}
EOF
  }
}

check_capacity() {
  [[ "$SOFT_ANTI_AFFINITY" == "true" ]] && return 0
  local schedulable
  schedulable=$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.taints[*].effect}{"\n"}{end}' | grep -vc 'NoSchedule' || true)
  if (( schedulable < DC_SIZE )); then
    warn "Only ${schedulable} schedulable node(s) for ${DC_SIZE} Cassandra pods (one per node) — some pods will stay Pending until more nodes join."
  fi
  return 0
}

deploy_cluster() {
  if [[ "$SKIP_CLUSTER" == "true" ]]; then
    warn "--skip-cluster set — not creating a K8ssandraCluster."
    return 0
  fi
  local manifest
  if [[ -n "$CLUSTER_MANIFEST" ]]; then
    manifest="$CLUSTER_MANIFEST"
    info "Applying your cluster manifest: ${manifest}"
  else
    check_capacity
    manifest="/root/k8ssandra-${CLUSTER_NAME}.yaml"
    [[ "$EUID" -eq 0 ]] || manifest="$HOME/k8ssandra-${CLUSTER_NAME}.yaml"
    render_cluster_manifest > "$manifest"
    info "Deploying Cassandra ${CASSANDRA_VERSION}: cluster ${CLUSTER_NAME}, DC ${DC_NAME} x ${DC_SIZE}, ${STORAGE_SIZE} on ${STORAGE_CLASS_NAME}${RACK_ZONES[0]+, racks: ${RACK_ZONES[*]}}"
    info "Manifest saved to ${manifest} (edit + 'kubectl apply -f' to change it later)."
  fi
  # the operator's admission webhook may need a moment after install
  retry 6 15 kubectl apply -f "$manifest" > /dev/null || error "Could not apply the K8ssandraCluster manifest."
  if [[ -n "$CLUSTER_MANIFEST" ]]; then
    # take name / namespace / first DC from what was actually applied, so the readiness wait works
    read -r CLUSTER_NAME NAMESPACE DC_NAME < <(kubectl get -f "$manifest" \
      -o jsonpath='{.metadata.name} {.metadata.namespace} {.spec.cassandra.datacenters[0].metadata.name}')
  fi
  success "K8ssandraCluster '${CLUSTER_NAME}' applied."
  wait_for_dc
}

wait_for_dc() {
  (( CLUSTER_READY_TIMEOUT == 0 )) && { warn "Not waiting for the datacenter (timeout 0)."; return 0; }
  info "Waiting up to ${CLUSTER_READY_TIMEOUT}s for datacenter '${DC_NAME}' to be Ready (typically 5-15 min)..."
  local deadline=$((SECONDS + CLUSTER_READY_TIMEOUT)) progress ready last=0
  while (( SECONDS < deadline )); do
    progress=$(kubectl -n "$NAMESPACE" get cassandradatacenter "$DC_NAME" -o jsonpath='{.status.cassandraOperatorProgress}' 2>/dev/null || true)
    ready=$(kubectl -n "$NAMESPACE" get cassandradatacenter "$DC_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$progress" == "Ready" && "$ready" == "True" ]]; then
      success "Datacenter '${DC_NAME}' is Ready."
      return 0
    fi
    if (( SECONDS - last >= 60 )); then
      last=$SECONDS
      info "  progress=${progress:-pending} ready=${ready:-unknown}; pods: $(kubectl -n "$NAMESPACE" get pods -l "cassandra.datastax.com/datacenter=${DC_NAME}" --no-headers 2>/dev/null | awk '{printf "%s(%s) ", $1, $3}')"
    fi
    sleep 15
  done
  kubectl -n "$NAMESPACE" get pods -o wide >&2 || true
  error "Datacenter '${DC_NAME}' not Ready after ${CLUSTER_READY_TIMEOUT}s. Investigate: kubectl -n ${NAMESPACE} describe cassandradatacenter ${DC_NAME}; kubectl -n ${NAMESPACE} get pvc"
}

run_addons() {
  [[ -n "$ADDONS" ]] || return 0
  local addons_script="" flags=()
  local f
  for f in "$SCRIPT_DIR"/k8ssandra-addons-setup*.sh; do [[ -f "$f" ]] && { addons_script="$f"; break; }; done
  [[ -n "$addons_script" ]] || { warn "k8ssandra-addons-setup.sh not found next to this script — skipping addons."; return 0; }
  local a
  for a in ${ADDONS//,/ }; do flags+=("--$a"); done
  header "Addons: ${ADDONS}"
  # Medusa secrets go through the environment, never the command line
  MEDUSA_BUCKET="$MEDUSA_BUCKET" MEDUSA_REGION="$MEDUSA_REGION" MEDUSA_CREDENTIALS_TYPE="$MEDUSA_CREDENTIALS_TYPE" \
  MEDUSA_ACCESS_KEY="$MEDUSA_ACCESS_KEY" MEDUSA_SECRET_KEY="$MEDUSA_SECRET_KEY" KUBECONFIG="$KUBECONFIG" \
    bash "$addons_script" "${flags[@]}" --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE"
}

phase_k8ssandra() {
  header "PHASE 3: K8ssandra stack"
  setup_kubeconfig_env
  command -v kubectl > /dev/null || error "kubectl not found."
  kubectl cluster-info > /dev/null 2>&1 || error "Cannot reach the Kubernetes API (KUBECONFIG=${KUBECONFIG:-unset}). Use --kubeconfig."
  success "Cluster reachable: $(kubectl config current-context 2>/dev/null || echo default) — $(kubectl get nodes --no-headers | wc -l) node(s)."
  RACK_ZONES=()
  if [[ -z "$CLUSTER_MANIFEST" && "$SKIP_CLUSTER" != "true" ]]; then resolve_racks; fi   # fail early, before installing anything
  ensure_helm
  install_storage
  install_cert_manager
  install_operator
  deploy_cluster
  run_addons
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
  header "DONE — ${ROLE}"
  setup_kubeconfig_env
  if command -v kubectl > /dev/null && kubectl cluster-info > /dev/null 2>&1; then
    kubectl get nodes -o wide || true
    if kubectl get ns "$NAMESPACE" > /dev/null 2>&1; then
      echo ""; kubectl -n "$NAMESPACE" get k8ssandracluster,cassandradatacenter 2>/dev/null || true
    fi
  fi
  echo ""
  case "$ROLE" in
    control-plane)
      echo -e "${YELLOW}▶ Next:${NC} join more workers:  sudo bash $(basename "$SCRIPT_PATH") --role add-workers --workers IP1,IP2 --ssh-key KEY"
      echo -e "${YELLOW}▶ Then:${NC} install K8ssandra:   sudo bash $(basename "$SCRIPT_PATH") --role k8ssandra [options]"
      echo -e "${YELLOW}▶ Manual join command (valid 24h):${NC}"
      echo "    $(kubeadm token create --print-join-command 2>/dev/null || echo 'kubeadm token create --print-join-command')"
      ;;
    all|k8ssandra)
      cat <<EOF
▶ Cassandra superuser:
    kubectl -n ${NAMESPACE} get secret ${CLUSTER_NAME}-superuser -o jsonpath='{.data.username}' | base64 -d; echo
    kubectl -n ${NAMESPACE} get secret ${CLUSTER_NAME}-superuser -o jsonpath='{.data.password}' | base64 -d; echo
▶ cqlsh / nodetool (first pod of the DC):
    POD=\$(kubectl -n ${NAMESPACE} get pods -l cassandra.datastax.com/datacenter=${DC_NAME} -o jsonpath='{.items[0].metadata.name}')
    kubectl -n ${NAMESPACE} exec -it \$POD -c cassandra -- cqlsh -u <user> -p <password>
    kubectl -n ${NAMESPACE} exec \$POD -c cassandra -- nodetool -u <user> -pw <password> status
▶ Add a datacenter later:  sudo bash scripts/k8ssandra-add-dc.sh --dc-name dc2
EOF
      ;;
  esac
  echo -e "\nLog: ${LOG_FILE:-n/a}"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
validate_config

if [[ "$PRINT_CONFIG" == "true" ]]; then print_config; exit 0; fi
if [[ "$RENDER_ONLY" == "true" ]]; then
  RACK_ZONES=()
  if [[ "$RACKS" != "zone" ]]; then resolve_racks; else
    setup_kubeconfig_env
    if kubectl cluster-info > /dev/null 2>&1; then resolve_racks; else warn "--racks zone needs a reachable cluster; rendering without racks."; fi
  fi
  render_cluster_manifest
  exit 0
fi

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# Log everything (stdout + stderr) to a file as well as the screen
if ! touch "$LOG_FILE" 2> /dev/null; then LOG_FILE="$HOME/k8ssandra-setup.log"; fi
exec > >(tee -a "$LOG_FILE") 2>&1

header "Kubernetes + K8ssandra installer v${SCRIPT_VERSION} — role: ${ROLE} — host: $(hostname)"
case "$ROLE" in
  all|control-plane|worker)
    require_root; detect_os; detect_arch; check_cgroups_local ;;
  add-workers)
    require_root; detect_os; detect_arch ;;
  k8ssandra) ;;
esac

if [[ "$ROLE" == "all" || "$ROLE" == "control-plane" || "$ROLE" == "add-workers" ]]; then
  print_config | sed 's/^/  /'
  if [[ ${#WORKER_LIST[@]} -gt 0 ]]; then preflight_ssh; fi
  confirm "Proceed with role '${ROLE}' on this node?"
fi

case "$ROLE" in
  all)
    phase_node_prep
    phase_control_plane
    join_workers
    phase_k8ssandra
    ;;
  control-plane)
    phase_node_prep
    phase_control_plane
    join_workers
    ;;
  add-workers)
    [[ -f /etc/kubernetes/admin.conf ]] || error "Run add-workers on an initialised control-plane node."
    join_workers
    ;;
  worker)
    phase_node_prep
    phase_worker_join
    ;;
  k8ssandra)
    phase_k8ssandra
    ;;
esac

[[ "$ROLE" == "worker" ]] || print_summary
success "Finished role '${ROLE}'."
