# K8ssandra Installer

Automated installer for **Kubernetes** and **Apache Cassandra** via the **K8ssandra Operator** on AWS EC2, bare-metal / Linux VMs, or existing Kubernetes clusters.

---

## Overview

This repository provides single-command automation for:
- Provisioning a multi-node **Kubernetes (kubeadm)** cluster across EC2 instances or Linux VMs.
- Setting up CNI networking (**Calico** VXLAN overlay), dynamic local storage (**local-path-provisioner**) or AWS EBS gp3, and **cert-manager**.
- Deploying the **K8ssandra Operator** and orchestrating an **Apache Cassandra** (4.1.x / 5.0.x) cluster with anti-affinity across nodes or availability zones.
- Optional addons: **Prometheus & Grafana** metrics dashboards, **Reaper** automated repairs, and **Medusa** backup/restore (using AWS S3, S3-compatible storage, or in-cluster **SeaweedFS**).

---

## Components & Versions

| Component | Default Version | Configurable Parameter | Purpose |
|---|---|---|---|
| **Kubernetes** | `1.36` | `--k8s-version` | Container orchestration (`kubeadm`, `kubelet`, `kubectl`) |
| **containerd** | OS / Docker repo | — | Container runtime engine |
| **CNI (Calico)** | `v3.33.0` | `--cni`, `--calico-version`, `--calico-encap` | Inter-node pod networking (VXLAN / IPIP) |
| **Storage Provisioner** | `v0.0.37` | `--storage-class`, `--storage-size` | `local-path` dynamic storage or AWS `ebs-gp3` |
| **cert-manager** | `v1.21.3` | `--cert-manager-version` | TLS certificates for operator webhooks |
| **K8ssandra Operator** | `1.33.0` | `--operator-version` | Lifecycle management for Cassandra clusters |
| **Apache Cassandra** | `4.1.8` | `--cassandra-version`, `--cassandra-image` | Distributed NoSQL database (5.0.x supported) |
| **Helm** | `v3.22.1` | `--helm-version` | Package manager (installed if missing) |
| **Addons** | Latest stable | `--addons monitoring,reaper,medusa` | Monitoring, scheduled repairs, and backups |

---

## Repository Structure

```text
k8ssandra-installer/
├── scripts/
│   ├── k8s-k8ssandra-setup.sh       # Main installer supporting all roles and full automation
│   ├── k8ssandra-addons-setup.sh    # Monitoring (Prometheus/Grafana) and Reaper setup
│   ├── k8ssandra-backup-setup.sh    # SeaweedFS (in-cluster S3) & Medusa backup automation
│   ├── k8ssandra-add-dc.sh          # Helper to add new Cassandra datacenters with keyspace replication
│   └── k8ssandra-cleanup.sh         # Scoped cleanup (addons/K8ssandra only) or full cluster reset
├── manifests/
│   ├── local-path-provisioner.yaml  # Dynamic local storage provisioner manifest
│   └── cassandra-cluster.yaml       # Sample standalone K8ssandraCluster specification
├── config/
│   ├── cluster.env.example          # Environment configuration template
│   └── kube-prom-stack-values.yaml  # Prometheus and Grafana Helm values
└── docs/
    ├── k8ssandra-runbook.md         # Operational administration runbook
    └── k8ssandra-on-ec2.txt         # Architecture, prerequisites, and backup notes
```

---

## Prerequisites

1. **Instances / Virtual Machines**:
   - **Control Plane**: 1 node (minimum 2 vCPU, 4 GB RAM, 30 GB disk — e.g., `t3.medium`).
   - **Worker Nodes**: 1 node per Cassandra replica (`DC_SIZE`, default 3 nodes, minimum `t3.large`, recommended `m5.xlarge`+ for production, 50 GB+ disk).
   - **Operating System**: Ubuntu 24.04 LTS (recommended), Ubuntu 22.04 LTS, Amazon Linux 2023, or RHEL-compatible.
2. **Network & Connectivity**:
   - All nodes must reside in the same VPC/subnet with private IPs reachable from each other.
   - **SSH Access**: Control-plane node must be able to SSH to all worker nodes via key with passwordless `sudo` privileges.
3. **Security Group Ports**:
   - **Between cluster nodes**: TCP `6443` (API), TCP `2379-2380` (etcd), TCP `10250` (kubelet), UDP `4789` (Calico VXLAN), TCP `7000-7001` (Cassandra inter-node), TCP `9042` (CQL), TCP `22` (SSH).
   - **Inbound access (admin IP / VPN only)**: TCP `22` (SSH), TCP `6443` (Kubernetes API), TCP `32000` (Grafana), TCP `32080` (Reaper UI).

---

## Quick Start (One-Command Deployment)

### Step 1: Copy or Clone Repository to Control-Plane Node
Copy this repository onto your designated control-plane node.

### Step 2: Configure Environment Settings
Copy the template and edit your worker private IPs and SSH credentials:

```bash
cp config/cluster.env.example config/cluster.env
vi config/cluster.env
```

At minimum, set:
```ini
WORKERS="10.0.1.11,10.0.1.12,10.0.1.13"
SSH_USER=ec2-user
SSH_KEY=/home/ec2-user/.ssh/cluster-key.pem
```

### Step 3: Run the Automated Installer
Execute the setup script from the control-plane node:

```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role all --config config/cluster.env
```

*Or pass configuration directly via CLI flags:*
```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role all \
  --workers 10.0.1.11,10.0.1.12,10.0.1.13 \
  --ssh-user ec2-user \
  --ssh-key /home/ec2-user/.ssh/cluster-key.pem \
  --dc-size 3
```

