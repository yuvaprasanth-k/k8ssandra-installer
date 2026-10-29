# k8ssandra-on-ec2

Deploy **Apache Cassandra** on **AWS EC2** (or any Linux VMs) with **Kubernetes** and the **K8ssandra Operator**, using **one command**. Or install only K8ssandra on a Kubernetes cluster you already have.

---

## What gets installed

| Component | Default version | Configurable with |
|---|---|---|
| Kubernetes (kubeadm, kubelet, kubectl) | 1.36 | `--k8s-version` |
| containerd | OS / Docker repo | — |
| CNI: Calico (VXLAN overlay) | v3.33.0 | `--cni`, `--calico-version`, `--calico-encap`, `--cni-manifest` |
| Storage: local-path-provisioner, or EBS CSI with encrypted gp3, or your own class | v0.0.37 | `--storage-class`, `--storage-size` |
| Helm (only if missing) | v3.22.1 | `--helm-version` |
| cert-manager (skipped if already present) | v1.21.3 | `--cert-manager-version` |
| K8ssandra Operator (Helm chart) | 1.33.0 | `--operator-version` |
| Apache Cassandra | 4.1.8 (5.0.x supported) | `--cassandra-version`, `--cassandra-image` |
| Addons: Prometheus + Grafana, Reaper, Medusa | — | `--addons monitoring,reaper,medusa` |

---

## Repository structure

```
k8ssandra-on-ec2/
├── scripts/
│   ├── k8s-k8ssandra-setup.sh       # Main installer — all roles, fully automated
│   ├── k8ssandra-addons-setup.sh    # Monitoring, Reaper, Medusa (called by setup via --addons)
│   ├── k8ssandra-backup-setup.sh    # SeaweedFS (in-cluster S3) + Medusa, S3-compatible storage, test backup
│   ├── k8ssandra-add-dc.sh          # Add a Cassandra datacenter (with keyspace replication)
│   ├── k8ssandra-cleanup.sh         # Remove K8ssandra, or tear down every node
│   └── fix-pvc-ebs.sh               # Legacy EBS helper (prefer --storage-class ebs-gp3)
├── manifests/
│   ├── local-path-provisioner.yaml  # Applied by the setup script for local-path storage
│   └── cassandra-cluster.yaml       # Example spec for --cluster-manifest
├── config/
│   ├── cluster.env.example          # Every setting, documented — copy to cluster.env
│   └── kube-prom-stack-values.yaml
└── docs/k8ssandra-runbook.md
```

---

## Quick start: everything with one command

