#!/bin/bash
# ============================================================
# k8s-k8ssandra-setup.sh
# Combined Kubernetes + K8ssandra installer for EC2 (Linux)
#
# Usage:
#   Control plane (Node 1):
#     sudo bash k8s-k8ssandra-setup.sh --role control-plane
#
#   Worker nodes (Nodes 2, 3, 4):
#     sudo bash k8s-k8ssandra-setup.sh --role worker \
#       --join-command "kubeadm join <ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
#
# Requirements:
#   - Amazon Linux 2 or Ubuntu 20.04/22.04
#   - Run as root or with sudo
#   - All nodes in the same VPC / security group
# ============================================================

set -euo pipefail

# ──────────────────────────────────────────────
# CONFIGURATION — edit these if needed
# ──────────────────────────────────────────────
K8S_VERSION="1.29"
POD_CIDR="192.168.0.0/16"          # Calico default
CALICO_VERSION="v3.27.0"
CERT_MANAGER_VERSION="v1.13.0"
CASSANDRA_STORAGE="20Gi"
CASSANDRA_SERVER_VERSION="4.1.3"
CASSANDRA_DC_SIZE=3                 # number of Cassandra nodes (workers)
LOCAL_PATH_PROVISIONER_VERSION="v0.0.26"
# ──────────────────────────────────────────────

# ── Colour helpers ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Parse arguments ──
ROLE=""
JOIN_COMMAND=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --role)           ROLE="$2";         shift 2 ;;
    --join-command)   JOIN_COMMAND="$2"; shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "$ROLE" ]] && error "Missing --role. Use: --role control-plane  OR  --role worker"
[[ "$ROLE" != "control-plane" && "$ROLE" != "worker" ]] && \
  error "--role must be 'control-plane' or 'worker'"
[[ "$ROLE" == "worker" && -z "$JOIN_COMMAND" ]] && \
  error "Worker nodes require --join-command. Get it from the control plane output."

# ── Must run as root ──
[[ "$EUID" -ne 0 ]] && error "Please run with sudo or as root."

# ── Detect OS ──
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS=$ID
else
  error "Cannot detect OS (/etc/os-release not found)."
fi
[[ "$OS" != "amzn" && "$OS" != "ubuntu" ]] && \
  error "Unsupported OS: $OS. Only 'amzn' (Amazon Linux 2) and 'ubuntu' are supported."

# ════════════════════════════════════════════════════════════
# PHASE 1 — COMMON SETUP (all nodes)
# ════════════════════════════════════════════════════════════
phase1_common() {
  info "═══ PHASE 1: Common node setup (OS: $OS) ═══"

  # ── Disable swap ──
  info "Disabling swap..."
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
  success "Swap disabled."

  # ── Kernel modules ──
  info "Loading kernel modules (overlay, br_netfilter)..."
  cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter
  success "Kernel modules loaded."

  # ── sysctl ──
  info "Applying sysctl settings..."
  cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system > /dev/null
  success "sysctl settings applied."

  # ── Install containerd ──
  info "Installing containerd..."
  if [[ "$OS" == "amzn" ]]; then
    yum install -y containerd > /dev/null
  elif [[ "$OS" == "ubuntu" ]]; then
    apt-get update -y > /dev/null
    apt-get install -y ca-certificates curl gnupg lsb-release > /dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y > /dev/null
    apt-get install -y containerd.io > /dev/null
  fi

  # ── Configure containerd ──
  info "Configuring containerd (SystemdCgroup=true)..."
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml > /dev/null
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  systemctl enable containerd
  success "containerd configured and started."

  # ── Install kubeadm / kubelet / kubectl ──
  info "Installing Kubernetes v${K8S_VERSION} components..."
  if [[ "$OS" == "amzn" ]]; then
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
    yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes > /dev/null
    systemctl enable --now kubelet
  elif [[ "$OS" == "ubuntu" ]]; then
    apt-get install -y apt-transport-https curl > /dev/null
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
      | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
    apt-get update -y > /dev/null
    apt-get install -y kubelet kubeadm kubectl > /dev/null
    apt-mark hold kubelet kubeadm kubectl
    systemctl enable --now kubelet
  fi
  success "Kubernetes v${K8S_VERSION} components installed."
}

