#!/bin/bash
# ============================================================
# k8ssandra-addons-setup.sh
# Deploys: Monitoring (Prometheus + Grafana), Management API,
#          Reaper (repairs), Medusa (backup/restore) for K8ssandra
#
# Usage:
#   sudo bash k8ssandra-addons-setup.sh [OPTIONS]
#
# Options:
#   --all                  Install all components (default)
#   --monitoring           Install Prometheus + Grafana only
#   --reaper               Enable Reaper only
#   --medusa               Enable Medusa only
#   --medusa-bucket        S3 bucket name for Medusa (required for --medusa)
#   --medusa-access-key    AWS access key for S3
#   --medusa-secret-key    AWS secret key for S3
#   --medusa-region        AWS S3 region (default: us-east-1)
#   --cluster-name         K8ssandraCluster name (default: cassandra-cluster)
#   --namespace            Namespace (default: k8ssandra-operator)
#
# Examples:
#   # Install everything (prompts for Medusa S3 details)
#   sudo bash k8ssandra-addons-setup.sh --all
#
#   # Monitoring only
#   sudo bash k8ssandra-addons-setup.sh --monitoring
#
#   # Reaper + Medusa with S3
#   sudo bash k8ssandra-addons-setup.sh --reaper --medusa \
#     --medusa-bucket my-cassandra-backups \
#     --medusa-access-key AKIAIOSFODNN7EXAMPLE \
#     --medusa-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
#     --medusa-region us-east-1
# ============================================================

set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN} $*${NC}"; \
            echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}\n"; }

# ── Defaults ──────────────────────────────────────────────────
INSTALL_MONITORING=false
INSTALL_REAPER=false
INSTALL_MEDUSA=false
CLUSTER_NAME="cassandra-cluster"
NAMESPACE="k8ssandra-operator"
MEDUSA_BUCKET=""
MEDUSA_ACCESS_KEY=""
MEDUSA_SECRET_KEY=""
MEDUSA_REGION="us-east-1"
INSTALL_ALL=false

# ── Argument parsing ──────────────────────────────────────────
if [[ $# -eq 0 ]]; then INSTALL_ALL=true; fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --all)                INSTALL_ALL=true;          shift ;;
    --monitoring)         INSTALL_MONITORING=true;   shift ;;
    --reaper)             INSTALL_REAPER=true;        shift ;;
    --medusa)             INSTALL_MEDUSA=true;        shift ;;
    --medusa-bucket)      MEDUSA_BUCKET="$2";        shift 2 ;;
    --medusa-access-key)  MEDUSA_ACCESS_KEY="$2";    shift 2 ;;
    --medusa-secret-key)  MEDUSA_SECRET_KEY="$2";    shift 2 ;;
    --medusa-region)      MEDUSA_REGION="$2";        shift 2 ;;
    --cluster-name)       CLUSTER_NAME="$2";         shift 2 ;;
    --namespace)          NAMESPACE="$2";             shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

if [[ "$INSTALL_ALL" == "true" ]]; then
  INSTALL_MONITORING=true
  INSTALL_REAPER=true
  INSTALL_MEDUSA=true
fi

# ── Prompt for Medusa S3 details if missing ────────────────────
if [[ "$INSTALL_MEDUSA" == "true" ]]; then
  if [[ -z "$MEDUSA_BUCKET" ]]; then
    read -rp "Enter S3 bucket name for Medusa backups: " MEDUSA_BUCKET
  fi
  if [[ -z "$MEDUSA_ACCESS_KEY" ]]; then
    read -rp "Enter AWS access key ID: " MEDUSA_ACCESS_KEY
  fi
  if [[ -z "$MEDUSA_SECRET_KEY" ]]; then
    read -rsp "Enter AWS secret access key: " MEDUSA_SECRET_KEY; echo ""
  fi
fi

[[ "$EUID" -ne 0 ]] && error "Run with sudo or as root."
which kubectl &>/dev/null || error "kubectl not found."
which helm &>/dev/null    || error "helm not found. Install helm first."

# ── Verify cluster is reachable ────────────────────────────────
kubectl cluster-info &>/dev/null || error "Cannot reach Kubernetes cluster. Check KUBECONFIG."
kubectl get namespace "$NAMESPACE" &>/dev/null || \
  error "Namespace '$NAMESPACE' not found. Is K8ssandra Operator installed?"

