#!/bin/bash
# ============================================================
# k8ssandra-add-dc.sh
# Adds a new Cassandra datacenter to an existing K8ssandraCluster.
#
# Prerequisites:
#   - Existing K8ssandraCluster named 'cassandra-cluster' in
#     namespace 'k8ssandra-operator'
#   - Worker nodes already joined (--role worker) and Ready
#   - Run on the control plane node as root / sudo
#
# Usage:
#   sudo bash scripts/k8ssandra-add-dc.sh \
#     --dc-name dc2 \
#     --dc-size 3 \
#     --storage 20Gi
#
# Defaults (if not provided):
#   --dc-name   dc2
#   --dc-size   3
#   --storage   20Gi
# ============================================================

set -euo pipefail

# ── Colour helpers ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Defaults ──
DC_NAME="dc2"
DC_SIZE=3
STORAGE="20Gi"
NAMESPACE="k8ssandra-operator"
CLUSTER_NAME="cassandra-cluster"

# ── Parse arguments ──
while [[ $# -gt 0 ]]; do
  case $1 in
    --dc-name)  DC_NAME="$2";  shift 2 ;;
    --dc-size)  DC_SIZE="$2";  shift 2 ;;
    --storage)  STORAGE="$2";  shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── Must run as root ──
[[ "$EUID" -ne 0 ]] && error "Please run with sudo or as root."

export KUBECONFIG=/etc/kubernetes/admin.conf

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN} K8ssandra — Add Datacenter${NC}"
echo -e "${CYAN} Cluster : ${CLUSTER_NAME} (ns: ${NAMESPACE})${NC}"
echo -e "${CYAN} New DC  : ${DC_NAME} | Size: ${DC_SIZE} | Storage: ${STORAGE}${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# ── Verify cluster exists ──
info "Verifying K8ssandraCluster '${CLUSTER_NAME}' exists..."
kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" > /dev/null || \
  error "K8ssandraCluster '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'."
success "Cluster found."

# ── Verify no DC with same name already exists ──
info "Checking for existing DC named '${DC_NAME}'..."
EXISTING=$(kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
  -o jsonpath="{.spec.cassandra.datacenters[?(@.metadata.name=='${DC_NAME}')].metadata.name}" \
  2>/dev/null || true)
[[ -n "$EXISTING" ]] && error "Datacenter '${DC_NAME}' already exists in cluster '${CLUSTER_NAME}'."
success "DC name '${DC_NAME}' is available."

# ── Check enough Ready worker nodes are available ──
info "Checking Ready nodes..."
READY_NODES=$(kubectl get nodes --no-headers | grep -c ' Ready' || true)
info "Ready nodes: ${READY_NODES}"
if [[ "$READY_NODES" -lt "$DC_SIZE" ]]; then
  warn "Only ${READY_NODES} Ready node(s) found but DC size is ${DC_SIZE}."
  warn "Pods may stay Pending until more nodes join."
fi

# ── Retrieve current Cassandra server version from existing cluster ──
SERVER_VERSION=$(kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.cassandra.serverVersion}')
info "Cassandra server version (from existing cluster): ${SERVER_VERSION}"

# ── Patch K8ssandraCluster to add the new DC ──
info "Patching K8ssandraCluster to add datacenter '${DC_NAME}'..."

# Build the JSON patch — appends the new DC to the datacenters array
kubectl patch k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
  --type=json \
  -p "[
    {
      \"op\": \"add\",
      \"path\": \"/spec/cassandra/datacenters/-\",
      \"value\": {
        \"metadata\": {
          \"name\": \"${DC_NAME}\"
        },
        \"size\": ${DC_SIZE},
        \"storageConfig\": {
          \"cassandraDataVolumeClaimSpec\": {
            \"storageClassName\": \"local-path\",
            \"accessModes\": [\"ReadWriteOnce\"],
            \"resources\": {
              \"requests\": {
                \"storage\": \"${STORAGE}\"
              }
            }
          }
        },
        \"config\": {
          \"jvmOptions\": {
            \"heapSize\": \"2048M\"
          }
        }
      }
    }
  ]"

success "Patch applied — datacenter '${DC_NAME}' added to spec."

# ── Wait for new DC pods to appear ──
info "Waiting for DC '${DC_NAME}' pods to be created (up to 5 min)..."
DEADLINE=$((SECONDS + 300))
while [[ $SECONDS -lt $DEADLINE ]]; do
  POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" \
    --selector="cassandra.datastax.com/datacenter=${DC_NAME}" \
    --no-headers 2>/dev/null | wc -l || true)
  if [[ "$POD_COUNT" -gt 0 ]]; then
    success "DC '${DC_NAME}' pods found (${POD_COUNT})."
    break
  fi
  info "No pods yet — retrying in 10s..."
  sleep 10
done

if [[ $SECONDS -ge $DEADLINE ]]; then
  warn "Timed out waiting for DC pods. Check: kubectl get pods -n ${NAMESPACE}"
fi

# ── Summary ──
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Datacenter '${DC_NAME}' add request submitted.${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
info "Current datacenters in cluster:"
kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{range .spec.cassandra.datacenters[*]}{.metadata.name}{"\t"}{.size}{" nodes\n"}{end}'
echo ""
info "Pod status (may take 5–10 min for new DC to fully start):"
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
echo -e "${YELLOW}▶ Monitor new DC rollout:${NC}"
echo -e "  kubectl get k8ssandracluster ${CLUSTER_NAME} -n ${NAMESPACE} -w"
echo ""
echo -e "${YELLOW}▶ Monitor new DC pods:${NC}"
echo -e "  kubectl get pods -n ${NAMESPACE} -l cassandra.datastax.com/datacenter=${DC_NAME} -w"
echo ""
echo -e "${YELLOW}▶ Monitor PVC binding for new DC:${NC}"
echo -e "  kubectl get pvc -n ${NAMESPACE} -w"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