---

## Deployment Roles

The installer supports multiple execution roles via `--role <role>`:

| Role | Target Node | Description |
|---|---|---|
| `all` | Control Plane | Prepares control plane, initializes Kubernetes, joins workers over SSH, installs storage, cert-manager, K8ssandra Operator, Cassandra cluster, and addons. |
| `control-plane` | Control Plane | Sets up Kubernetes and CNI only; optionally joins workers if `--workers` is supplied. Does not deploy K8ssandra. |
| `add-workers` | Control Plane | Joins additional worker nodes to an active cluster over SSH. |
| `worker` | Worker Node | Manually joins the local node using `--join-command "kubeadm join ..."`. |
| `k8ssandra` | Any node with `kubectl` | Deploys K8ssandra Operator and Cassandra cluster to an existing Kubernetes/EKS cluster. |

### Examples

**Scale Cluster (Add Workers):**
```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role add-workers \
  --workers 10.0.1.14,10.0.1.15 \
  --ssh-user ec2-user \
  --ssh-key /home/ec2-user/.ssh/cluster-key.pem
```

**Deploy K8ssandra onto an Existing Kubernetes Cluster:**
```bash
bash scripts/k8s-k8ssandra-setup.sh --role k8ssandra \
  --kubeconfig ~/.kube/config \
  --storage-class gp3 \
  --dc-size 3 \
  --cpu 2 \
  --memory 8Gi
```

---

## Cluster Operations

### 1. Accessing Services

- **Cassandra CQL**:
  ```bash
  # Retrieve superuser credentials
  kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator -o jsonpath='{.data.username}' | base64 -d; echo
  kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator -o jsonpath='{.data.password}' | base64 -d; echo

  # Connect to CQL shell
  kubectl exec -it cassandra-cluster-dc1-default-sts-0 -n k8ssandra-operator -c cassandra -- cqlsh -u <username> -p <password>
  ```

- **Grafana Dashboard**:
  - **URL**: `http://<node-ip>:32000`
  - **Username**: `admin`
  - **Password**:
    ```bash
    kubectl get secret prometheus-grafana -n k8ssandra-operator -o jsonpath='{.data.admin-password}' | base64 -d; echo
    ```

- **Reaper UI (Automated Repairs)**:
  - **URL**: `http://<node-ip>:32080/webui`
  - **Credentials**:
    ```bash
    kubectl get secret cassandra-cluster-reaper-ui -n k8ssandra-operator -o jsonpath='{.data.password}' | base64 -d; echo
    ```

### 2. Backups & Restores (`scripts/k8ssandra-backup-setup.sh`)

- **In-Cluster SeaweedFS (Local S3 Storage)**:
  ```bash
  sudo bash scripts/k8ssandra-backup-setup.sh --seaweedfs --medusa --test-backup
  ```

- **AWS S3 / S3-Compatible Remote Storage**:
  ```bash
  export MEDUSA_ACCESS_KEY="<ACCESS_KEY>"
  export MEDUSA_SECRET_KEY="<SECRET_KEY>"

  sudo -E bash scripts/k8ssandra-backup-setup.sh --medusa \
    --medusa-bucket cassandra-backups \
    --medusa-region us-east-1
  ```

- **Trigger an Ad-hoc Backup**:
  ```bash
  kubectl apply -n k8ssandra-operator -f - <<EOF
  apiVersion: medusa.k8ssandra.io/v1alpha1
  kind: MedusaBackupJob
  metadata:
    name: backup-$(date +%Y%m%d-%H%M)
  spec:
    cassandraDatacenter: dc1
  EOF
  ```

### 3. Adding a Cassandra Datacenter (`scripts/k8ssandra-add-dc.sh`)

1. Add sufficient worker nodes first using `--role add-workers`.
2. Deploy the new datacenter and update keyspace replication:
   ```bash
   sudo bash scripts/k8ssandra-add-dc.sh --dc-name dc2 --dc-size 3 \
     --replication '{"my_keyspace": 3}'
   ```

---

## Cleanup & Teardown

- **Remove K8ssandra & Addons (Preserve Kubernetes cluster)**:
  ```bash
  sudo bash scripts/k8ssandra-cleanup.sh --scope k8ssandra
  ```

- **Remove Specific Components**:
  ```bash
  sudo bash scripts/k8ssandra-cleanup.sh --scope monitoring
  sudo bash scripts/k8ssandra-cleanup.sh --scope medusa,seaweedfs
  ```

- **Full Cluster Teardown (Resets all nodes and Kubernetes)**:
  ```bash
  sudo bash scripts/k8ssandra-cleanup.sh --scope full --config config/cluster.env
  ```

---

## Troubleshooting

| Symptom | Diagnostic Command / Action |
|---|---|
| **Worker node join fails** | Check logs: `/var/log/k8ssandra-setup-worker-<ip>.log` on control plane. Verify SSH connectivity and security group port `6443`. |
| **Nodes in `NotReady` status** | Inspect Calico daemonset: `kubectl -n kube-system get pods -l k8s-app=calico-node`. Verify UDP port `4789` is open. |
| **Cassandra pods `Pending`** | Run `kubectl describe pod <pod-name> -n k8ssandra-operator`. Ensure each pod has a dedicated worker node (anti-affinity). |
| **Storage PVC Unbound** | Check storage class: `kubectl get sc,pvc -n k8ssandra-operator` and verify `local-path-provisioner` pods are running in `local-path-storage`. |

For in-depth operational procedures, consult [`docs/k8ssandra-runbook.md`](docs/k8ssandra-runbook.md).

---

## License

Apache License 2.0
