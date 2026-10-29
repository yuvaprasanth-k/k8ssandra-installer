#!/bin/bash
# ============================================================
# k8ssandra-backup-setup.sh
# Backups for K8ssandra: SeaweedFS (in-cluster S3 storage) and Medusa.
# Kept separate from k8ssandra-addons-setup.sh (monitoring + Reaper).
#
# Usage (run on the control plane):
#   # In-cluster SeaweedFS + Medusa, fully automatic (bucket, endpoint, keys)
#   sudo bash k8ssandra-backup-setup.sh --seaweedfs --medusa
#
#   # Same, plus a test backup at the end
#   sudo bash k8ssandra-backup-setup.sh --seaweedfs --medusa --test-backup
#
#   # SeaweedFS only (add Medusa later with: --seaweedfs --medusa)
#   sudo bash k8ssandra-backup-setup.sh --seaweedfs
#
#   # Medusa to AWS S3 (keys via environment, never on the command line)
#   export MEDUSA_ACCESS_KEY=... MEDUSA_SECRET_KEY=...
#   sudo -E bash k8ssandra-backup-setup.sh --medusa --medusa-bucket my-bucket --medusa-region us-east-1
#
#   # Medusa with the instance's IAM role (AWS S3 only, no keys)
#   sudo bash k8ssandra-backup-setup.sh --medusa --medusa-bucket my-bucket --medusa-credentials-type role-based
#
#   # Medusa to other S3-compatible storage (MinIO, Wasabi, Ceph RGW, ...)
#   export MEDUSA_ACCESS_KEY=... MEDUSA_SECRET_KEY=...
#   sudo -E bash k8ssandra-backup-setup.sh --medusa --medusa-provider s3_compatible \
#     --medusa-bucket cassandra-backups --medusa-host 10.0.1.50 --medusa-port 9000 --medusa-secure false
#
# Options:
#   --seaweedfs                Install SeaweedFS (single pod, data on a PVC) and create the bucket.
#                              With --medusa, Medusa is wired to it automatically.
#   --medusa                   Enable Medusa on the K8ssandraCluster (rolling restart of Cassandra)
#   --test-backup              Run a MedusaBackupJob on the first DC and wait for it to finish
#   --medusa-bucket NAME       Bucket (default with --seaweedfs: cassandra-backups)
#   --medusa-provider P        s3 (AWS, default) | s3_compatible | s3_rgw
#   --medusa-host HOST         Endpoint host/IP for s3_compatible / s3_rgw (no http://)
#   --medusa-port PORT         Endpoint port
#   --medusa-secure B          true|false — HTTPS to the endpoint (default true)
#   --medusa-ssl-verify B      true|false — verify TLS certificate (default true)
#   --medusa-region R          Region (default us-east-1)
#   --medusa-credentials-type  credential-based (default) | role-based (AWS S3 only)
#   --cluster-name NAME        K8ssandraCluster name (default cassandra-cluster)
#   --namespace NS             Namespace (default k8ssandra-operator)
#
# Environment variables (also usable from config/cluster.env with set -a):
#   MEDUSA_ACCESS_KEY, MEDUSA_SECRET_KEY, MEDUSA_BUCKET, MEDUSA_REGION, MEDUSA_PROVIDER,
#   MEDUSA_HOST, MEDUSA_PORT, MEDUSA_SECURE, MEDUSA_SSL_VERIFY, MEDUSA_CREDENTIALS_TYPE,
#   MEDUSA_MAX_BACKUP_COUNT   keep at most N backups (purge)
#   MEDUSA_BACKUP_SCHEDULE    cron for automatic backups, e.g. "0 1 * * *"
#   SEAWEEDFS_STORAGE_CLASS   PVC storage class for SeaweedFS (default local-path)
#   SEAWEEDFS_SIZE            PVC size (default 50Gi)
#   SEAWEEDFS_CHART_VERSION   seaweedfs Helm chart version (default 4.51.0)
#   SEAWEEDFS_NAMESPACE       (default seaweedfs)
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
usage()   { sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; }

