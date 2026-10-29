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

*Or pass configuration directly via CLI flags (including optional addons):*
```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role all \
  --workers 10.0.1.11,10.0.1.12,10.0.1.13 \
  --ssh-user ec2-user \
  --ssh-key /home/ec2-user/.ssh/cluster-key.pem \
  --dc-size 3 \
  --addons monitoring,reaper
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

## Optional Addons: Monitoring, Reaper, and Backup

You can deploy addons either during the initial cluster installation via `--addons monitoring,reaper,medusa` or at any time using the standalone addon scripts.

### 1. Monitoring & Reaper (`scripts/k8ssandra-addons-setup.sh`)

This script installs Prometheus, Grafana with pre-built Cassandra dashboards, and Apache Cassandra Reaper for automated repair scheduling.

#### Install Monitoring (Prometheus + Grafana)
Deploys `kube-prometheus-stack`, configures Cassandra metrics telemetry, and provisions Grafana dashboards:

```bash
sudo bash scripts/k8ssandra-addons-setup.sh --monitoring
```

- **Access Grafana**: `http://<node-ip>:32000`
- **Username**: `admin`
- **Retrieve Password**:
  ```bash
  kubectl get secret prometheus-grafana -n k8ssandra-operator -o jsonpath='{.data.admin-password}' | base64 -d; echo
  ```

#### Install Reaper (Automated Repairs)
Enables Reaper in the `K8ssandraCluster` spec across all datacenters and exposes the management UI on NodePort `32080`:

```bash
sudo bash scripts/k8ssandra-addons-setup.sh --reaper
```

- **Access Reaper Web UI**: `http://<node-ip>:32080/webui`
- **Retrieve Credentials**:
  ```bash
  # Username
  kubectl get secret cassandra-cluster-reaper-ui -n k8ssandra-operator -o jsonpath='{.data.username}' | base64 -d; echo
  # Password
  kubectl get secret cassandra-cluster-reaper-ui -n k8ssandra-operator -o jsonpath='{.data.password}' | base64 -d; echo
  ```

#### Install All Addons Together
```bash
sudo bash scripts/k8ssandra-addons-setup.sh --all
```

---

### 2. Backup & Restore with Medusa (`scripts/k8ssandra-backup-setup.sh`)

This dedicated script manages backup infrastructure and Medusa integration.

#### Option A: In-Cluster Backup with SeaweedFS (No AWS Account Required)
Deploys SeaweedFS S3-compatible object store on local storage, creates the backup bucket, configures Medusa, and triggers an initial test backup:

```bash
sudo bash scripts/k8ssandra-backup-setup.sh --seaweedfs --medusa --test-backup
```

#### Option B: AWS S3 or S3-Compatible Remote Storage (MinIO, Wasabi, Ceph RGW)
Pass credentials safely via environment variables:

```bash
export MEDUSA_ACCESS_KEY="<YOUR_ACCESS_KEY>"
export MEDUSA_SECRET_KEY="<YOUR_SECRET_KEY>"

# AWS S3 with access keys
sudo -E bash scripts/k8ssandra-backup-setup.sh --medusa \
  --medusa-bucket my-cassandra-backups \
  --medusa-region us-east-1

# S3-compatible remote storage (e.g. MinIO)
sudo -E bash scripts/k8ssandra-backup-setup.sh --medusa \
  --medusa-provider s3_compatible \
  --medusa-bucket cassandra-backups \
  --medusa-host minio.example.com \
  --medusa-port 9000 \
  --medusa-secure false
```

#### Backup Operations

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

- **List Backup Jobs & Completed Backups**:
  ```bash
  kubectl get medusabackupjob -n k8ssandra-operator
  kubectl get medusabackup -n k8ssandra-operator
  ```

- **Restore from Backup**:
  ```bash
  kubectl apply -n k8ssandra-operator -f - <<EOF
  apiVersion: medusa.k8ssandra.io/v1alpha1
  kind: MedusaRestoreJob
  metadata:
    name: restore-$(date +%Y%m%d-%H%M)
  spec:
    cassandraDatacenter: dc1
    backup: <backup-name>
  EOF
  ```

---

## Cluster Operations

### Connecting to Cassandra (CQL)

```bash
# Retrieve superuser credentials
kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator -o jsonpath='{.data.password}' | base64 -d; echo

# Connect via cqlsh inside a Cassandra pod
kubectl exec -it cassandra-cluster-dc1-default-sts-0 -n k8ssandra-operator -c cassandra -- cqlsh -u <username> -p <password>
```

### Adding a Datacenter (`scripts/k8ssandra-add-dc.sh`)

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

- **Remove Specific Addons**:
  ```bash
  sudo bash scripts/k8ssandra-cleanup.sh --scope monitoring
  sudo bash scripts/k8ssandra-cleanup.sh --scope medusa,seaweedfs
  ```

- **Full Cluster Teardown (Resets all nodes and Kubernetes)**:
  ```bash
  sudo bash scripts/k8ssandra-cleanup.sh --scope full --config config/cluster.env
  ```

---


For in-depth operational procedures, consult [`docs/k8ssandra-runbook.md`](docs/k8ssandra-runbook.md).

---

## License

Apache License 2.0
