#!/bin/bash
# ============================================================
# fix-pvc-ebs.sh
# Fixes: 0/4 nodes available: pod has unbound PVCs
#
# Root cause: EBS CSI Driver not installed — Kubernetes cannot
# dynamically provision EBS volumes for Cassandra PVCs.
#
# What this script does:
#   1. Installs the AWS EBS CSI Driver (via Helm)
#   2. Creates/patches the gp2 StorageClass as default
#   3. Verifies PVCs bind and pods schedule
#
# Prerequisites:
#   - kubectl configured (KUBECONFIG set)
#   - Helm installed
#   - EC2 instances must have an IAM role with EBS permissions
#     (AmazonEBSCSIDriverPolicy or inline policy — see Step 0)
# ============================================================

set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN} Fix: Unbound PVCs — EBS CSI Driver Setup${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# ── Step 0: Verify IAM permissions ──────────────────────────
info "STEP 0: Checking EC2 instance IAM role for EBS permissions..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")

if [[ -n "$TOKEN" ]]; then
  IAM_ROLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || echo "")
else
  IAM_ROLE=$(curl -s \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || echo "")
fi

if [[ -z "$IAM_ROLE" ]]; then
  warn "No IAM role found on this instance."
  warn "The EBS CSI Driver REQUIRES an IAM role with EBS permissions."
  warn ""
  warn "Attach the following inline policy to your EC2 IAM role in AWS Console:"
  warn ""
  cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumeStatus",
        "ec2:DescribeInstances",
        "ec2:DescribeAvailabilityZones",
        "ec2:CreateTags",
        "ec2:DescribeTags",
        "ec2:ModifyVolume",
        "ec2:DescribeVolumesModifications",
        "ec2:DescribeSnapshots",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
        "ec2:DescribeSnapshotTierStatus"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
  warn ""
  warn "After attaching the policy, re-run this script."
  read -rp "Do you want to continue anyway? (y/N): " CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 1
else
  success "IAM role found: $IAM_ROLE"
fi

# ── Step 1: Install AWS EBS CSI Driver ──────────────────────
info "STEP 1: Installing AWS EBS CSI Driver via Helm..."

helm repo add aws-ebs-csi-driver \
  https://kubernetes-sigs.github.io/aws-ebs-csi-driver > /dev/null
helm repo update > /dev/null

# Check if already installed
if helm status aws-ebs-csi-driver -n kube-system &>/dev/null; then
  warn "EBS CSI Driver already installed. Upgrading..."
  helm upgrade aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    --namespace kube-system \
    --set enableVolumeScheduling=true \
    --set enableVolumeResizing=true \
    --set enableVolumeSnapshot=true \
    --wait
else
  helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    --namespace kube-system \
    --set enableVolumeScheduling=true \
    --set enableVolumeResizing=true \
    --set enableVolumeSnapshot=true \
    --wait
fi

success "AWS EBS CSI Driver installed."

# ── Step 2: Wait for CSI driver pods ────────────────────────
info "STEP 2: Waiting for EBS CSI Driver pods to be ready..."
kubectl rollout status deployment/ebs-csi-controller \
  -n kube-system --timeout=120s
success "EBS CSI controller is ready."

# ── Step 3: Create gp2 StorageClass (CSI-based) ─────────────
info "STEP 3: Creating gp2 StorageClass (AWS EBS gp2, CSI provisioner)..."

# Delete old non-CSI gp2 if it exists (uses kubernetes.io/aws-ebs)
if kubectl get storageclass gp2 &>/dev/null; then
  OLD_PROVISIONER=$(kubectl get storageclass gp2 \
    -o jsonpath='{.provisioner}' 2>/dev/null || echo "")
  if [[ "$OLD_PROVISIONER" == "kubernetes.io/aws-ebs" ]]; then
    warn "Found legacy in-tree gp2 StorageClass. Replacing with CSI version..."
    kubectl delete storageclass gp2
  fi
fi

kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: gp2
  fsType: ext4
  encrypted: "false"
EOF

success "gp2 StorageClass created and set as default."

# ── Step 4: Also create gp3 StorageClass (recommended) ──────
info "STEP 4: Creating gp3 StorageClass (better performance, lower cost)..."

kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: gp3
  fsType: ext4
  encrypted: "false"
  throughput: "125"
  iops: "3000"
EOF

success "gp3 StorageClass created."

# ── Step 5: Verify StorageClasses ───────────────────────────
info "STEP 5: StorageClass status:"
kubectl get storageclass
echo ""

# ── Step 6: Check current PVC status ────────────────────────
info "STEP 6: Current PVC status in k8ssandra-operator namespace:"
kubectl get pvc -n k8ssandra-operator 2>/dev/null || \
  warn "No PVCs found in k8ssandra-operator namespace yet."
echo ""

# ── Step 7: Restart Cassandra pods to trigger rescheduling ──
info "STEP 7: Restarting Cassandra StatefulSet to trigger PVC provisioning..."

SS_NAME=$(kubectl get statefulset -n k8ssandra-operator \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$SS_NAME" ]]; then
  kubectl rollout restart statefulset/"$SS_NAME" -n k8ssandra-operator
  info "Waiting for StatefulSet rollout (up to 5 min)..."
  kubectl rollout status statefulset/"$SS_NAME" \
    -n k8ssandra-operator --timeout=300s || \
    warn "Rollout still in progress. Monitor with: kubectl get pods -n k8ssandra-operator -w"
  success "StatefulSet $SS_NAME restarted."
else
  warn "No StatefulSet found in k8ssandra-operator. PVCs will bind when Cassandra pods are created."
fi

# ── Step 8: Final status ─────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} EBS CSI DRIVER SETUP COMPLETE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
info "PVC status:"
kubectl get pvc -n k8ssandra-operator 2>/dev/null || echo "  (none yet)"
echo ""
info "Pod status:"
kubectl get pods -n k8ssandra-operator 2>/dev/null || echo "  (none yet)"
echo ""
echo -e "${YELLOW}▶ Monitor PVC binding:${NC}"
echo -e "  kubectl get pvc -n k8ssandra-operator -w"
echo ""
echo -e "${YELLOW}▶ Monitor pod scheduling:${NC}"
echo -e "  kubectl get pods -n k8ssandra-operator -w"
echo ""
echo -e "${YELLOW}▶ If pods still fail, describe a failing pod:${NC}"
echo -e "  kubectl describe pod <pod-name> -n k8ssandra-operator"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