### Prerequisites
- 1 control-plane instance plus N workers. Run at least as many workers as `DC_SIZE` (default 3), because each Cassandra pod needs its own node. Use `m5.xlarge` or larger for real workloads; `t3.large` is fine for a lab.
- Amazon Linux 2023, Ubuntu 22.04/24.04, Debian or a RHEL-family OS. Same VPC, private IPs reachable from each other.
- **The control plane can SSH to every worker** with a key, and the SSH user has passwordless `sudo` (the default for `ec2-user` and `ubuntu`). Copy the key onto the control plane, e.g. `/home/ec2-user/.ssh/cluster-key.pem` with `chmod 600`.
- Security group: see [ports](#security-group-ports).

### 1. Copy the repo to the control-plane node and configure it
```bash
cp config/cluster.env.example config/cluster.env
vi config/cluster.env        # at minimum: WORKERS, SSH_USER, SSH_KEY
```

### 2. Run it
```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role all --config config/cluster.env
```

Or with flags only:
```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role all \
  --workers 10.0.1.11,10.0.1.12,10.0.1.13 \
  --ssh-user ec2-user --ssh-key /home/ec2-user/.ssh/cluster-key.pem
```

What happens, in order:

| Step | Action |
|---|---|
| 0 | Validates all settings and checks SSH + sudo on every worker **before touching anything** |
| 1 | Prepares the control plane (swap, kernel, containerd, kubeadm, kubelet with node IP and AZ labels) |
| 2 | `kubeadm init`, then Calico with your pod CIDR (checked against the VPC CIDR) |
| 3 | Copies the script to every worker over SSH and joins them **in parallel**, with one log per worker in `/var/log/` |
| 4 | Waits until every worker is Ready |
| 5 | Storage → cert-manager → K8ssandra Operator (retries while webhooks warm up) |
| 6 | Generates and applies the K8ssandraCluster, saving it to `/root/k8ssandra-<cluster>.yaml` |
| 7 | Waits for the Cassandra datacenter to be **Ready** |
| 8 | Installs the addons, if you asked for any |

**Safe to re-run:** finished steps are detected and skipped, including an initialised control plane, workers that already joined, and installed Helm releases.
The whole run is logged to `/var/log/k8ssandra-setup.log`.

---

## Customising

Every option works as a **flag**, a **config-file line** or an **environment variable**, in that order of priority.
`bash scripts/k8s-k8ssandra-setup.sh --help` lists them all, and `config/cluster.env.example` documents each one.

```bash
# See the effective settings without installing anything
bash scripts/k8s-k8ssandra-setup.sh --config config/cluster.env --print-config

# Preview the K8ssandraCluster YAML that would be applied
bash scripts/k8s-k8ssandra-setup.sh --config config/cluster.env --render-only
```

Common recipes:

```bash
# Production-like: EBS gp3 (encrypted), one rack per AZ, sized pods, Cassandra 5.0, addons
sudo bash scripts/k8s-k8ssandra-setup.sh --role all --config config/cluster.env \
  --storage-class ebs-gp3 --storage-size 200Gi \
  --racks zone --cpu 4 --memory 16Gi --heap-size 8G \
  --cassandra-version 5.0.4 --dc-size 6 \
  --addons monitoring,reaper,medusa

# Different Kubernetes version / network ranges / overlay
sudo bash scripts/k8s-k8ssandra-setup.sh --role all --config config/cluster.env \
  --k8s-version 1.35 --pod-cidr 10.244.0.0/16 --calico-encap IPIP

# Single-node lab (Cassandra on the control plane)
sudo bash scripts/k8s-k8ssandra-setup.sh --role all \
  --schedule-on-control-plane --dc-size 1 --heap-size 1G

# Bring your own K8ssandraCluster spec
sudo bash scripts/k8s-k8ssandra-setup.sh --role all --config config/cluster.env \
  --cluster-manifest manifests/cassandra-cluster.yaml
```

Racks (`--racks zone`): on EC2, every node labels itself with `topology.kubernetes.io/zone`. The script creates one rack per AZ, so Cassandra spreads its replicas across AZs. You can also give an explicit list: `--racks us-east-1a,us-east-1b,us-east-1c`.

---

## Install K8ssandra on an existing cluster

Works on a kubeadm cluster, EKS, or any conformant Kubernetes. Root is not needed if Helm is already installed.

```bash
bash scripts/k8s-k8ssandra-setup.sh --role k8ssandra \
  --kubeconfig ~/.kube/config \
  --storage-class gp3 \
  --dc-size 3 --cpu 2 --memory 8Gi
```
`--storage-class` takes an existing StorageClass name, or `local-path` / `ebs-gp3` to have the script install one.

cert-manager is skipped automatically if it's already installed. Use `--skip-cluster` to install only the operator.

---

## Step-by-step roles

| Role | Run on | Does |
|---|---|---|
| `all` | control plane | Everything (above) |
| `control-plane` | control plane | Kubernetes + CNI, plus joins `--workers` if given. No K8ssandra. |
| `add-workers` | control plane | Joins more workers over SSH to a running cluster |
| `worker` | a worker | Manual join: `--join-command "kubeadm join ..."` |
| `k8ssandra` | anywhere with kubectl | K8ssandra stack and Cassandra on an existing cluster |

```bash
# Kubernetes first, K8ssandra later
sudo bash scripts/k8s-k8ssandra-setup.sh --role control-plane --config config/cluster.env
sudo bash scripts/k8s-k8ssandra-setup.sh --role k8ssandra   --config config/cluster.env

# Grow the cluster
sudo bash scripts/k8s-k8ssandra-setup.sh --role add-workers \
  --workers 10.0.1.14,10.0.1.15,10.0.1.16 --ssh-key /home/ec2-user/.ssh/cluster-key.pem
```

---

## Adding a datacenter

```bash
# 1. Add nodes for it (each Cassandra pod needs its own node)
sudo bash scripts/k8s-k8ssandra-setup.sh --role add-workers --workers IP4,IP5,IP6 --ssh-key KEY

# 2. Add the DC, listing ALL your keyspaces with the replica count wanted in dc2
sudo bash scripts/k8ssandra-add-dc.sh --dc-name dc2 --dc-size 3 \
  --replication '{"orders": 3, "users": 3}'
```

The storage class and heap size are copied from `dc1` unless you pass `--storage-class` or `--heap-size`. Without `--replication`, only the system and K8ssandra keyspaces are replicated to the new DC.

---

## Addons

`--addons monitoring,reaper,medusa` on the setup script, or run `scripts/k8ssandra-addons-setup.sh` on its own.
Medusa secrets are read from the config file or environment, never from the command line:

```bash
# config/cluster.env
ADDONS=monitoring,reaper,medusa
MEDUSA_BUCKET=my-cassandra-backups
MEDUSA_REGION=us-east-1
MEDUSA_CREDENTIALS_TYPE=role-based     # use the instances' IAM role — no keys
# or: MEDUSA_CREDENTIALS_TYPE=credential-based + MEDUSA_ACCESS_KEY / MEDUSA_SECRET_KEY (chmod 600 the file)
```

### Backups: `scripts/k8ssandra-backup-setup.sh`

Medusa and its storage have their own script; `k8ssandra-addons-setup.sh` stays as it is.

In-cluster storage with SeaweedFS (no AWS account needed). Installs SeaweedFS, creates the bucket, and points Medusa at it:

```bash
sudo bash scripts/k8ssandra-backup-setup.sh --seaweedfs --medusa --test-backup
#   options (env): MEDUSA_BUCKET=cassandra-backups  SEAWEEDFS_STORAGE_CLASS=local-path  SEAWEEDFS_SIZE=50Gi
```
SeaweedFS runs as a single pod with its data on one PVC. That's fine for labs and small clusters; for production use AWS S3 or Ceph (Rook).

S3-compatible storage (MinIO, Wasabi, Ceph RGW, ...) — keys are required, IAM roles only work with AWS S3:

```bash
export MEDUSA_ACCESS_KEY=... MEDUSA_SECRET_KEY=...
sudo -E bash scripts/k8ssandra-backup-setup.sh --medusa \
  --medusa-provider s3_compatible --medusa-bucket cassandra-backups \
  --medusa-host minio.example.com --medusa-port 9000 --medusa-secure false
#   HTTPS endpoint with a self-signed cert:  --medusa-port 443 --medusa-secure true --medusa-ssl-verify false
#   Ceph RADOS Gateway:                       --medusa-provider s3_rgw
```
The script checks that the endpoint is reachable from inside the cluster before enabling Medusa. The bucket must already exist.

| Service | Access |
|---|---|
| Grafana | `http://<node-ip>:32000`, user `admin`, password: `kubectl -n k8ssandra-operator get secret prometheus-grafana -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Reaper UI | `http://<node-ip>:32080/webui` |
| CQL | `kubectl -n k8ssandra-operator exec -it <pod> -c cassandra -- cqlsh -u <user> -p <pw>` |

```bash
# Cassandra superuser
kubectl -n k8ssandra-operator get secret cassandra-cluster-superuser -o jsonpath='{.data.username}' | base64 -d
kubectl -n k8ssandra-operator get secret cassandra-cluster-superuser -o jsonpath='{.data.password}' | base64 -d
```

---

## Security group ports

Between cluster nodes (source: the cluster's own security group):

| Port | Protocol | Purpose |
|---|---|---|
| `6443` | TCP | Kubernetes API |
| `2379-2380` | TCP | etcd |
| `10250` | TCP | kubelet |
| `4789` | UDP | Calico VXLAN (default `--calico-encap VXLAN`) |
| IP protocol `4` + `179`/TCP | — | **Only** with `--calico-encap IPIP` (IP-in-IP + BGP) |
| `7000-7001`, `9042` | TCP | Cassandra inter-node / CQL |
| `22` | TCP | SSH from control plane → workers (auto-join, full teardown) |

From your own IP or VPN only, **never `0.0.0.0/0`**: `22`, `6443`, and any NodePorts you use (`32000` Grafana, `32080` Reaper).

---

## Storage

| `--storage-class` | Use for | Notes |
|---|---|---|
| `local-path` (default) | labs, dev | Data lives in `/opt/local-path-provisioner` on the node; losing the node loses that replica |
| `ebs-gp3` | production on EC2 | Installs the EBS CSI driver and an **encrypted** gp3 class with `Retain`. Nodes need an IAM role with `AmazonEBSCSIDriverPolicy` and IMDS hop limit ≥ 2 |
| any other name | existing clusters | Must already exist |

> A datacenter's storage class can't be changed after it's created. To move from local-path to EBS, add a new DC on `ebs-gp3` and decommission the old one.

---

## Cleanup

```bash
sudo bash scripts/k8ssandra-cleanup.sh --scope k8ssandra          # K8ssandra only, keep Kubernetes
# Every node (asks you to type 'destroy')
sudo bash scripts/k8ssandra-cleanup.sh --scope full \
  --ssh-user ec2-user --ssh-key /home/ec2-user/.ssh/cluster-key.pem
```

With `ebs-gp3` (reclaim policy `Retain`), EBS volumes survive cleanup. Delete them in the EC2 console when you no longer need the data.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Worker join failed | `/var/log/k8ssandra-setup-worker-<ip>.log` on the control plane |
| Nodes `NotReady` | `kubectl -n kube-system get pods -o wide` (Calico), plus security group UDP 4789 |
| Cassandra pods `Pending` | `kubectl describe pod`: too few free nodes (one per pod) or unbound PVC |
| DC never Ready | `kubectl -n k8ssandra-operator describe cassandradatacenter dc1` |

See [`docs/k8ssandra-runbook.md`](docs/k8ssandra-runbook.md) for day-2 operations.

## License
Apache 2.0