# ════════════════════════════════════════════════════════════
# PHASE 2a — CONTROL PLANE INIT
# ════════════════════════════════════════════════════════════
phase2_control_plane() {
  info "═══ PHASE 2: Initialising control plane ═══"

  CONTROL_PLANE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
  info "Control plane IP: $CONTROL_PLANE_IP"
  info "Pod network CIDR: $POD_CIDR"

  # ── kubeadm init ──
  info "Running kubeadm init (this may take ~2 minutes)..."
  kubeadm init \
    --apiserver-advertise-address="$CONTROL_PLANE_IP" \
    --pod-network-cidr="$POD_CIDR" \
    --cri-socket unix:///var/run/containerd/containerd.sock \
    2>&1 | tee /var/log/kubeadm-init.log
  success "kubeadm init complete."

  # ── Configure kubectl ──
  info "Configuring kubectl..."
  export KUBECONFIG=/etc/kubernetes/admin.conf
  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config

  for USER_HOME in /home/ec2-user /home/ubuntu; do
    if [[ -d "$USER_HOME" ]]; then
      mkdir -p "$USER_HOME/.kube"
      cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
      chown -R "$(stat -c '%u:%g' "$USER_HOME")" "$USER_HOME/.kube"
      success "kubectl configured for $(basename "$USER_HOME")."
    fi
  done

  # ── Install Calico CNI ──
  info "Installing Calico CNI ${CALICO_VERSION}..."
  kubectl apply -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  success "Calico CNI installed."

  # ── Wait for control plane ready ──
  info "Waiting for control plane node to be Ready (up to 3 min)..."
  kubectl wait --for=condition=Ready node --all --timeout=180s || \
    warn "Node not Ready yet — it may still be coming up. Check: kubectl get nodes"

  # ── Print join command ──
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} CONTROL PLANE SETUP COMPLETE${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}▶ Run the following command on each WORKER node (Nodes 2, 3, 4):${NC}"
  echo ""
  echo -e "${CYAN}  sudo bash k8s-k8ssandra-setup.sh --role worker --join-command \"$(kubeadm token create --print-join-command)\"${NC}"
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"

  # ── Save join command to file for convenience ──
  JOIN_CMD=$(kubeadm token create --print-join-command)
  echo "sudo bash k8s-k8ssandra-setup.sh --role worker --join-command \"$JOIN_CMD\"" \
    > /root/worker-join-command.sh
  chmod +x /root/worker-join-command.sh
  success "Join command saved to /root/worker-join-command.sh"
}

