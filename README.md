# k3s + ArgoCD + AWX — Single Node GitOps Stack

Fully automated 3-phase Ansible deployment of k3s, ArgoCD, and AWX
on a single node with custom SSL via Traefik on port 443.

---

## Architecture

```
Internet / LAN
      |
  Port 443 (HTTPS)
      |
  Traefik (k3s built-in LB, externalIP = node_ip)
      |
  ┌───────────────────────────────┐
  │  IngressRoute (Traefik CRD)   │
  │  argocd.example.com  → ArgoCD │
  │  awx.example.com     → AWX    │
  └───────────────────────────────┘
      |                   |
  [argocd ns]         [awx ns]
   ArgoCD Server       AWX Operator
                       AWX Instance  ← deployed by ArgoCD Application
                                         using public Helm chart
```

---

## Prerequisites

**Control node** (your laptop/workstation):
- Ansible ≥ 2.14
- Python packages: `bcrypt` (`pip install bcrypt`)
- SSH key access to the target node

**Target node** (single server):
- Ubuntu 20.04/22.04/24.04, RHEL 8/9, or Oracle Linux 8/9
- Minimum: 4 vCPU, 8 GB RAM, 50 GB disk
- Root or sudo access
- Ports 80, 443, 6443 reachable

Install Ansible collections:
```bash
ansible-galaxy collection install -r requirements.yml
```

---

## Quick Start

### 1. Configure variables

Edit **`group_vars/all/vars.yml`** — this is the **only file you need to change**:

```yaml
node_ip:              "192.168.1.100"
local_storage_path:   "/data/storage"

ssl_cert_path:        "/etc/ssl/certs/tls.crt"   # on control node
ssl_key_path:         "/etc/ssl/private/tls.key"  # on control node

argocd_fqdn:          "argocd.example.com"
argocd_chart_version: ""          # empty = latest; pin e.g. "7.7.0"
argocd_admin_password: "Ch@ngeMe123!"

awx_fqdn:             "awx.example.com"
awx_chart_version:    ""          # empty = latest; pin e.g. "2.19.1"
awx_admin_password:   "Ch@ngeMe456!"
```

### 2. Configure inventory

Edit `inventory/hosts.ini`:
```ini
[k3s_nodes]
k3s-node ansible_host=192.168.1.100 ansible_user=root
```

### 3. Run full deploy

```bash
# Install package
chmod +x build.sh && bash build.sh

# All 3 phases at once
ansible-playbook -i inventory/hosts.ini site.yml

# Or phase by phase
ansible-playbook -i inventory/hosts.ini playbooks/phase1_k3s.yml
ansible-playbook -i inventory/hosts.ini playbooks/phase2_argocd.yml
ansible-playbook -i inventory/hosts.ini playbooks/phase3_awx.yml
```

---

## Project Structure

```
awx-gitops/
├── ansible.cfg
├── requirements.yml
├── site.yml                        ← master playbook (all phases)
│
├── inventory/
│   └── hosts.ini
│
├── group_vars/
│   └── all/
│       └── vars.yml                ← SINGLE VARIABLE FILE (edit this)
│
├── roles/
│   ├── k3s/
│   │   ├── tasks/main.yml          ← Phase 1: k3s + Helm + Traefik
│   │   └── handlers/main.yml
│   │
│   ├── argocd/
│   │   ├── tasks/main.yml          ← Phase 2: ArgoCD + SSL
│   │   └── templates/
│   │       └── ingressroute.yml.j2
│   │
│   └── awx/
│       ├── tasks/main.yml          ← Phase 3: AWX via ArgoCD Helm app
│       └── templates/
│           └── ingressroute.yml.j2
│
└── playbooks/
    ├── phase1_k3s.yml
    ├── phase2_argocd.yml
    ├── phase3_awx.yml
    ├── upgrade.yml                 ← Upgrade ArgoCD / AWX versions
    ├── renew_ssl.yml               ← Renew TLS certificates
    └── status.yml                  ← Health check / status report
```

---

## Day-2 Operations

### Upgrade ArgoCD

```bash
# 1. Set new version in vars.yml
argocd_chart_version: "7.8.0"

# 2. Run upgrade
ansible-playbook -i inventory/hosts.ini playbooks/upgrade.yml --tags argocd
```

### Upgrade AWX

```bash
# 1. Set new version in vars.yml
awx_chart_version: "2.20.0"

# 2. Run upgrade (patches the ArgoCD Application; ArgoCD syncs automatically)
ansible-playbook -i inventory/hosts.ini playbooks/upgrade.yml --tags awx
```

### Renew SSL certificates

```bash
# 1. Update ssl_cert_path / ssl_key_path in vars.yml to new cert files
# 2. Run renewal
ansible-playbook -i inventory/hosts.ini playbooks/renew_ssl.yml

# Renew only ArgoCD cert
ansible-playbook -i inventory/hosts.ini playbooks/renew_ssl.yml --tags argocd

# Renew only AWX cert
ansible-playbook -i inventory/hosts.ini playbooks/renew_ssl.yml --tags awx
```

### Health check

```bash
ansible-playbook -i inventory/hosts.ini playbooks/status.yml
```

---

## DNS / Hosts File

Point your FQDNs to `node_ip`. For local testing add to `/etc/hosts`:
```
192.168.1.100  argocd.example.com
192.168.1.100  awx.example.com
```

---

## Helm Repos Used

| App     | Helm Repo                                    | Chart          |
|---------|----------------------------------------------|----------------|
| ArgoCD  | https://argoproj.github.io/argo-helm         | argo-cd        |
| AWX     | https://ansible.github.io/awx-operator/      | awx-operator   |
| Traefik | https://helm.traefik.io/traefik              | traefik        |

All use public, official Helm repositories. Pinning a version in `vars.yml`
is all you need for reproducible upgrades.

---

## Security Notes

- `argocd_admin_password` and `awx_admin_password` in `vars.yml` are
  plain-text for convenience. For production, use **Ansible Vault**:
  ```bash
  ansible-vault encrypt_string 'Ch@ngeMe123!' --name argocd_admin_password
  ```
- TLS secrets are created directly in-cluster from your cert files;
  private keys never persist on disk on the target node.
- ArgoCD is deployed with `--insecure` (HTTP internally) because TLS
  termination is handled by Traefik — this is the standard single-node pattern.
