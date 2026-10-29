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
#     --storage 20Gi \
#     --replication '{"my_keyspace": 3, "other_ks": 3}'
#
# Defaults (if not provided):
#   --dc-name        dc2
#   --dc-size        3
#   --storage        20Gi
#   --storage-class  same as the first existing DC
#   --heap-size      same as the first existing DC (else 2048M)
#   --replication    none -- only system/K8ssandra keyspaces get replicas in the new
#                    DC. To copy YOUR keyspaces, list ALL of them with a replica
#                    count (0 = no replicas); the operator then alters replication
#                    and rebuilds the new DC (k8ssandra.io/dc-replication annotation).
#   --cluster-name   cassandra-cluster      --namespace  k8ssandra-operator
#
# Need more nodes first? From the control plane:
#   sudo bash scripts/k8s-k8ssandra-setup.sh --role add-workers --workers IP1,IP2,IP3 --ssh-key KEY
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
STORAGE_CLASS=""
HEAP_SIZE=""
REPLICATION=""
NAMESPACE="k8ssandra-operator"
CLUSTER_NAME="cassandra-cluster"

# ── Parse arguments ──
while [[ $# -gt 0 ]]; do
  case $1 in
    --dc-name)  DC_NAME="$2";  shift 2 ;;
    --dc-size)  DC_SIZE="$2";  shift 2 ;;
    --storage)  STORAGE="$2";  shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --heap-size)     HEAP_SIZE="$2";     shift 2 ;;
    --replication)   REPLICATION="$2";   shift 2 ;;
    --cluster-name)  CLUSTER_NAME="$2";  shift 2 ;;
    --namespace)     NAMESPACE="$2";     shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ "$DC_SIZE" =~ ^[1-9][0-9]*$ ]] || error "--dc-size must be a positive integer."
[[ "$DC_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || error "--dc-name must be lowercase letters, digits and '-'."
if [[ -n "$REPLICATION" ]]; then
  command -v python3 > /dev/null || error "--replication needs python3 to validate the JSON."
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert isinstance(d,dict) and d and all(type(v) is int and v>=0 for v in d.values())' "$REPLICATION" 2>/dev/null \
    || error "--replication must be a JSON object of keyspace -> replica count, e.g. '{\"ks1\": 3}'"
fi

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

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

# ── Check enough FREE schedulable nodes exist (Ready, no NoSchedule taint, no Cassandra pod yet) ──
info "Checking free schedulable nodes..."
BUSY=$(kubectl get pods -A -l app.kubernetes.io/name=cassandra \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sed '/^$/d' | sort -u)
FREE_NODES=0
while read -r NODE READY TAINTS; do
  [[ "$READY" != "True" || "${TAINTS:-}" == *NoSchedule* ]] && continue
  grep -qx "$NODE" <<< "$BUSY" && continue
  FREE_NODES=$((FREE_NODES + 1))
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.spec.taints[*].effect}{"\n"}{end}')
info "Free nodes for the new DC: ${FREE_NODES} (need ${DC_SIZE})"
if [[ "$FREE_NODES" -lt "$DC_SIZE" ]]; then
  warn "Only ${FREE_NODES} free node(s) but DC size is ${DC_SIZE} -- some pods will stay Pending."
  warn "Add workers first: sudo bash scripts/k8s-k8ssandra-setup.sh --role add-workers --workers IP1,IP2 --ssh-key KEY"
fi

# ── Inherit storage class / heap from the first DC (or cluster-level settings) ──
if [[ -z "$STORAGE_CLASS" ]]; then
  STORAGE_CLASS=$(kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.cassandra.datacenters[0].storageConfig.cassandraDataVolumeClaimSpec.storageClassName}')
  if [[ -z "$STORAGE_CLASS" ]]; then
    STORAGE_CLASS=$(kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.cassandra.storageConfig.cassandraDataVolumeClaimSpec.storageClassName}')
  fi
  STORAGE_CLASS=${STORAGE_CLASS:-local-path}
fi
kubectl get storageclass "$STORAGE_CLASS" > /dev/null 2>&1 || error "StorageClass '${STORAGE_CLASS}' not found."
if [[ -z "$HEAP_SIZE" ]]; then
  HEAP_SIZE=$(kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.cassandra.datacenters[0].config.jvmOptions.heapSize}')
  HEAP_SIZE=${HEAP_SIZE:-2048M}
fi
info "Storage class: ${STORAGE_CLASS} | Heap: ${HEAP_SIZE}"

# ── Replication annotation for user keyspaces (must be set BEFORE the DC is added) ──
if [[ -n "$REPLICATION" ]]; then
  EXISTING_ANN=$(kubectl get k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.k8ssandra\.io/dc-replication}')
  NEW_ANN=$(python3 -c 'import json,sys; a=json.loads(sys.argv[1] or "{}"); a[sys.argv[2]]=json.loads(sys.argv[3]); print(json.dumps(a))' \
    "$EXISTING_ANN" "$DC_NAME" "$REPLICATION")
  kubectl annotate k8ssandracluster "${CLUSTER_NAME}" -n "${NAMESPACE}" --overwrite "k8ssandra.io/dc-replication=${NEW_ANN}" > /dev/null
  success "Replication for user keyspaces in ${DC_NAME}: ${REPLICATION}"
else
  warn "No --replication given: your own keyspaces will NOT get replicas in ${DC_NAME}."
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
            \"storageClassName\": \"${STORAGE_CLASS}\",
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
            \"heapSize\": \"${HEAP_SIZE}\"
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