# ════════════════════════════════════════════════════════════
# PHASE 2b — WORKER JOIN
# ════════════════════════════════════════════════════════════
phase2_worker() {
  info "═══ PHASE 2: Joining cluster as worker node ═══"
  info "Executing join command..."
  eval "$JOIN_COMMAND"
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} WORKER NODE $(hostname) JOINED SUCCESSFULLY${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW} Verify on control plane:  kubectl get nodes${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

# ════════════════════════════════════════════════════════════
# PHASE 3 — K8SSANDRA INSTALL (control plane only)
# ════════════════════════════════════════════════════════════
phase3_k8ssandra() {
  info "═══ PHASE 3: Installing K8ssandra ═══"
  export KUBECONFIG=/etc/kubernetes/admin.conf

  # ── Install Helm ──
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash > /dev/null
  success "Helm installed: $(helm version --short)"

  # ── Install local-path-provisioner (no EBS/IAM required) ──
  info "Installing local-path-provisioner ${LOCAL_PATH_PROVISIONER_VERSION}..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-service-account
  namespace: local-path-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumeclaims", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["endpoints", "persistentvolumes", "pods"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-path-provisioner
  template:
    metadata:
      labels:
        app: local-path-provisioner
    spec:
      serviceAccountName: local-path-provisioner-service-account
      containers:
        - name: local-path-provisioner
          image: rancher/local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}
          imagePullPolicy: IfNotPresent
          command:
            - local-path-provisioner
            - --debug
            - start
            - --config
            - /etc/config/config.json
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config/
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
      volumes:
        - name: config-volume
          configMap:
            name: local-path-config
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |-
    {
      "nodePathMap": [
        {
          "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths": ["/opt/local-path-provisioner"]
        }
      ]
    }
  setup: |-
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |-
    #!/bin/sh
    set -eu
    rm -rf "$VOL_DIR"
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
        - name: helper-pod
          image: busybox
          imagePullPolicy: IfNotPresent
EOF

  info "Waiting for local-path-provisioner to be ready..."
  kubectl rollout status deployment/local-path-provisioner \
    -n local-path-storage --timeout=60s
  success "local-path-provisioner is ready."

  # ── Ensure /opt/local-path-provisioner exists on all nodes ──
  info "Ensuring storage directory exists on all nodes..."
  for NODE in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    kubectl debug node/"$NODE" -it --image=busybox -- \
      chroot /host mkdir -p /opt/local-path-provisioner 2>/dev/null || true
  done
  success "Storage directories ready on all nodes."

  # ── Add K8ssandra Helm repo ──
  info "Adding K8ssandra Helm repository..."
  helm repo add k8ssandra https://helm.k8ssandra.io/stable > /dev/null
  helm repo update > /dev/null
  success "K8ssandra repo added."

  # ── Install cert-manager ──
  info "Installing cert-manager ${CERT_MANAGER_VERSION} (K8ssandra dependency)..."
  kubectl apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
    > /dev/null
  info "Waiting for cert-manager pods to be ready (up to 2 min)..."
  kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=120s
  success "cert-manager is ready."

  # ── Install K8ssandra Operator ──
  info "Installing K8ssandra Operator..."
  helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
    --namespace k8ssandra-operator \
    --create-namespace \
    --wait
  success "K8ssandra Operator installed."

  # ── Deploy Cassandra Cluster with local-path storage ──
  info "Deploying Cassandra cluster (${CASSANDRA_DC_SIZE} nodes, Cassandra ${CASSANDRA_SERVER_VERSION})..."
  kubectl apply -f - <<EOF
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: cassandra-cluster
  namespace: k8ssandra-operator
spec:
  cassandra:
    serverVersion: "${CASSANDRA_SERVER_VERSION}"
    datacenters:
      - metadata:
          name: dc1
        size: ${CASSANDRA_DC_SIZE}
        storageConfig:
          cassandraDataVolumeClaimSpec:
            storageClassName: local-path
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: ${CASSANDRA_STORAGE}
        config:
          jvmOptions:
            heapSize: 2048M
EOF
  success "Cassandra cluster manifest applied."

  # ── Final verification ──
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} K8SSANDRA SETUP COMPLETE${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
  echo ""
  info "Cluster node status:"
  kubectl get nodes -o wide
  echo ""
  info "StorageClass:"
  kubectl get storageclass
  echo ""
  info "K8ssandra pods (may take 5–10 min to fully start):"
  kubectl get pods -n k8ssandra-operator
  echo ""
  echo -e "${YELLOW}▶ Monitor Cassandra startup:${NC}"
  echo -e "  kubectl get k8ssandracluster -n k8ssandra-operator -w"
  echo ""
  echo -e "${YELLOW}▶ Monitor PVC binding:${NC}"
  echo -e "  kubectl get pvc -n k8ssandra-operator -w"
  echo ""
  echo -e "${YELLOW}▶ Get Cassandra credentials:${NC}"
  echo -e "  kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator -o jsonpath='{.data.username}' | base64 -d"
  echo -e "  kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator -o jsonpath='{.data.password}' | base64 -d"
  echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

# ════════════════════════════════════════════════════════════
# MAIN — orchestrate phases based on role
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN} Kubernetes ${K8S_VERSION} + K8ssandra Installer${NC}"
echo -e "${CYAN} Role: ${ROLE} | Host: $(hostname)${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

phase1_common

if [[ "$ROLE" == "control-plane" ]]; then
  phase2_control_plane
  phase3_k8ssandra
elif [[ "$ROLE" == "worker" ]]; then
  phase2_worker
fi
