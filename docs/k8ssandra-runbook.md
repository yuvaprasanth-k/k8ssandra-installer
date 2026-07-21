# Runbook: Kubernetes + K8ssandra on AWS EC2

**Version:** 1.2
**Last Updated:** 2025
**Author:** Platform Engineering
**Scripts:** `k8s-k8ssandra-setup.sh`, `local-path-provisioner.yaml`, `k8ssandra-addons-setup.sh`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [EC2 Security Group Rules](#4-ec2-security-group-rules)
5. [Component Versions](#5-component-versions)
6. [Installation Steps](#6-installation-steps)
7. [Verification](#7-verification)
8. [Accessing Cassandra](#8-accessing-cassandra)
9. [Configuration Reference](#9-configuration-reference)
10. [Common Operations](#10-common-operations)
11. [Troubleshooting](#11-troubleshooting)
12. [Rollback / Teardown](#12-rollback--teardown)
13. [Addons — Monitoring, Reaper, Medusa](#13-addons--monitoring-reaper-and-medusa)
14. [Storage — local-path-provisioner](#14-storage--local-path-provisioner)

---

## 1. Overview

This runbook covers the end-to-end installation of a **Kubernetes cluster** and **K8ssandra (Apache Cassandra)** on 4 AWS EC2 Linux instances using a single automated script: `k8s-k8ssandra-setup.sh`.

| Component | Purpose |
|---|---|
| **Kubernetes v1.29** | Container orchestration platform |
| **containerd** | Container runtime |
| **Calico CNI** | Pod networking |
| **Helm** | Kubernetes package manager |
| **cert-manager** | TLS certificate management (K8ssandra dependency) |
| **K8ssandra Operator** | Manages Cassandra lifecycle on Kubernetes |
| **Apache Cassandra 4.1.3** | Distributed NoSQL database |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    AWS VPC / Subnet                      │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Node 1 — Control Plane (t3.large minimum)       │   │
│  │  • kube-apiserver  • kube-scheduler              │   │
│  │  • kube-controller-manager  • etcd               │   │
│  │  • K8ssandra Operator  • cert-manager            │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────┐ ┌─────────────────┐ ┌──────────┐  │
│  │  Node 2 — Worker│ │  Node 3 — Worker│ │  Node 4  │  │
│  │  Cassandra Pod  │ │  Cassandra Pod  │ │  Worker  │  │
│  │  (dc1 node 1)   │ │  (dc1 node 2)   │ │  Cass.   │  │
│  └─────────────────┘ └─────────────────┘ └──────────┘  │
│                                                         │
│           ◄──── Calico CNI Pod Network ────►            │
│                  192.168.0.0/16                         │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Prerequisites

### EC2 Instance Requirements

| Item | Minimum | Recommended |
|---|---|---|
| **Count** | 4 instances | 4 instances |
| **Instance type** | `t3.large` (2 vCPU / 8 GB) | `t3.xlarge` or `m5.xlarge` |
| **OS** | Amazon Linux 2 or Ubuntu 20.04/22.04 | Amazon Linux 2 |
| **Root disk** | 30 GB | 50 GB |
| **Data disk** | — | 20 GB+ local disk per worker (used by local-path-provisioner at `/opt/local-path-provisioner`) |
| **Network** | Same VPC and subnet | Same VPC and subnet |

> **Note:** Cassandra is memory-intensive. Use `t3.xlarge` (4 vCPU / 16 GB) or larger for production workloads.

### Access Requirements

- SSH access to all 4 instances
- `sudo` or root privileges on all instances
- Outbound internet access (to pull packages and container images)
- All 4 nodes must be able to communicate with each other on private IPs

### Script Setup

Copy `k8s-k8ssandra-setup.sh` to all 4 EC2 instances and make it executable:

```bash
chmod +x k8s-k8ssandra-setup.sh
```

---

## 4. EC2 Security Group Rules

Create or update the security group used by all 4 instances with the following **inbound rules**:

| Port / Range | Protocol | Source | Purpose |
|---|---|---|---|
| `22` | TCP | Your IP | SSH access |
| `6443` | TCP | VPC CIDR | Kubernetes API server |
| `2379–2380` | TCP | VPC CIDR | etcd peer communication |
| `10250` | TCP | VPC CIDR | kubelet API |
| `10255` | TCP | VPC CIDR | kubelet read-only |
| `30000–32767` | TCP | 0.0.0.0/0 | Kubernetes NodePort services |
| `4789` | UDP | VPC CIDR | Calico VXLAN (pod networking) |
| `179` | TCP | VPC CIDR | Calico BGP |
| `9042` | TCP | VPC CIDR | Cassandra CQL (native transport) |
| `7000` | TCP | VPC CIDR | Cassandra inter-node communication |
| `7001` | TCP | VPC CIDR | Cassandra inter-node TLS |

> Replace `VPC CIDR` with your actual VPC CIDR, e.g. `10.0.0.0/16`.

---

## 5. Component Versions

All versions are configured at the top of `k8s-k8ssandra-setup.sh`:

| Variable | Default Value | Component |
|---|---|---|
| `K8S_VERSION` | `1.29` | Kubernetes |
| `CALICO_VERSION` | `v3.27.0` | Calico CNI |
| `CERT_MANAGER_VERSION` | `v1.13.0` | cert-manager |
| `CASSANDRA_SERVER_VERSION` | `4.1.3` | Apache Cassandra |
| `POD_CIDR` | `192.168.0.0/16` | Pod network range |
| `CASSANDRA_STORAGE` | `20Gi` | PVC size per Cassandra node (local-path) |
| `LOCAL_PATH_PROVISIONER_VERSION` | `v0.0.26` | local-path-provisioner image version |
| `CASSANDRA_DC_SIZE` | `3` | Number of Cassandra replicas |

To change a version, edit the variable at the top of the script before running.

---

## 6. Installation Steps

> ⚠️ **Important:** Follow this order strictly. Do **not** run Node 2/3/4 before Node 1 completes.

---

### Step 1 — Run on Node 1 (Control Plane)

SSH into Node 1 and run:

```bash
sudo bash k8s-k8ssandra-setup.sh --role control-plane
```

**What this does (in order):**

| Phase | Action |
|---|---|
| Phase 1 | Disables swap, loads kernel modules, configures sysctl |
| Phase 1 | Installs `containerd` and configures `SystemdCgroup=true` |
| Phase 1 | Installs `kubeadm`, `kubelet`, `kubectl` v1.29 |
| Phase 2 | Runs `kubeadm init`, configures `kubectl` |
| Phase 2 | Installs Calico CNI for pod networking |
| Phase 2 | Prints and saves the worker join command |
| Phase 3 | Installs Helm |
| Phase 3 | Installs cert-manager |
| Phase 3 | Installs K8ssandra Operator via Helm |
| Phase 3 | Deploys the Cassandra cluster (3-node dc1) |

**Duration:** ~8–12 minutes

**Expected output at the end:**

```
[OK]    Cassandra cluster manifest applied.
[INFO]  Cluster node status:
NAME       STATUS   ROLES           AGE   VERSION
node1      Ready    control-plane   8m    v1.29.x

[INFO]  K8ssandra pods (may take 5–10 min to fully start):
NAME                                           READY   STATUS
k8ssandra-operator-xxx                         1/1     Running
```

---

### Step 2 — Copy the Join Command

After Node 1 finishes, retrieve the join command (saved automatically):

```bash
cat /root/worker-join-command.sh
```

The output looks like:

```bash
sudo bash k8s-k8ssandra-setup.sh --role worker --join-command "kubeadm join 10.0.1.50:6443 --token abc123.xyz789 --discovery-token-ca-cert-hash sha256:abcdef..."
```

> **Note:** Tokens expire after **24 hours**. If expired, regenerate on Node 1:
> ```bash
> kubeadm token create --print-join-command
> ```

---

### Step 3 — Run on Nodes 2, 3, and 4 (Workers)

SSH into each worker node and run the join command from Step 2.  
Nodes 2, 3, and 4 **can be run simultaneously** once Node 1 is complete.

```bash
sudo bash k8s-k8ssandra-setup.sh --role worker \
  --join-command "kubeadm join 10.0.1.50:6443 --token abc123.xyz789 --discovery-token-ca-cert-hash sha256:abcdef..."
```

**What this does:**

| Phase | Action |
|---|---|
| Phase 1 | Same common setup as Node 1 (swap, kernel modules, containerd, kubeadm) |
| Phase 2 | Joins the Kubernetes cluster as a worker node |

**Duration:** ~4–6 minutes per worker

**Expected output:**

```
[OK]    Kubernetes v1.29 components installed.
[INFO]  Executing join command...
This node has joined the cluster:
* Certificate signing request was sent to apiserver...
[OK]    WORKER NODE node2 JOINED SUCCESSFULLY
```

---

## 7. Verification

Run the following on **Node 1** to verify the cluster is healthy.

### 7.1 Check all nodes are Ready

```bash
kubectl get nodes -o wide
```

Expected output (all nodes `Ready`):

```
NAME    STATUS   ROLES           AGE   VERSION   INTERNAL-IP
node1   Ready    control-plane   15m   v1.29.x   10.0.1.50
node2   Ready    <none>          10m   v1.29.x   10.0.1.51
node3   Ready    <none>          10m   v1.29.x   10.0.1.52
node4   Ready    <none>          10m   v1.29.x   10.0.1.53
```

### 7.2 Check system pods

```bash
kubectl get pods -n kube-system
```

All pods should be `Running` or `Completed`.

### 7.3 Check K8ssandra pods

```bash
kubectl get pods -n k8ssandra-operator
```

### 7.4 Check Cassandra cluster status

```bash
kubectl get k8ssandracluster -n k8ssandra-operator
```

Expected output when healthy:

```
NAME                READY
cassandra-cluster   true
```

> Cassandra pods may take **5–10 minutes** to reach `Running` state after the script completes.

### 7.5 Check cluster info

```bash
kubectl cluster-info
```

---

## 8. Accessing Cassandra

### 8.1 Retrieve credentials

```bash
# Username
kubectl get secret cassandra-cluster-superuser \
  -n k8ssandra-operator \
  -o jsonpath='{.data.username}' | base64 -d

# Password
kubectl get secret cassandra-cluster-superuser \
  -n k8ssandra-operator \
  -o jsonpath='{.data.password}' | base64 -d
```

### 8.2 Connect with cqlsh (from inside the cluster)

```bash
# Get the name of a running Cassandra pod
kubectl get pods -n k8ssandra-operator | grep cassandra

# Open a shell into a Cassandra pod
kubectl exec -it cassandra-cluster-dc1-default-sts-0 \
  -n k8ssandra-operator -- cqlsh \
  -u <username> -p <password>
```

### 8.3 Connect from outside the cluster (NodePort)

```bash
# Expose Cassandra CQL port via NodePort
kubectl expose service cassandra-cluster-dc1-service \
  --type=NodePort \
  --name=cassandra-nodeport \
  --port=9042 \
  -n k8ssandra-operator

# Get assigned NodePort
kubectl get svc cassandra-nodeport -n k8ssandra-operator
```

Then connect using:
```
cqlsh <EC2-public-ip> <NodePort> -u <username> -p <password>
```

---

## 9. Configuration Reference

To customise the deployment, edit the variables at the top of `k8s-k8ssandra-setup.sh`:

```bash
K8S_VERSION="1.29"               # Kubernetes minor version
POD_CIDR="192.168.0.0/16"        # Pod network CIDR (Calico)
CALICO_VERSION="v3.27.0"         # Calico CNI version
CERT_MANAGER_VERSION="v1.13.0"   # cert-manager version
CASSANDRA_STORAGE="20Gi"         # Local-path PVC size per Cassandra node
LOCAL_PATH_PROVISIONER_VERSION="v0.0.26"
CASSANDRA_SERVER_VERSION="4.1.3" # Apache Cassandra version
CASSANDRA_DC_SIZE=3              # Number of Cassandra replicas
```

### Supported Kubernetes versions for K8ssandra

| K8ssandra Operator | Kubernetes |
|---|---|
| v1.x | 1.25 – 1.29 |
| v1.22+ | 1.27 – 1.30 |

---

## 10. Common Operations

### Scale Cassandra up (add nodes)

```bash
kubectl edit k8ssandracluster cassandra-cluster -n k8ssandra-operator
# Change: size: 3  →  size: 4
```

### Rolling restart of Cassandra

```bash
kubectl rollout restart statefulset \
  cassandra-cluster-dc1-default-sts \
  -n k8ssandra-operator
```

### View Cassandra logs

```bash
kubectl logs cassandra-cluster-dc1-default-sts-0 \
  -n k8ssandra-operator -f
```

### Check Cassandra ring status (nodetool)

```bash
kubectl exec -it cassandra-cluster-dc1-default-sts-0 \
  -n k8ssandra-operator -- nodetool status
```

### Backup with Medusa (if installed)

```bash
kubectl create job --from=cronjob/medusa-backup manual-backup \
  -n k8ssandra-operator
```

### Regenerate expired worker join token

Run on **Node 1**:

```bash
kubeadm token create --print-join-command
```

---

## 11. Troubleshooting

### Nodes stuck in `NotReady`

```bash
# Check kubelet logs on the affected node
journalctl -u kubelet -f

# Check node conditions
kubectl describe node <node-name>
```

**Common causes:**
- CNI not yet installed → wait ~2 min after control plane init
- containerd not running → `systemctl restart containerd`
- Swap not disabled → `swapoff -a`

---

### kubeadm init fails

```bash
# Review the full init log
cat /var/log/kubeadm-init.log

# Reset and retry
kubeadm reset -f
sudo bash k8s-k8ssandra-setup.sh --role control-plane
```

---

### Cassandra pods stuck in `Pending`

```bash
kubectl describe pod <cassandra-pod> -n k8ssandra-operator
```

**Common causes:**

| Symptom | Cause | Fix |
|---|---|---|
| `Insufficient memory` | Node too small | Use `t3.xlarge` or larger |
| `no persistent volumes available` | No PVC / StorageClass | Verify `local-path` StorageClass exists: `kubectl get sc` |
| `0/4 nodes available` | Taints on nodes | Untaint worker nodes |

```bash
# Check StorageClass
kubectl get storageclass

# Untaint control-plane if needed (for testing only)
kubectl taint nodes node1 node-role.kubernetes.io/control-plane:NoSchedule-
```

---

### cert-manager pods not ready

```bash
kubectl get pods -n cert-manager
kubectl describe pod <cert-manager-pod> -n cert-manager
```

Wait up to 3 minutes for cert-manager to fully initialise before K8ssandra pods start.

---

### Worker join token expired (24h)

On **Node 1**:
```bash
kubeadm token create --print-join-command
```

Use the new command with `--role worker`.

---

### Check all component health at once

```bash
kubectl get nodes && \
kubectl get pods -n kube-system && \
kubectl get pods -n cert-manager && \
kubectl get pods -n k8ssandra-operator && \
kubectl get k8ssandracluster -n k8ssandra-operator
```

---

## 12. Rollback / Teardown

### Remove Cassandra cluster only

```bash
kubectl delete k8ssandracluster cassandra-cluster -n k8ssandra-operator
```

### Uninstall K8ssandra Operator

```bash
helm uninstall k8ssandra-operator -n k8ssandra-operator
kubectl delete namespace k8ssandra-operator
```

### Uninstall cert-manager

```bash
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

### Full cluster teardown

Run on **each worker node** first:
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo ipvsadm --clear   # if ipvs is used
```

Then on **Node 1** (control plane):
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d ~/.kube /var/lib/etcd
```

---

*End of Runbook*

---

## 13. Addons — Monitoring, Reaper, and Medusa

> **Script:** [`k8ssandra-addons-setup.sh`](k8ssandra-addons-setup.sh)  
> **Run on:** Node 1 (control plane) only, after the Cassandra cluster is healthy.

---

### 13.1 Overview

| Component | Purpose | How Deployed |
|---|---|---|
| **Management API** | Enables lifecycle operations (scale, repair, config) inside each Cassandra pod | Built into `k8ssandra/cass-management-api` image — auto-deployed by the operator |
| **Prometheus** | Scrapes and stores Cassandra / Reaper metrics | Helm: `kube-prometheus-stack` |
| **Grafana** | Dashboard visualisation of Cassandra metrics | Bundled with `kube-prometheus-stack` |
| **Reaper** | Schedules and runs anti-entropy repairs | Enabled via `K8ssandraCluster` spec patch |
| **Medusa** | Backup and restore of Cassandra data to S3 | Enabled via `K8ssandraCluster` spec patch + S3 credentials secret |

> **Note:** The Management API is automatically embedded in each Cassandra pod via the `cass-management-api` container image. No separate installation is required.

---

### 13.2 Prerequisites

Before running the addons script:

- Cassandra cluster is `Ready`: `kubectl get k8ssandracluster -n k8ssandra-operator`
- All Cassandra pods are `Running`: `kubectl get pods -n k8ssandra-operator`
- For Medusa: an **S3 bucket** exists and IAM credentials with `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject` on that bucket

---

### 13.3 Usage

#### Install all components at once

```bash
chmod +x k8ssandra-addons-setup.sh
sudo bash k8ssandra-addons-setup.sh --all \
  --medusa-bucket my-cassandra-backups \
  --medusa-access-key AKIAIOSFODNN7EXAMPLE \
  --medusa-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  --medusa-region us-east-1
```

#### Install individual components

```bash
# Monitoring only
sudo bash k8ssandra-addons-setup.sh --monitoring

# Reaper only
sudo bash k8ssandra-addons-setup.sh --reaper

# Medusa only
sudo bash k8ssandra-addons-setup.sh --medusa \
  --medusa-bucket my-cassandra-backups \
  --medusa-access-key AKIAIOSFODNN7EXAMPLE \
  --medusa-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Custom cluster name or namespace
sudo bash k8ssandra-addons-setup.sh --all \
  --cluster-name my-cluster \
  --namespace my-namespace
```

---

### 13.4 Component A — Management API

The **Cassandra Management API** is automatically embedded in every Cassandra pod by the K8ssandra Operator. It runs as a sidecar container (`server-system-logger`) and exposes a REST API on port `8080` that the operator uses for all lifecycle operations.

**Verify it is running:**

```bash
# Each Cassandra pod should show 3/3 READY containers
kubectl get pods -n k8ssandra-operator

# Check Management API health directly in a pod
kubectl exec -it cassandra-cluster-dc1-default-sts-0 \
  -n k8ssandra-operator \
  -c cassandra \
  -- curl -s http://localhost:8080/api/v0/probes/liveness
```

Expected response: `OK`

**Management API capabilities:**

| Operation | Command |
|---|---|
| Node liveness | `curl http://localhost:8080/api/v0/probes/liveness` |
| Node readiness | `curl http://localhost:8080/api/v0/probes/readiness` |
| List keyspaces | `curl http://localhost:8080/api/v0/ops/keyspaces` |
| Flush data | `curl -X POST http://localhost:8080/api/v0/ops/tables/flush` |
| Trigger repair | `curl -X POST http://localhost:8080/api/v0/ops/node/repair` |

---

### 13.5 Component B — Monitoring (Prometheus + Grafana)

The script installs the `kube-prometheus-stack` and enables `ServiceMonitor` resources for Cassandra, Reaper, and Stargate.

**Architecture:**

```
Cassandra pods ──► ServiceMonitor ──► Prometheus ──► Grafana Dashboards
Reaper pods    ──► ServiceMonitor ──┘
```

**Access Grafana:**

```bash
# Option 1: NodePort (port 32000 — set by the script)
http://<any-ec2-public-ip>:32000
Username: admin
Password: K8ssandraAdmin!

# Option 2: Port-forward (from your laptop)
kubectl port-forward svc/prometheus-grafana 3000:80 -n k8ssandra-operator
# Then open: http://localhost:3000
```

**Access Prometheus:**

```bash
kubectl port-forward svc/prometheus-grafana-kube-pr-prometheus 9090:9090 -n k8ssandra-operator
# Then open: http://localhost:9090
```

**Verify ServiceMonitors are created:**

```bash
kubectl get servicemonitor -n k8ssandra-operator
```

Expected monitors:
- `cassandra-cluster-dc1-cass-servicemonitor`
- `cassandra-cluster-dc1-reaper-reaper-servicemonitor`

**Key Grafana dashboards:**

| Dashboard | Panels |
|---|---|
| Cassandra Overview | Read/write latency, compaction, GC, heap |
| Cassandra Condensed | Compact single-pane cluster health |
| JVM Metrics | Heap usage, GC pause, thread count |

---

### 13.6 Component C — Reaper (Repair Scheduler)

Reaper schedules and runs anti-entropy repairs automatically. It is deployed as a pod alongside the Cassandra cluster.

**Access the Reaper Web UI:**

The addons script automatically patches the Reaper service from `ClusterIP` to `NodePort` on port `32080`.

```bash
# Get the password
kubectl get secret cassandra-cluster-reaper-ui \
  -n k8ssandra-operator \
  -o jsonpath='{.data.password}' | base64 -d

# Confirm service type and NodePort
kubectl get svc cassandra-cluster-dc1-reaper-service -n k8ssandra-operator
```

**Open in browser:**
```
http://<any-worker-node-ip>:32080/webui
```

**Patch manually if needed (e.g. after cluster recreation):**
```bash
kubectl patch svc cassandra-cluster-dc1-reaper-service \
  -n k8ssandra-operator \
  --type=json \
  -p='[
    {"op": "replace", "path": "/spec/type",                    "value": "NodePort"},
    {"op": "replace", "path": "/spec/ports/0/nodePort",        "value": 32080},
    {"op": "replace", "path": "/spec/ports/1/nodePort",        "value": 32081}
  ]'
```

**Reaper credentials:**

| Field | Value |
|---|---|
| Username | `cassandra-cluster-reaper-ui` |
| Password | Retrieved from secret above |
| NodePort (Web UI) | `32080` |
| NodePort (Admin API) | `32081` |

**Schedule a weekly repair (recommended):**

```bash
# Via UI: Schedules → Add Schedule
# - Cluster: cassandra-cluster
# - Keyspace: (your keyspace)
# - Schedule: once per week
# - Start time: off-peak hours
```

**Via kubectl (create a one-off repair):**

```yaml
apiVersion: reaper.k8ssandra.io/v1alpha1
kind: CassandraReaper
metadata:
  name: manual-repair
  namespace: k8ssandra-operator
spec:
  clusterName: cassandra-cluster
  repair:
    keyspace: system_auth
    tables: []
    repairParallelism: DATACENTER_AWARE
    intensity: "0.8"
```

```bash
kubectl apply -f repair.yaml
kubectl get cassandrareaper -n k8ssandra-operator
```

**Best practices:**

- Run a full repair **once per week** per keyspace
- Set intensity to `0.8` (leaves 20% cluster headroom)
- Schedule repairs during off-peak hours
- Reaper automatically pauses if pending compactions exceed 20

---

### 13.7 Component D — Medusa (Backup and Restore)

Medusa runs as a sidecar container in each Cassandra pod and copies SSTables to S3.

**Architecture:**

```
Cassandra pod
├── cassandra container
├── server-system-logger (Management API)
└── medusa container ──────────────────► S3 Bucket
                                          └── <cluster-name>/
                                              └── backup-20250101/
                                                  ├── node-0/
                                                  ├── node-1/
                                                  └── node-2/
```

#### Take a backup

```bash
kubectl apply -f - <<EOF
apiVersion: medusa.k8ssandra.io/v1alpha1
kind: CassandraBackup
metadata:
  name: backup-$(date +%Y%m%d-%H%M)
  namespace: k8ssandra-operator
spec:
  name: backup-$(date +%Y%m%d-%H%M)
  k8ssandraClusterRef:
    name: cassandra-cluster
    namespace: k8ssandra-operator
EOF

# Monitor backup progress
kubectl get cassandrabackup -n k8ssandra-operator -w
```

#### List available backups

```bash
kubectl get cassandrabackup -n k8ssandra-operator
```

#### Restore from a backup

```bash
kubectl apply -f - <<EOF
apiVersion: medusa.k8ssandra.io/v1alpha1
kind: CassandraRestore
metadata:
  name: restore-$(date +%Y%m%d-%H%M)
  namespace: k8ssandra-operator
spec:
  backup:
    name: backup-20250101-0000        # ← name of the backup to restore
    k8ssandraClusterRef:
      name: cassandra-cluster
      namespace: k8ssandra-operator
  k8ssandraClusterRef:
    name: cassandra-cluster
    namespace: k8ssandra-operator
EOF

# Monitor restore progress
kubectl get cassandrarestore -n k8ssandra-operator -w
```

> ⚠️ **Warning:** Restore stops and restarts Cassandra pods. Schedule during a maintenance window.

#### Schedule automated daily backups

```bash
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cassandra-daily-backup
  namespace: k8ssandra-operator
spec:
  schedule: "0 2 * * *"           # 2:00 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: k8ssandra-operator
          restartPolicy: OnFailure
          containers:
          - name: backup-trigger
            image: bitnami/kubectl:latest
            command:
            - /bin/sh
            - -c
            - |
              kubectl apply -f - <<INNEREOF
              apiVersion: medusa.k8ssandra.io/v1alpha1
              kind: CassandraBackup
              metadata:
                name: backup-\$(date +%Y%m%d)
                namespace: k8ssandra-operator
              spec:
                name: backup-\$(date +%Y%m%d)
                k8ssandraClusterRef:
                  name: cassandra-cluster
                  namespace: k8ssandra-operator
              INNEREOF
EOF
```

---

### 13.8 Addons Verification Checklist

Run after deploying all addons to confirm everything is healthy:

```bash
# 1. All pods running
kubectl get pods -n k8ssandra-operator

# 2. K8ssandraCluster reports Ready
kubectl get k8ssandracluster -n k8ssandra-operator

# 3. ServiceMonitors exist (Prometheus scraping)
kubectl get servicemonitor -n k8ssandra-operator

# 4. Reaper pod running
kubectl get pods -n k8ssandra-operator -l app.kubernetes.io/component=reaper

# 5. Medusa sidecar injected (each Cassandra pod should now show 4/4 READY)
kubectl get pods -n k8ssandra-operator -l cassandra.datastax.com/cluster=cassandra-cluster

# 6. Grafana accessible
kubectl get svc prometheus-grafana -n k8ssandra-operator

# 7. Management API healthy (run inside a Cassandra pod)
kubectl exec cassandra-cluster-dc1-default-sts-0 \
  -n k8ssandra-operator -c cassandra \
  -- curl -s http://localhost:8080/api/v0/probes/liveness
```

---

### 13.9 Additional Security Group Ports for Addons

Add these inbound rules to the EC2 security group:

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| `32000` | TCP | Your IP / VPN | Grafana NodePort |
| `32080` | TCP | Your IP / VPN | Reaper Web UI (NodePort) |
| `32081` | TCP | VPC CIDR | Reaper Admin API (NodePort) |
| `9090` | TCP | VPC CIDR | Prometheus (internal) |
| `50051` | TCP | VPC CIDR | Medusa gRPC |

*End of Section 13*

---

## 14. Storage — local-path-provisioner

> **File:** [`local-path-provisioner.yaml`](local-path-provisioner.yaml)  
> **Why:** Self-managed kubeadm clusters on EC2 have no built-in dynamic storage provisioner.  
> The `local-path-provisioner` provides one using local node disk — **no EBS CSI Driver or IAM role required**.

---

### 14.1 How it Works

```
Cassandra PVC created
        │
        ▼
local-path-provisioner (running in local-path-storage namespace)
        │
        ▼
Creates directory on the node that will run the pod:
  /opt/local-path-provisioner/<pvc-name>/
        │
        ▼
Binds PVC → Pod can schedule and start
```

- **`volumeBindingMode: WaitForFirstConsumer`** — the PV is only created once a pod is scheduled to a node, ensuring the volume is on the correct node.
- **`reclaimPolicy: Delete`** — when a PVC is deleted, the local directory is cleaned up automatically.
- Data is stored at **`/opt/local-path-provisioner/`** on each worker node's root disk.

---

### 14.2 Deploy (standalone)

```bash
# Apply the manifest directly
kubectl apply -f local-path-provisioner.yaml

# Verify provisioner is running
kubectl get pods -n local-path-storage
kubectl get storageclass
```

Expected output:
```
NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      DEFAULT
local-path   rancher.io/local-path   Delete          WaitForFirstConsumer   true
```

---

### 14.3 K8ssandraCluster with local-path

The complete working manifest to deploy Cassandra using `local-path` storage:

```yaml
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: cassandra-cluster
  namespace: k8ssandra-operator
spec:
  cassandra:
    serverVersion: "4.1.3"
    datacenters:
      - metadata:
          name: dc1
        size: 3
        storageConfig:
          cassandraDataVolumeClaimSpec:
            storageClassName: local-path
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: 20Gi
```

Apply with:
```bash
kubectl apply -f cassandra-cluster.yaml
```

---

### 14.4 Verify PVC Binding

```bash
# Watch PVCs — should go Pending → Bound once pods are scheduled
kubectl get pvc -n k8ssandra-operator -w

# Check PVs created on nodes
kubectl get pv

# See which node a PV is on
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}{end}'
```

---

### 14.5 Check Storage on Nodes

SSH into a worker node and verify data directories are being created:

```bash
ls -la /opt/local-path-provisioner/
# Should show one directory per Cassandra PVC
```

---

### 14.6 Important Limitations

| Limitation | Detail |
|---|---|
| **No replication** | Data lives on a single node's local disk — if the node is terminated, data is lost |
| **No cross-node migration** | A pod is permanently pinned to the node where its PV was created |
| **Not recommended for production** | Use EBS CSI (gp2/gp3) or EFS for production workloads where data durability is required |
| **Cassandra replication compensates** | With `replication_factor: 3`, Cassandra itself replicates data across all 3 nodes — losing one node does not lose data |

> **Recommendation:** For development/testing environments, `local-path` is ideal.  
> For production on AWS, use the **EBS CSI Driver** (`fix-pvc-ebs.sh`) with `gp3` StorageClass for durable, node-independent volumes.

---

### 14.7 Troubleshooting

**PVC stuck in `Pending` after applying local-path:**

```bash
# 1. Check provisioner is running
kubectl get pods -n local-path-storage

# 2. Check provisioner logs for errors
kubectl logs -n local-path-storage \
  deployment/local-path-provisioner --tail=50

# 3. Describe the PVC for events
kubectl describe pvc <pvc-name> -n k8ssandra-operator

# 4. Ensure the storage directory is writable on the node
# SSH into the worker node and run:
sudo mkdir -p /opt/local-path-provisioner
sudo chmod 777 /opt/local-path-provisioner
```

**`helper-pod` fails to create directory:**

```bash
# The provisioner uses a busybox helper pod — check its logs
kubectl get pods -n k8ssandra-operator | grep helper
kubectl logs <helper-pod-name> -n k8ssandra-operator
```

*End of Runbook (v1.2)*
