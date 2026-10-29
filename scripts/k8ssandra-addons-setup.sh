#!/bin/bash
# ============================================================
# k8ssandra-addons-setup.sh
# Deploys: Monitoring (Prometheus + Grafana), Management API,
#          Reaper (repairs), Medusa (backup/restore) for K8ssandra
#
# Addon coverage across datacenters:
#   - Prometheus + Grafana : cluster-wide — covers ALL DCs automatically
#   - Telemetry patch      : cluster-wide — covers ALL DCs automatically
#   - Reaper               : operator deploys one Reaper service per DC —
#                            this script patches NodePort for ALL DCs
#   - Medusa               : cluster-wide — covers ALL DCs automatically
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
#   --medusa-region        AWS S3 region (default: us-east-1)
#   --medusa-credentials-type credential-based (default) | role-based
#   --medusa-access-key    AWS access key (prefer env var MEDUSA_ACCESS_KEY)
#   --medusa-secret-key    AWS secret key (prefer env var MEDUSA_SECRET_KEY)
#
# Medusa settings can also come from environment variables, which keeps secrets
# out of the process list and shell history:
#   MEDUSA_BUCKET, MEDUSA_REGION, MEDUSA_CREDENTIALS_TYPE,
#   MEDUSA_ACCESS_KEY, MEDUSA_SECRET_KEY,
#   MEDUSA_BACKUP_SCHEDULE   cron for automatic daily backups, e.g. "0 1 * * *"
#   GRAFANA_ADMIN_PASSWORD   Grafana admin password (default: random, kept on re-runs)
# role-based uses the node's IAM instance profile (needs IMDS hop limit >= 2)
# or IRSA on EKS — no keys stored in the cluster.
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
#   # Reaper + Medusa with S3 (keys via environment, not flags)
#   export MEDUSA_ACCESS_KEY=... MEDUSA_SECRET_KEY=...
#   bash k8ssandra-addons-setup.sh --reaper --medusa \
#     --medusa-bucket my-cassandra-backups --medusa-region us-east-1
#
#   # Medusa with the instance's IAM role, no keys at all
#   bash k8ssandra-addons-setup.sh --medusa --medusa-bucket my-cassandra-backups \
#     --medusa-credentials-type role-based
# ============================================================

set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

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
MEDUSA_BUCKET="${MEDUSA_BUCKET:-}"
MEDUSA_ACCESS_KEY="${MEDUSA_ACCESS_KEY:-}"
MEDUSA_SECRET_KEY="${MEDUSA_SECRET_KEY:-}"
MEDUSA_REGION="${MEDUSA_REGION:-us-east-1}"
MEDUSA_CREDENTIALS_TYPE="${MEDUSA_CREDENTIALS_TYPE:-credential-based}"
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
    --medusa-credentials-type) MEDUSA_CREDENTIALS_TYPE="$2"; shift 2 ;;
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
# Prompts only when a human is at the terminal; unattended runs fail fast instead of hanging.
if [[ "$INSTALL_MEDUSA" == "true" ]]; then
  [[ "$MEDUSA_CREDENTIALS_TYPE" =~ ^(credential-based|role-based)$ ]] || \
    error "--medusa-credentials-type must be credential-based or role-based."
  ask() { [[ -t 0 ]] || error "$1 is not set (set it via environment/config — running non-interactively)."; }
  if [[ -z "$MEDUSA_BUCKET" ]]; then
    ask MEDUSA_BUCKET; read -rp "Enter S3 bucket name for Medusa backups: " MEDUSA_BUCKET
  fi
  if [[ "$MEDUSA_CREDENTIALS_TYPE" == "credential-based" ]]; then
    if [[ -z "$MEDUSA_ACCESS_KEY" ]]; then
      ask MEDUSA_ACCESS_KEY; read -rp "Enter AWS access key ID: " MEDUSA_ACCESS_KEY
    fi
    if [[ -z "$MEDUSA_SECRET_KEY" ]]; then
      ask MEDUSA_SECRET_KEY; read -rsp "Enter AWS secret access key: " MEDUSA_SECRET_KEY; echo ""
    fi
  fi
