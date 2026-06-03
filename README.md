# ArgoCD + AWX on k3s (single node) — Ansible Automation

## Traffic flow

```
Browser
  │
  ▼ :443 (hostPort on single node)
Traefik  ← built into k3s, no extra ingress controller needed
  │
  ├── Host(argocd-awx.domain.com) → argocd-server:80  (ArgoCD runs --insecure)
  │     TLS: Secret argocd-tls  (issued by cert-manager)
  │
  └── Host(awx-prod.domain.com)  → awx-prod-service:80
        TLS: Secret awx-tls     (issued by cert-manager)

cert-manager  →  ClusterIssuer (Let's Encrypt)  →  Certificate CRDs  →  TLS Secrets
Traefik IngressRoute reads secretName → terminates TLS at edge
```

## Quick start

### 1 — Edit ONLY this file

```bash
vi group_vars/all.yml
```

Minimum changes:

| Variable | What to set |
|---|---|
| `base_domain` | your domain, e.g. `company.com` |
| `k3s_master_ip` | server IP, e.g. `10.0.0.5` |
| `tls_email` | email for Let's Encrypt |
| `tls_issuer` | `letsencrypt-prod` or `selfsigned` |
| `argocd_admin_password` | strong password |
| `awx_admin_password` | strong password |
| `awx_db_password` | strong password |
| `ldap_bind_dn` / `ldap_bind_password` | your LDAP service account |
| `argocd_ldap.bind_dn` / `argocd_ldap.bind_password` | LDAP for ArgoCD/dex |

### 2 — Edit inventory

```ini
# inventory/hosts.ini
[k3s_masters]
k3s-master ansible_host=10.0.0.5
```

### 3 — Deploy

```bash
# Full stack
ansible-playbook site.yml -i inventory/hosts.ini

# Individual phases
ansible-playbook site.yml -i inventory/hosts.ini --tags k3s
ansible-playbook site.yml -i inventory/hosts.ini --tags argocd
ansible-playbook site.yml -i inventory/hosts.ini --tags awx
ansible-playbook site.yml -i inventory/hosts.ini --tags ldap
```

## Traefik IngressRoute overview

Each app gets two IngressRoute objects:

```
IngressRoute (websecure / :443)  → service:80, tls.secretName: <app>-tls
IngressRoute (web / :80)         → Middleware: redirectScheme https
Middleware                       → redirectScheme: https, permanent: true
Certificate (cert-manager CRD)   → issues Secret <app>-tls via ClusterIssuer
```

ArgoCD runs with `--insecure` (HTTP internally). Traefik terminates TLS and
forwards plain HTTP to `argocd-server:80`. This is the recommended pattern for
Traefik + ArgoCD.

## RBAC

### ArgoCD (LDAP groups → roles)

| LDAP group | Role | Permissions |
|---|---|---|
| `argocd-admins` | admin | Full access + exec |
| `argocd-developers` | dev | Sync / create / update apps |
| `argocd-readonly` | readonly | View only |
| `argocd-awx` | awx-deploy | Sync AWX app only |

### AWX (LDAP groups)

| LDAP group | Permission |
|---|---|
| `cn=awx-admins,...` | Superuser |
| `cn=awx-auditors,...` | System Auditor |
| `cn=awx-users,...` | Required to login |

## DNS requirement

Point both FQDNs to the single node's IP **before** running the playbook
(Let's Encrypt HTTP-01 challenge requires this):

```
argocd-awx.domain.com  A  <server-ip>
awx-prod.domain.com    A  <server-ip>
```

## Secrets (production)

```bash
ansible-vault encrypt group_vars/all.yml
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass
```

## File structure

```
.
├── site.yml                             # Master playbook
├── group_vars/all.yml                   # ← single source of truth
├── inventory/hosts.ini
├── files/
│   └── argocd-app-awx.yaml             # ArgoCD Application CR (GitOps)
└── roles/
    ├── k3s/
    │   ├── tasks/main.yml               # k3s install + Traefik patch + cert-manager
    │   └── templates/cluster-issuer.yaml.j2
    ├── argocd/
    │   ├── tasks/main.yml
    │   └── templates/
    │       ├── argocd-values.yaml.j2    # Helm values (LDAP + RBAC + --insecure)
    │       ├── argocd-certificate.yaml.j2
    │       └── argocd-ingressroute.yaml.j2
    ├── awx/
    │   ├── tasks/main.yml
    │   └── templates/
    │       ├── awx-instance.yaml.j2
    │       ├── awx-certificate.yaml.j2
    │       └── awx-ingressroute.yaml.j2
    └── ldap-config/
        └── tasks/main.yml               # AWX LDAP via REST API
