# Changelog

All notable changes to this project are documented here.

---

## [1.2.0] — 2025

### Added
- `local-path-provisioner.yaml` — local dynamic storage provisioner (no EBS CSI / IAM required)
- `fix-pvc-ebs.sh` — optional EBS CSI driver installer for production durable storage
- `k8ssandra-addons-setup.sh` — addons installer for Monitoring, Reaper, Medusa
- Section 13 in runbook: Addons (Monitoring, Reaper, Medusa)
- Section 14 in runbook: Storage (local-path-provisioner)
- `cassandra-cluster.yaml` standalone manifest using `local-path` StorageClass

### Changed
- `k8s-k8ssandra-setup.sh`: Phase 3 now installs `local-path-provisioner` before K8ssandra
- `k8s-k8ssandra-setup.sh`: `storageClassName` changed from `gp2` → `local-path`
- `k8s-k8ssandra-setup.sh`: `CASSANDRA_STORAGE` reduced from `100Gi` → `20Gi`
- `k8ssandra-addons-setup.sh`: Reaper service patched from `ClusterIP` → `NodePort` (32080/32081)
- Runbook updated to v1.2

### Fixed
- `local-path-provisioner.yaml`: ServiceAccount and ConfigMap namespaces corrected to `local-path-storage`
- `local-path-provisioner.yaml`: ClusterRoleBinding namespace removed (cluster-scoped resource)
- `local-path-provisioner.yaml`: Image tag pinned from `master-head` → `v0.0.26`

---

## [1.1.0] — 2025

### Added
- `fix-pvc-ebs.sh` — fixes unbound PVC errors by installing the AWS EBS CSI driver
- `k8ssandra-addons-setup.sh` initial version with Monitoring, Reaper, Medusa
- Section 13 in runbook: Addons

### Changed
- Runbook updated to v1.1

---

## [1.0.0] — 2025

### Added
- `k8s-k8ssandra-setup.sh` — combined single-script Kubernetes + K8ssandra installer
- Support for Amazon Linux 2 and Ubuntu 20.04/22.04
- `--role control-plane` and `--role worker` flags
- Auto-saves worker join command to `/root/worker-join-command.sh`
- Installs: containerd, kubeadm, kubelet, kubectl v1.29, Calico CNI, Helm, cert-manager, K8ssandra Operator
- `k8ssandra-runbook.md` — full operational runbook v1.0