fi
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

  # ── Grafana admin password: keep the existing one, else $GRAFANA_ADMIN_PASSWORD, else random ──
  local grafana_pw
  grafana_pw=$(kubectl get secret prometheus-grafana -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -z "$grafana_pw" ]] && grafana_pw="${GRAFANA_ADMIN_PASSWORD:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)}"
  ( umask 077; printf 'grafana:\n  adminPassword: "%s"\n' "$grafana_pw" > /tmp/kube-prom-stack-secret-values.yaml )

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
      -f /tmp/kube-prom-stack-values.yaml -f /tmp/kube-prom-stack-secret-values.yaml \
      --wait --timeout 5m
  else
    helm install prometheus-grafana \
      prometheus-community/kube-prometheus-stack \
      -n "$NAMESPACE" \
      -f /tmp/kube-prom-stack-values.yaml -f /tmp/kube-prom-stack-secret-values.yaml \
      --wait --timeout 5m
  fi
  rm -f /tmp/kube-prom-stack-secret-values.yaml
  success "Prometheus + Grafana installed."

  # ── Install Grafana dashboards for Cassandra ──
  info "Installing Cassandra Grafana dashboards..."
  curl -fsSL \
    "https://raw.githubusercontent.com/k8ssandra/k8ssandra-operator/${K8SSANDRA_DOCS_REF:-v1.33.0}/docs/content/en/tasks/monitor/prometheus-grafana/grafana-dashboards.yaml" \
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
  echo -e "${YELLOW}  Grafana pass   :${NC} kubectl get secret prometheus-grafana -n ${NAMESPACE} -o jsonpath='{.data.admin-password}' | base64 -d; echo"
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
      -p "{\"spec\":{\"cassandra\":{${TELEMETRY_PATCH}}}}" \
      && success "Cassandra telemetry patched." \
      || warn "Could not patch telemetry — you may need to apply manually."
  fi

  # Patch reaper into the cluster spec
  if [[ -n "$REAPER_PATCH" ]]; then
    kubectl patch k8ssandracluster "$CLUSTER_NAME" \
      -n "$NAMESPACE" \
      --type=merge \
      -p "{\"spec\":{${REAPER_PATCH}}}" \
      && success "Reaper added to K8ssandraCluster." \
      || warn "Could not patch Reaper — you may need to apply manually (see output below)."
  fi
}

