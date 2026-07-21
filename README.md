# k8ssandra-on-ec2

Deploy a production-grade **Apache Cassandra** cluster on **AWS EC2** using **Kubernetes** and **K8ssandra Operator** — fully automated with a single script.

---

## What This Does

| Component | Version | Purpose |
|---|---|---|
| Kubernetes | 1.29 | Container orchestration |
| containerd | latest | Container runtime |
| Calico CNI | v3.27.0 | Pod networking |
| local-path-provisioner | v0.0.26 | Dynamic local storage (no EBS/IAM needed) |
| cert-manager | v1.13.0 | TLS certificates (K8ssandra dependency) |
| K8ssandra Operator | latest stable | Manages Cassandra lifecycle |
| Apache Cassandra | 4.1.3 | Distributed NoSQL database |
| Prometheus + Grafana | latest | Monitoring & dashboards |
| Reaper | latest | Automated repair scheduling |
| Medusa | latest | Backup / restore to S3 |

---

## Repository Structure

```
k8ssandra-on-ec2/
├── scripts/
│   ├── k8s-k8ssandra-setup.sh       # Main installer (Kubernetes + K8ssandra)
│   ├── k8ssandra-addons-setup.sh    # Addons installer (Monitoring, Reaper, Medusa)
│   └── fix-pvc-ebs.sh               # Optional: EBS CSI driver (production storage)
├── manifests/
│   ├── local-path-provisioner.yaml  # Local storage provisioner
│   └── cassandra-cluster.yaml       # K8ssandraCluster definition
├── config/
│   └── kube-prom-stack-values.yaml  # Prometheus + Grafana Helm values
├── docs/
│   └── k8ssandra-runbook.md         # Full operational runbook
├── .gitignore
├── CHANGELOG.md
└── README.md
```

---

## Quick Start

### Requirements
- 4 × EC2 instances (`t3.large` minimum, `t3.xlarge` recommended)
- Amazon Linux 2 or Ubuntu 20.04/22.04
- All instances in the same VPC / security group
- SSH + sudo access to all instances

### Step 1 — Copy scripts to all 4 nodes

```bash
chmod +x scripts/*.sh
```

### Step 2 — Run on Node 1 (control plane)

```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role control-plane
```

### Step 3 — Run on Nodes 2, 3, 4 (workers)

Copy the join command printed at the end of Step 2, then on each worker:

```bash
sudo bash scripts/k8s-k8ssandra-setup.sh --role worker \
  --join-command "kubeadm join <ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
```

### Step 4 — Deploy Addons (on Node 1)

```bash
# All addons (Monitoring + Reaper + Medusa)
sudo bash scripts/k8ssandra-addons-setup.sh --all \
  --medusa-bucket my-cassandra-backups \
  --medusa-access-key AKIAIOSFODNN7EXAMPLE \
  --medusa-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Or selectively
sudo bash scripts/k8ssandra-addons-setup.sh --monitoring
sudo bash scripts/k8ssandra-addons-setup.sh --reaper
```

---

## Accessing Services

| Service | URL | Credentials |
|---|---|---|
| **Grafana** | `http://<node-ip>:32000` | admin / K8ssandraAdmin! |
| **Reaper UI** | `http://<node-ip>:32080/webui` | See secret below |
| **Cassandra CQL** | `<node-ip>:9042` | See secret below |

```bash
# Cassandra superuser credentials
kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator \
  -o jsonpath='{.data.username}' | base64 -d

kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator \
  -o jsonpath='{.data.password}' | base64 -d

# Reaper UI password
kubectl get secret cassandra-cluster-reaper-ui -n k8ssandra-operator \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Security Group Ports

| Port | Protocol | Purpose |
|---|---|---|
| `22` | TCP | SSH |
| `6443` | TCP | Kubernetes API |
| `2379-2380` | TCP | etcd |
| `10250` | TCP | kubelet |
| `4789` | UDP | Calico VXLAN |
| `9042` | TCP | Cassandra CQL |
| `7000-7001` | TCP | Cassandra inter-node |
| `30000-32767` | TCP | Kubernetes NodePort range |

---

## Full Documentation

See [`docs/k8ssandra-runbook.md`](docs/k8ssandra-runbook.md) for the complete operational runbook including:
- Detailed installation steps
- Verification checklists
- Common operations (scale, repair, backup)
- Troubleshooting guide
- Rollback / teardown procedures

---

## Storage

This setup uses **`local-path-provisioner`** (no AWS IAM or EBS CSI driver required).  
Data is stored at `/opt/local-path-provisioner/` on each worker node's local disk.

For production use with durable EBS-backed storage, run:
```bash
sudo bash scripts/fix-pvc-ebs.sh
```
Then update `manifests/cassandra-cluster.yaml` to use `storageClassName: gp3`.

---

## License

Apache 2.0