# ════════════════════════════════════════════════════════════════
# COMPONENT 1 — MONITORING (Prometheus + Grafana)
# ════════════════════════════════════════════════════════════════
install_monitoring() {
  header "COMPONENT 1: Monitoring — Prometheus + Grafana"

  # ── Add prometheus-community repo ──
  info "Adding prometheus-community Helm repo..."
  helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts > /dev/null
  helm repo update > /dev/null
  success "Helm repo added."

  # ── Write values file ──
  info "Writing kube-prometheus-stack values..."
  cat > /tmp/kube-prom-stack-values.yaml <<'EOF'
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    retention: 15d
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
      limits:
        memory: 1Gi
        cpu: 500m

grafana:
  enabled: true
  adminUser: admin
  adminPassword: K8ssandraAdmin!
  defaultDashboardsEnabled: false
  plugins:
    - grafana-polystat-panel
  image:
    repository: grafana/grafana
    tag: 7.5.11
    pullPolicy: IfNotPresent
  service:
    type: NodePort
    nodePort: 32000

alertmanager:
  enabled: false
EOF

  # ── Install or upgrade kube-prometheus-stack ──
  info "Installing kube-prometheus-stack (Prometheus + Grafana)..."
  if helm status prometheus-grafana -n "$NAMESPACE" &>/dev/null; then
    warn "Already installed — upgrading..."
    helm upgrade prometheus-grafana \
      prometheus-community/kube-prometheus-stack \
      -n "$NAMESPACE" \
      -f /tmp/kube-prom-stack-values.yaml \
      --wait --timeout 5m
  else
    helm install prometheus-grafana \
      prometheus-community/kube-prometheus-stack \
      -n "$NAMESPACE" \
      -f /tmp/kube-prom-stack-values.yaml \
      --wait --timeout 5m
  fi
  success "Prometheus + Grafana installed."

  # ── Install Grafana dashboards for Cassandra ──
  info "Installing Cassandra Grafana dashboards..."
  curl -fsSL \
    "https://raw.githubusercontent.com/k8ssandra/k8ssandra-operator/main/docs/content/en/tasks/monitor/prometheus-grafana/grafana-dashboards.yaml" \
    -o /tmp/grafana-dashboards.yaml 2>/dev/null || \
    warn "Could not download dashboard configmaps — apply manually from K8ssandra docs."

  if [[ -f /tmp/grafana-dashboards.yaml ]]; then
    kubectl apply -f /tmp/grafana-dashboards.yaml -n "$NAMESPACE" || \
      warn "Dashboard configmaps may need manual adjustment."
    success "Grafana dashboards applied."
  fi

  # ── Print access info ──
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  echo ""
  success "Monitoring deployed!"
  echo -e "${YELLOW}  Grafana URL    :${NC} http://${NODE_IP}:32000"
  echo -e "${YELLOW}  Grafana user   :${NC} admin"
  echo -e "${YELLOW}  Grafana pass   :${NC} K8ssandraAdmin!"
  echo -e "${YELLOW}  Port-forward   :${NC} kubectl port-forward svc/prometheus-grafana 3000:80 -n ${NAMESPACE}"
  echo ""
}

# ════════════════════════════════════════════════════════════════
# COMPONENT 2 — UPDATE K8ssandraCluster (Reaper + Telemetry)
# ════════════════════════════════════════════════════════════════
patch_k8ssandra_cluster() {
  header "COMPONENT 2 & 3: Patching K8ssandraCluster — Reaper + Telemetry"

  # Build the patch JSON dynamically based on what is being installed
  REAPER_PATCH=""
  TELEMETRY_PATCH=""

  if [[ "$INSTALL_REAPER" == "true" ]]; then
    info "Adding Reaper to K8ssandraCluster spec..."
    REAPER_PATCH='"reaper": {"keyspace": "reaper_db", "telemetry": {"prometheus": {"enabled": true}}}'
  fi

  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    info "Enabling Prometheus telemetry on Cassandra..."
    TELEMETRY_PATCH='"telemetry": {"prometheus": {"enabled": true}}'
  fi

  # Patch cassandra spec with telemetry
  if [[ -n "$TELEMETRY_PATCH" ]]; then
    kubectl patch k8ssandracluster "$CLUSTER_NAME" \
      -n "$NAMESPACE" \
      --type=merge \
      -p "{\"spec\":{\"cassandra\":{${TELEMETRY_PATCH}}}}" || \
      warn "Could not patch telemetry — you may need to apply manually."
    success "Cassandra telemetry patched."
  fi

  # Patch reaper into the cluster spec
  if [[ -n "$REAPER_PATCH" ]]; then
    kubectl patch k8ssandracluster "$CLUSTER_NAME" \
      -n "$NAMESPACE" \
      --type=merge \
      -p "{\"spec\":{${REAPER_PATCH}}}" || \
      warn "Could not patch Reaper — you may need to apply manually (see output below)."
    success "Reaper added to K8ssandraCluster."
  fi
}