# ════════════════════════════════════════════════════════════════
# COMPONENT 3 — REAPER (NodePort patched for every DC)
# The K8ssandra operator creates one Reaper service per DC.
# This function discovers all DC services and patches them all.
# NodePorts are assigned starting at 32080, incrementing by 10
# per DC: dc1=32080, dc2=32090, dc3=32100, …
# ════════════════════════════════════════════════════════════════
setup_reaper() {
  header "COMPONENT 3: Reaper — Cassandra Repair Scheduler (all DCs)"

  # ── Wait for at least one Reaper pod to be Running ──
  info "Waiting for Reaper pod(s) to be Running (up to 3 min)..."
  for _ in {1..18}; do
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
  [[ -z "$REAPER_POD" ]] && \
    warn "Reaper pod not found yet — services will still be patched if present."

  # ── Get a node IP for access info ──
  NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[1].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || echo "")
  [[ -z "$NODE_IP" ]] && NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[1].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")

  # ── Get Reaper credentials (shared across all DCs) ──
  REAPER_SECRET="${CLUSTER_NAME}-reaper-ui"
  REAPER_USER=$(kubectl get secret "$REAPER_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "check-secret-manually")
  REAPER_PASS=$(kubectl get secret "$REAPER_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "check-secret-manually")

  # ── Discover all DC names from the K8ssandraCluster CR ──
  mapfile -t DC_NAMES < <(kubectl get k8ssandracluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{range .spec.cassandra.datacenters[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "dc1")

  info "Found ${#DC_NAMES[@]} datacenter(s): ${DC_NAMES[*]}"

  # ── Patch Reaper service for each DC ──
  BASE_NODEPORT=32080
  DC_INDEX=0
  for DC in "${DC_NAMES[@]}"; do
    REAPER_SVC="${CLUSTER_NAME}-${DC}-reaper-service"
    NODEPORT=$((BASE_NODEPORT + DC_INDEX * 10))
    NODEPORT_SVC="${CLUSTER_NAME}-${DC}-reaper-nodeport"

    info "Exposing Reaper for ${DC} on NodePort ${NODEPORT} (service '${NODEPORT_SVC}')..."

    # Wait up to 2 min for the service to exist
    SVC_FOUND=false
    for _ in {1..12}; do
      if kubectl get svc "$REAPER_SVC" -n "$NAMESPACE" &>/dev/null; then
        SVC_FOUND=true
        break
      fi
      info "  Waiting for ${REAPER_SVC} to be created..."
      sleep 10
    done

    if [[ "$SVC_FOUND" == "false" ]]; then
      warn "Service '${REAPER_SVC}' not found — skipping (DC may still be starting)."
      DC_INDEX=$((DC_INDEX + 1))
      continue
    fi

    # The operator's Reaper service exposes one port (8080, "app") and is reconciled by the
    # operator, so instead of patching it we create our own NodePort service with the same
    # pod selector. The operator never touches it, so the port stays fixed.
    SELECTOR=$(kubectl get svc "$REAPER_SVC" -n "$NAMESPACE" -o jsonpath='{.spec.selector}')
    TARGET_PORT=$(kubectl get svc "$REAPER_SVC" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].targetPort}')
    [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || TARGET_PORT="\"${TARGET_PORT:-app}\""
    if [[ -z "$SELECTOR" ]]; then
      warn "Could not read the selector of ${REAPER_SVC} — skipping ${DC}."
      DC_INDEX=$((DC_INDEX + 1))
      continue
    fi
    if kubectl apply -n "$NAMESPACE" -f - > /dev/null <<EOF_SVC
{
  "apiVersion": "v1",
  "kind": "Service",
  "metadata": {
    "name": "${NODEPORT_SVC}",
    "labels": {"app.kubernetes.io/managed-by": "k8ssandra-addons-setup", "k8ssandra.io/cluster-name": "${CLUSTER_NAME}"}
  },
  "spec": {
    "type": "NodePort",
    "selector": ${SELECTOR},
    "ports": [{"name": "app", "port": 8080, "targetPort": ${TARGET_PORT}, "nodePort": ${NODEPORT}, "protocol": "TCP"}]
  }
}
EOF_SVC
    then
      success "Reaper for ${DC} exposed on NodePort ${NODEPORT}."
      echo -e "${YELLOW}  ${DC} Web UI :${NC} http://${NODE_IP}:${NODEPORT}/webui"
    else
      warn "Could not create ${NODEPORT_SVC} (is port ${NODEPORT} already used?). Use: kubectl port-forward svc/${REAPER_SVC} 8080:8080 -n ${NAMESPACE}"
    fi

    DC_INDEX=$((DC_INDEX + 1))
  done

  echo ""
  echo -e "${YELLOW}  Username   :${NC} ${REAPER_USER}"
  echo -e "${YELLOW}  Password   :${NC} ${REAPER_PASS}"
  echo -e "${YELLOW}  Get secret :${NC} kubectl get secret ${REAPER_SECRET} -n ${NAMESPACE} -o jsonpath='{.data.password}' | base64 -d"
  echo ""
}

# ════════════════════════════════════════════════════════════════
# COMPONENT 4 — MEDUSA (S3 backup/restore)
# ════════════════════════════════════════════════════════════════
install_medusa() {
  header "COMPONENT 4: Medusa — Backup and Restore (S3)"

  local secret_ref='{"name": "medusa-bucket-key"}'
  if [[ "$MEDUSA_CREDENTIALS_TYPE" == "role-based" ]]; then
    info "Using role-based credentials (IAM instance profile / IRSA) — no secret created."
    secret_ref='{"name": ""}'
  else
    # ── Create S3 credentials secret (keys piped via stdin, never on a command line) ──
    info "Creating Medusa S3 credentials secret..."
    printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
      "$MEDUSA_ACCESS_KEY" "$MEDUSA_SECRET_KEY" \
      | kubectl create secret generic medusa-bucket-key -n "$NAMESPACE" \
          --from-file=credentials=/dev/stdin --dry-run=client -o yaml \
      | kubectl apply -f - > /dev/null
    success "Medusa credentials secret created/updated."
  fi

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
            \"credentialsType\": \"${MEDUSA_CREDENTIALS_TYPE}\",
            \"storageSecretRef\": ${secret_ref},
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
  info "Note: adding Medusa rolling-restarts the Cassandra pods (a medusa container is added to each)."

  # ── Optional: scheduled backups (one MedusaBackupSchedule per DC) ──
  if [[ -n "${MEDUSA_BACKUP_SCHEDULE:-}" ]]; then
    local dc
    for dc in $(kubectl get k8ssandracluster "$CLUSTER_NAME" -n "$NAMESPACE" \
                  -o jsonpath='{range .spec.cassandra.datacenters[*]}{.metadata.name}{" "}{end}'); do
      kubectl apply -n "$NAMESPACE" -f - > /dev/null <<EOF_SCHED
apiVersion: medusa.k8ssandra.io/v1alpha1
kind: MedusaBackupSchedule
metadata:
  name: ${CLUSTER_NAME}-${dc}-backup-schedule
spec:
  cronSchedule: "${MEDUSA_BACKUP_SCHEDULE}"
  backupSpec:
    cassandraDatacenter: ${dc}
    backupType: differential
EOF_SCHED
      success "Backup schedule for ${dc}: '${MEDUSA_BACKUP_SCHEDULE}' (differential)."
    done
  fi

  echo ""
  echo -e "${YELLOW}  Take a backup now (per DC):${NC}"
  echo -e "    kubectl apply -n ${NAMESPACE} -f - <<EOF"
  echo -e "    apiVersion: medusa.k8ssandra.io/v1alpha1"
  echo -e "    kind: MedusaBackupJob"
  echo -e "    metadata:"
  echo -e "      name: backup-\$(date +%Y%m%d-%H%M)"
  echo -e "    spec:"
  echo -e "      cassandraDatacenter: dc1"
  echo -e "    EOF"
  echo ""
  echo -e "${YELLOW}  Backup jobs    :${NC} kubectl get medusabackupjob -n ${NAMESPACE}"
  echo -e "${YELLOW}  Backups        :${NC} kubectl get medusabackup -n ${NAMESPACE}"
  echo -e "${YELLOW}  Restore        :${NC} create a MedusaRestoreJob (spec.cassandraDatacenter + spec.backup: <backup name>)"
  echo -e "${YELLOW}  Schedules      :${NC} kubectl get medusabackupschedule -n ${NAMESPACE}"
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