# ── Defaults ──────────────────────────────────────────────────
INSTALL_SEAWEEDFS=false
INSTALL_MEDUSA=false
TEST_BACKUP=false
CLUSTER_NAME="cassandra-cluster"
NAMESPACE="k8ssandra-operator"
MEDUSA_BUCKET="${MEDUSA_BUCKET:-}"
MEDUSA_ACCESS_KEY="${MEDUSA_ACCESS_KEY:-}"
MEDUSA_SECRET_KEY="${MEDUSA_SECRET_KEY:-}"
MEDUSA_REGION="${MEDUSA_REGION:-us-east-1}"
MEDUSA_CREDENTIALS_TYPE="${MEDUSA_CREDENTIALS_TYPE:-credential-based}"
MEDUSA_PROVIDER="${MEDUSA_PROVIDER:-s3}"
MEDUSA_HOST="${MEDUSA_HOST:-}"
MEDUSA_PORT="${MEDUSA_PORT:-}"
MEDUSA_SECURE="${MEDUSA_SECURE:-true}"
MEDUSA_SSL_VERIFY="${MEDUSA_SSL_VERIFY:-true}"
MEDUSA_MAX_BACKUP_COUNT="${MEDUSA_MAX_BACKUP_COUNT:-}"
SEAWEEDFS_NAMESPACE="${SEAWEEDFS_NAMESPACE:-seaweedfs}"
SEAWEEDFS_STORAGE_CLASS="${SEAWEEDFS_STORAGE_CLASS:-local-path}"
SEAWEEDFS_SIZE="${SEAWEEDFS_SIZE:-50Gi}"
SEAWEEDFS_CHART_VERSION="${SEAWEEDFS_CHART_VERSION:-4.51.0}"

# ── Argument parsing ──────────────────────────────────────────
[[ $# -eq 0 ]] && { usage; exit 1; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --seaweedfs)          INSTALL_SEAWEEDFS=true;    shift ;;
    --medusa)             INSTALL_MEDUSA=true;       shift ;;
    --test-backup)        TEST_BACKUP=true;          shift ;;
    --medusa-bucket)      MEDUSA_BUCKET="$2";        shift 2 ;;
    --medusa-access-key)  MEDUSA_ACCESS_KEY="$2";    shift 2 ;;
    --medusa-secret-key)  MEDUSA_SECRET_KEY="$2";    shift 2 ;;
    --medusa-region)      MEDUSA_REGION="$2";        shift 2 ;;
    --medusa-credentials-type) MEDUSA_CREDENTIALS_TYPE="$2"; shift 2 ;;
    --medusa-provider)    MEDUSA_PROVIDER="$2";      shift 2 ;;
    --medusa-host)        MEDUSA_HOST="$2";          shift 2 ;;
    --medusa-port)        MEDUSA_PORT="$2";          shift 2 ;;
    --medusa-secure)      MEDUSA_SECURE="$2";        shift 2 ;;
    --medusa-ssl-verify)  MEDUSA_SSL_VERIFY="$2";    shift 2 ;;
    --cluster-name)       CLUSTER_NAME="$2";         shift 2 ;;
    --namespace)          NAMESPACE="$2";            shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) error "Unknown argument: $1  (see --help)" ;;
  esac