# ════════════════════════════════════════════════════════════════
# COMPONENT 3 — REAPER (service patched to NodePort)
# ════════════════════════════════════════════════════════════════
setup_reaper() {
  header "COMPONENT 3: Reaper — Cassandra Repair Scheduler"

  # ── Wait for Reaper pod to be Running ──
  info "Waiting for Reaper pod to be Running (up to 3 min)..."
  REAPER_POD=""
  for i in {1..18}; do
    REAPER_POD=$(kubectl get pods -n "$NAMESPACE" \
      --selector=app.kubernetes.io/component=reaper \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$REAPER_POD" ]]; then
      STATUS=$(kubectl get pod "$REAPER_POD" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [[ "$STATUS" == "Running" ]] && break
    fi
    sleep 10
  done

  if [[ -z "$REAPER_POD" ]]; then
    warn "Reaper pod not found yet — it may still be starting."
    warn "Re-run once the pod is Running: kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=reaper"
  fi

  # ── Patch Reaper service from ClusterIP → NodePort ──
  REAPER_SVC="${CLUSTER_NAME}-dc1-reaper-service"
  info "Patching Reaper service '${REAPER_SVC}' to NodePort (8080 → 32080, 8081 → 32081)..."

  # Wait up to 2 min for the service to be created by the operator
  for i in {1..12}; do
    kubectl get svc "$REAPER_SVC" -n "$NAMESPACE" &>/dev/null && break
    info "Waiting for service ${REAPER_SVC} to be created..."
    sleep 10
  done

  # Patch type + pin both NodePorts; fall back to simple merge patch if JSON patch fails
  kubectl patch svc "$REAPER_SVC" \
    -n "$NAMESPACE" \
    --type=json \
    -p='[
      {"op": "replace", "path": "/spec/type",                    "value": "NodePort"},
      {"op": "replace", "path": "/spec/ports/0/nodePort",        "value": 32080},
      {"op": "replace", "path": "/spec/ports/1/nodePort",        "value": 32081}
    ]' 2>/dev/null || \
  kubectl patch svc "$REAPER_SVC" \
    -n "$NAMESPACE" \
    --type=merge \
    -p '{"spec": {"type": "NodePort"}}' || \
    warn "Could not auto-patch service. Run manually: kubectl patch svc ${REAPER_SVC} -n ${NAMESPACE} --type=merge -p '{\"spec\":{\"type\":\"NodePort\"}}'"

  success "Reaper service patched to NodePort."

  # ── Retrieve the assigned NodePort ──
  REAPER_NODEPORT=$(kubectl get svc "$REAPER_SVC" -n "$NAMESPACE" \
    -o jsonpath='{.spec.ports[?(@.port==8080)].nodePort}' 2>/dev/null || echo "32080")

  # ── Get a worker node IP (prefer ExternalIP, fall back to InternalIP) ──
  NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[1].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || echo "")
  if [[ -z "$NODE_IP" ]]; then
    NODE_IP=$(kubectl get nodes \
      -o jsonpath='{.items[1].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")
  fi

  # ── Get Reaper credentials ──
  REAPER_SECRET="${CLUSTER_NAME}-reaper-ui"
  REAPER_PASS=$(kubectl get secret "$REAPER_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "check-secret-manually")

  echo ""
  success "Reaper is accessible via NodePort!"
  echo -e "${YELLOW}  Web UI (NodePort) :${NC} http://${NODE_IP}:${REAPER_NODEPORT}/webui"
  echo -e "${YELLOW}  Username          :${NC} ${CLUSTER_NAME}-reaper-ui"
  echo -e "${YELLOW}  Password          :${NC} ${REAPER_PASS}"
  echo ""
  echo -e "${YELLOW}  Get password      :${NC} kubectl get secret ${REAPER_SECRET} -n ${NAMESPACE} -o jsonpath='{.data.password}' | base64 -d"
  echo -e "${YELLOW}  Service status    :${NC} kubectl get svc ${REAPER_SVC} -n ${NAMESPACE}"
  echo ""
  echo -e "${YELLOW}  ▶ To patch manually if needed:${NC}"
  echo -e "    kubectl patch svc ${REAPER_SVC} -n ${NAMESPACE} --type=merge -p '{\"spec\":{\"type\":\"NodePort\"}}'"
  echo ""
}

# ════════════════════════════════════════════════════════════════
# COMPONENT 4 — MEDUSA (S3 backup/restore)
# ════════════════════════════════════════════════════════════════
install_medusa() {
  header "COMPONENT 4: Medusa — Backup and Restore (S3)"

  # ── Create S3 credentials secret ──
  info "Creating Medusa S3 credentials secret..."
  kubectl create secret generic medusa-bucket-key \
    -n "$NAMESPACE" \
    --from-literal=credentials="[default]
aws_access_key_id = ${MEDUSA_ACCESS_KEY}
aws_secret_access_key = ${MEDUSA_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "Medusa credentials secret created/updated."

  # ── Patch K8ssandraCluster with Medusa config ──
  info "Adding Medusa to K8ssandraCluster spec..."
  kubectl patch k8ssandracluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    --type=merge \
    -p "{
      \"spec\": {
        \"medusa\": {
          \"storageProperties\": {
            \"storageProvider\": \"s3\",
            \"storageSecretRef\": {\"name\": \"medusa-bucket-key\"},
            \"bucketName\": \"${MEDUSA_BUCKET}\",
            \"prefix\": \"${CLUSTER_NAME}\",
            \"region\": \"${MEDUSA_REGION}\",
            \"secure\": true
          },
          \"serviceProperties\": {
            \"grpcPort\": 50051
          }
        }
      }
    }" || error "Failed to patch K8ssandraCluster with Medusa config."
  success "Medusa added to K8ssandraCluster."

  echo ""
  success "Medusa deployed!"
  echo -e "${YELLOW}  Storage        :${NC} S3 (${MEDUSA_REGION})"
  echo -e "${YELLOW}  Bucket         :${NC} ${MEDUSA_BUCKET}"
  echo -e "${YELLOW}  Prefix         :${NC} ${CLUSTER_NAME}"
  echo ""
  echo -e "${YELLOW}  Take a backup  :${NC}"
  echo -e "    kubectl apply -f - <<EOF"
  echo -e "    apiVersion: medusa.k8ssandra.io/v1alpha1"
  echo -e "    kind: CassandraBackup"
  echo -e "    metadata:"
  echo -e "      name: backup-\$(date +%Y%m%d)"
  echo -e "      namespace: ${NAMESPACE}"
  echo -e "    spec:"
  echo -e "      name: backup-\$(date +%Y%m%d)"
  echo -e "      k8ssandraClusterRef:"
  echo -e "        name: ${CLUSTER_NAME}"
  echo -e "        namespace: ${NAMESPACE}"
  echo -e "    EOF"
  echo ""
  echo -e "${YELLOW}  List backups   :${NC} kubectl get cassandrabackup -n ${NAMESPACE}"
  echo -e "${YELLOW}  List restores  :${NC} kubectl get cassandrarestore -n ${NAMESPACE}"
  echo ""
}