done
# ── SeaweedFS: Medusa settings are derived from it (keys are read after install) ──
SEAWEEDFS_S3_HOST="seaweedfs-all-in-one.${SEAWEEDFS_NAMESPACE}.svc.cluster.local"
if [[ "$INSTALL_SEAWEEDFS" == "true" ]]; then
  MEDUSA_BUCKET="${MEDUSA_BUCKET:-cassandra-backups}"
  [[ "$MEDUSA_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || error "Bucket name '${MEDUSA_BUCKET}' is not a valid S3 bucket name."
  if [[ "$INSTALL_MEDUSA" == "true" ]]; then
    if [[ -n "$MEDUSA_HOST" && "$MEDUSA_HOST" != "$SEAWEEDFS_S3_HOST" ]]; then
      error "--seaweedfs sets the Medusa endpoint itself — drop --medusa-host (${MEDUSA_HOST})."
    fi
    MEDUSA_PROVIDER=s3_compatible
    MEDUSA_HOST="$SEAWEEDFS_S3_HOST"
    MEDUSA_PORT=8333
    MEDUSA_SECURE=false
    MEDUSA_CREDENTIALS_TYPE=credential-based
    MEDUSA_ACCESS_KEY="__from_seaweedfs__"   # replaced with the real keys after install
    MEDUSA_SECRET_KEY="__from_seaweedfs__"
  fi
fi

# ── Prompt for Medusa S3 details if missing ────────────────────
# Prompts only when a human is at the terminal; unattended runs fail fast instead of hanging.
if [[ "$INSTALL_MEDUSA" == "true" ]]; then
  [[ "$MEDUSA_CREDENTIALS_TYPE" =~ ^(credential-based|role-based)$ ]] || \
    error "--medusa-credentials-type must be credential-based or role-based."
  [[ "$MEDUSA_PROVIDER" =~ ^(s3|s3_compatible|s3_rgw)$ ]] || \
    error "--medusa-provider must be s3, s3_compatible or s3_rgw."
  [[ "$MEDUSA_SECURE" =~ ^(true|false)$ && "$MEDUSA_SSL_VERIFY" =~ ^(true|false)$ ]] || \
    error "--medusa-secure and --medusa-ssl-verify must be true or false."
  if [[ "$MEDUSA_PROVIDER" != "s3" ]]; then
    [[ -n "$MEDUSA_HOST" ]] || error "--medusa-provider ${MEDUSA_PROVIDER} needs --medusa-host (endpoint host, no http://)."
    [[ "$MEDUSA_HOST" != *://* ]] || error "--medusa-host must be a host name or IP only, without http:// or https://"
    [[ -z "$MEDUSA_PORT" || "$MEDUSA_PORT" =~ ^[0-9]+$ ]] || error "--medusa-port must be a number."
    [[ "$MEDUSA_CREDENTIALS_TYPE" == "credential-based" ]] || \
      error "role-based credentials only work with AWS S3 — use access/secret keys for ${MEDUSA_PROVIDER}."
  fi
  [[ -z "$MEDUSA_MAX_BACKUP_COUNT" || "$MEDUSA_MAX_BACKUP_COUNT" =~ ^[0-9]+$ ]] || error "MEDUSA_MAX_BACKUP_COUNT must be a number."
  ask() { [[ -t 0 ]] || error "$1 is not set (set it via environment/config — running non-interactively)."; }
  if [[ -z "$MEDUSA_BUCKET" ]]; then
    ask MEDUSA_BUCKET; read -rp "Enter S3 bucket name for Medusa backups: " MEDUSA_BUCKET
  fi
  if [[ "$MEDUSA_CREDENTIALS_TYPE" == "credential-based" ]]; then
    if [[ -z "$MEDUSA_ACCESS_KEY" ]]; then
      ask MEDUSA_ACCESS_KEY; read -rp "Enter S3 access key ID: " MEDUSA_ACCESS_KEY
    fi
    if [[ -z "$MEDUSA_SECRET_KEY" ]]; then
      ask MEDUSA_SECRET_KEY; read -rsp "Enter S3 secret access key: " MEDUSA_SECRET_KEY; echo ""
    fi
  fi
fi

command -v kubectl &>/dev/null || error "kubectl not found."
command -v helm &>/dev/null    || error "helm not found."
kubectl cluster-info &>/dev/null || error "Cannot reach Kubernetes cluster. Check KUBECONFIG."
kubectl get k8ssandracluster "$CLUSTER_NAME" -n "$NAMESPACE" &>/dev/null || \
  error "K8ssandraCluster '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'."

# ════════════════════════════════════════════════════════════════
# STEP 1 — SEAWEEDFS (in-cluster S3-compatible object store)
# Single "all-in-one" pod (master + volume + filer + S3 gateway) on a PVC.
# Good for labs and small clusters; for production use AWS S3 or Ceph (Rook).
# ════════════════════════════════════════════════════════════════
install_seaweedfs() {
  header "STEP 1: SeaweedFS — in-cluster S3 storage"

  kubectl get storageclass "$SEAWEEDFS_STORAGE_CLASS" &>/dev/null || \
    error "StorageClass '${SEAWEEDFS_STORAGE_CLASS}' not found — set SEAWEEDFS_STORAGE_CLASS."

  info "Adding seaweedfs Helm repo..."
  helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm --force-update > /dev/null
  helm repo update seaweedfs > /dev/null

  cat > /tmp/seaweedfs-values.yaml <<EOF_SW
# All-in-one mode: turn the separate components off, or they are deployed too
master:
  enabled: false
volume:
  enabled: false
filer:
  enabled: false
allInOne:
  enabled: true
  s3:
    enabled: true
    enableAuth: true            # access/secret keys generated into secret seaweedfs-s3-secret
    createBuckets:
      - name: ${MEDUSA_BUCKET}
  data:
    type: persistentVolumeClaim
    storageClass: ${SEAWEEDFS_STORAGE_CLASS}
    size: ${SEAWEEDFS_SIZE}
EOF_SW

  info "Installing SeaweedFS chart ${SEAWEEDFS_CHART_VERSION} in namespace ${SEAWEEDFS_NAMESPACE} (${SEAWEEDFS_SIZE} on ${SEAWEEDFS_STORAGE_CLASS})..."
  helm upgrade --install seaweedfs seaweedfs/seaweedfs \
    --version "$SEAWEEDFS_CHART_VERSION" \
    -n "$SEAWEEDFS_NAMESPACE" --create-namespace \
    -f /tmp/seaweedfs-values.yaml \
    --wait --timeout 10m > /dev/null || \
    error "SeaweedFS install failed. Check: kubectl -n ${SEAWEEDFS_NAMESPACE} get pods,pvc,jobs"
  success "SeaweedFS running; bucket '${MEDUSA_BUCKET}' created."

  local ak sk
  ak=$(kubectl get secret seaweedfs-s3-secret -n "$SEAWEEDFS_NAMESPACE" -o jsonpath='{.data.admin_access_key_id}' | base64 -d)
  sk=$(kubectl get secret seaweedfs-s3-secret -n "$SEAWEEDFS_NAMESPACE" -o jsonpath='{.data.admin_secret_access_key}' | base64 -d)
  [[ -n "$ak" && -n "$sk" ]] || error "Could not read keys from secret seaweedfs-s3-secret in ${SEAWEEDFS_NAMESPACE}."
  if [[ "$INSTALL_MEDUSA" == "true" ]]; then
    MEDUSA_ACCESS_KEY="$ak"
    MEDUSA_SECRET_KEY="$sk"
  fi

  echo ""
  echo -e "${YELLOW}  S3 endpoint    :${NC} http://${SEAWEEDFS_S3_HOST}:8333  (inside the cluster)"
  echo -e "${YELLOW}  Bucket         :${NC} ${MEDUSA_BUCKET}"
  echo -e "${YELLOW}  Access key     :${NC} kubectl get secret seaweedfs-s3-secret -n ${SEAWEEDFS_NAMESPACE} -o jsonpath='{.data.admin_access_key_id}' | base64 -d"
  echo -e "${YELLOW}  Secret key     :${NC} kubectl get secret seaweedfs-s3-secret -n ${SEAWEEDFS_NAMESPACE} -o jsonpath='{.data.admin_secret_access_key}' | base64 -d"
  echo ""
}

# ════════════════════════════════════════════════════════════════
# STEP 2 — MEDUSA
# ════════════════════════════════════════════════════════════════
install_medusa() {
  header "STEP 2: Medusa — backup & restore (${MEDUSA_PROVIDER})"

  # ── Check the S3-compatible endpoint is reachable from inside the cluster ──
  if [[ "$MEDUSA_PROVIDER" != "s3" ]]; then
    local scheme=http url code
    [[ "$MEDUSA_SECURE" == "true" ]] && scheme=https
    url="${scheme}://${MEDUSA_HOST}${MEDUSA_PORT:+:$MEDUSA_PORT}/"
    info "Checking ${url} is reachable from the cluster..."
    code=$(kubectl run "medusa-endpoint-check-$$" -n "$NAMESPACE" --rm -i --restart=Never --quiet \
             --image=curlimages/curl:8.10.1 --command -- \
             curl -sk -m 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
      success "Endpoint answered (HTTP ${code})."
    else
      warn "Could not reach ${url} from inside the cluster (got '${code:-nothing}')."
      warn "Check the host/port, --medusa-secure, and security groups/firewall between the nodes and the storage."
    fi
  fi

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
  local extra=""
  if [[ "$MEDUSA_PROVIDER" != "s3" ]]; then
    extra+=", \"host\": \"${MEDUSA_HOST}\", \"sslVerify\": ${MEDUSA_SSL_VERIFY}"
    [[ -n "$MEDUSA_PORT" ]] && extra+=", \"port\": ${MEDUSA_PORT}"
  fi
  [[ -n "$MEDUSA_MAX_BACKUP_COUNT" ]] && extra+=", \"maxBackupCount\": ${MEDUSA_MAX_BACKUP_COUNT}"
  info "Adding Medusa to K8ssandraCluster spec..."
  kubectl patch k8ssandracluster "$CLUSTER_NAME" \
    -n "$NAMESPACE" \
    --type=merge \
    -p "{
      \"spec\": {
        \"medusa\": {
          \"storageProperties\": {
            \"storageProvider\": \"${MEDUSA_PROVIDER}\",
            \"credentialsType\": \"${MEDUSA_CREDENTIALS_TYPE}\",
            \"storageSecretRef\": ${secret_ref},
            \"bucketName\": \"${MEDUSA_BUCKET}\",
            \"prefix\": \"${CLUSTER_NAME}\",
            \"region\": \"${MEDUSA_REGION}\",
            \"secure\": ${MEDUSA_SECURE}${extra}
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
  if [[ "$MEDUSA_PROVIDER" == "s3" ]]; then
    echo -e "${YELLOW}  Storage        :${NC} AWS S3 (${MEDUSA_REGION})"
  else
    echo -e "${YELLOW}  Storage        :${NC} ${MEDUSA_PROVIDER} at $( [[ "$MEDUSA_SECURE" == "true" ]] && echo https || echo http )://${MEDUSA_HOST}${MEDUSA_PORT:+:$MEDUSA_PORT}"
  fi
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

# Wait until every Cassandra pod runs the medusa container and is fully ready
wait_for_medusa_rollout() {
  info "Waiting for Cassandra pods to restart with the Medusa container (up to 30 min)..."
  local deadline=$((SECONDS + 1800)) total with_medusa ready_all
  while (( SECONDS < deadline )); do
    total=0; with_medusa=0; ready_all=0
    # one line per pod: "<container names>|<ready flags>"
    while IFS='|' read -r containers readies; do
      [[ -z "$containers" ]] && continue
      total=$((total + 1))
      [[ " $containers " == *" medusa "* ]] && with_medusa=$((with_medusa + 1))
      [[ -n "$readies" && "$readies" != *false* ]] && ready_all=$((ready_all + 1))
    done < <(kubectl get pods -n "$NAMESPACE" -l "cassandra.datastax.com/cluster=${CLUSTER_NAME}" \
               -o jsonpath='{range .items[*]}{.spec.containers[*].name}{"|"}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null || true)
    if (( total > 0 && with_medusa == total && ready_all == total )); then
      success "All ${total} Cassandra pod(s) running with Medusa."
      return 0
    fi
    info "  ${with_medusa}/${total} pods have Medusa, ${ready_all}/${total} fully ready..."
    sleep 30
  done
  warn "Cassandra pods not all ready with Medusa after 30 min. Check: kubectl get pods -n ${NAMESPACE}"
  return 1
}

# Run one backup on the first DC and wait for it
run_test_backup() {
  header "STEP 3: Test backup"
  local dc job deadline finish failed
  dc=$(kubectl get k8ssandracluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.cassandra.datacenters[0].metadata.name}')
  kubectl get k8ssandracluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.medusa}' | grep -q storageProperties || \
    error "Medusa is not enabled on ${CLUSTER_NAME} — run with --medusa first."
  job="test-backup-$(date +%Y%m%d-%H%M%S)"
  kubectl apply -n "$NAMESPACE" -f - > /dev/null <<EOF_JOB
apiVersion: medusa.k8ssandra.io/v1alpha1
kind: MedusaBackupJob
metadata:
  name: ${job}
spec:
  cassandraDatacenter: ${dc}
EOF_JOB
  info "Started MedusaBackupJob '${job}' on ${dc}; waiting up to 20 min..."
  deadline=$((SECONDS + 1200))
  while (( SECONDS < deadline )); do
    finish=$(kubectl get medusabackupjob "$job" -n "$NAMESPACE" -o jsonpath='{.status.finishTime}' 2>/dev/null || true)
    failed=$(kubectl get medusabackupjob "$job" -n "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    if [[ -n "$finish" ]]; then
      if [[ -n "$failed" && "$failed" != "[]" ]]; then
        error "Backup '${job}' finished with failures on: ${failed}. Check: kubectl logs <cassandra-pod> -c medusa -n ${NAMESPACE}"
      fi
      success "Backup '${job}' completed at ${finish}."
      kubectl get medusabackup -n "$NAMESPACE"
      return 0
    fi
    sleep 15
  done
  error "Backup '${job}' did not finish in 20 min. Check: kubectl describe medusabackupjob ${job} -n ${NAMESPACE}"
}

# ════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════
header "K8ssandra Backup Setup"
info "Cluster   : $CLUSTER_NAME (ns: $NAMESPACE)"
info "Steps     : SeaweedFS=$INSTALL_SEAWEEDFS | Medusa=$INSTALL_MEDUSA | Test backup=$TEST_BACKUP"

if [[ "$INSTALL_SEAWEEDFS" == "true" ]]; then install_seaweedfs; fi
if [[ "$INSTALL_MEDUSA" == "true" ]]; then
  install_medusa
  wait_for_medusa_rollout || true
fi
if [[ "$TEST_BACKUP" == "true" ]]; then run_test_backup; fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} BACKUP SETUP DONE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