# ════════════════════════════════════════════════════════════════
# FINAL VERIFICATION
# ════════════════════════════════════════════════════════════════
verify_all() {
  header "Verification — All Components"

  info "K8ssandraCluster status:"
  kubectl get k8ssandracluster -n "$NAMESPACE"
  echo ""

  info "All pods in $NAMESPACE:"
  kubectl get pods -n "$NAMESPACE"
  echo ""

  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    info "ServiceMonitors (Prometheus scrape targets):"
    kubectl get servicemonitor -n "$NAMESPACE" 2>/dev/null || \
      warn "No ServiceMonitors yet — they appear after Cassandra pods are fully running."
    echo ""
  fi
}

# ════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════
echo ""
header "K8ssandra Addons Setup"
info "Cluster   : $CLUSTER_NAME"
info "Namespace : $NAMESPACE"
info "Components: Monitoring=$INSTALL_MONITORING | Reaper=$INSTALL_REAPER | Medusa=$INSTALL_MEDUSA"
echo ""

[[ "$INSTALL_MONITORING" == "true" ]] && install_monitoring
[[ "$INSTALL_REAPER" == "true" || "$INSTALL_MONITORING" == "true" ]] && patch_k8ssandra_cluster
[[ "$INSTALL_REAPER" == "true" ]] && setup_reaper
[[ "$INSTALL_MEDUSA" == "true" ]]  && install_medusa
verify_all

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} ALL ADDONS DEPLOYED SUCCESSFULLY${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}▶ Watch all pods come up:${NC}"
echo -e "  kubectl get pods -n ${NAMESPACE} -w"
echo ""
echo -e "${YELLOW}▶ Check K8ssandraCluster overall status:${NC}"
echo -e "  kubectl get k8ssandracluster -n ${NAMESPACE}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
