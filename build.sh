#!/usr/bin/env bash
# =============================================================
# build.sh — Dependency installer for k3s + ArgoCD + AWX stack
# Supports: Ubuntu 20/22/24, RHEL 8/9, Oracle Linux 8/9
# Usage: bash build.sh
# =============================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()     { echo -e "${GREEN}[OK]${NC}  $*"; }
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}==============================${NC}"; echo -e "${CYAN} $*${NC}"; echo -e "${CYAN}==============================${NC}"; }

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
  error "Please run as root: sudo bash build.sh"
fi

# =============================================================
# 1. Detect OS
# =============================================================
section "Detecting Operating System"

if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID}"
  OS_VERSION="${VERSION_ID%%.*}"   # major version only
  OS_FAMILY=""

  case "$ID" in
    ubuntu|debian)          OS_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol)  OS_FAMILY="redhat" ;;
    *)                      error "Unsupported OS: $ID" ;;
  esac
else
  error "Cannot detect OS: /etc/os-release not found"
fi

info "OS       : $PRETTY_NAME"
info "Family   : $OS_FAMILY"
info "Version  : $OS_VERSION"

# =============================================================
# 2. System packages
# =============================================================
section "Installing System Packages"

if [[ "$OS_FAMILY" == "debian" ]]; then
  info "Updating apt cache..."
  apt-get update -qq

  info "Installing base packages..."
  apt-get install -y -qq \
    curl wget git unzip tar \
    apt-transport-https ca-certificates gnupg lsb-release \
    open-iscsi nfs-common \
    python3 python3-pip python3-venv \
    openssl \
    software-properties-common

  log "APT packages installed"

elif [[ "$OS_FAMILY" == "redhat" ]]; then
  info "Installing base packages via dnf..."
  dnf install -y -q \
    curl wget git unzip tar \
    ca-certificates gnupg2 \
    iscsi-initiator-utils nfs-utils \
    python3 python3-pip \
    openssl \
    httpd-tools \
    container-selinux

  # Enable iscsid for Longhorn/local storage
  systemctl enable --now iscsid 2>/dev/null || true

  log "DNF packages installed"
fi

# =============================================================
# 3. Python packages (bcrypt, ansible, etc.)
# =============================================================
section "Installing Python Packages"

info "Upgrading pip..."
python3 -m pip install --upgrade pip --quiet

info "Installing bcrypt (for ArgoCD password hashing)..."
python3 -m pip install bcrypt --quiet
log "bcrypt installed: $(python3 -c 'import bcrypt; print(bcrypt.__version__)')"

info "Installing ansible..."
python3 -m pip install ansible --quiet
log "Ansible installed: $(ansible --version | head -1)"

info "Installing ansible-lint (optional)..."
python3 -m pip install ansible-lint --quiet 2>/dev/null || warn "ansible-lint skipped"

# =============================================================
# 4. Ansible collections
# =============================================================
section "Installing Ansible Collections"

if [ -f "requirements.yml" ]; then
  info "Found requirements.yml — installing collections..."
  ansible-galaxy collection install -r requirements.yml --force
  log "Collections installed"
else
  warn "requirements.yml not found — installing collections manually..."
  ansible-galaxy collection install \
    ansible.posix \
    community.general \
    kubernetes.core \
    --force
  log "Collections installed manually"
fi

# =============================================================
# 5. Helm
# =============================================================
section "Installing Helm"

if command -v helm &>/dev/null; then
  warn "Helm already installed: $(helm version --short)"
else
  info "Downloading Helm install script..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log "Helm installed: $(helm version --short)"
fi

# =============================================================
# 6. kubectl (standalone — k3s also ships kubectl, this is a backup)
# =============================================================
section "Installing kubectl"

if command -v kubectl &>/dev/null; then
  warn "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
  info "Fetching latest stable kubectl..."
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
  log "kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# =============================================================
# 7. htpasswd (fallback bcrypt hasher for ArgoCD)
# =============================================================
section "Ensuring htpasswd Available"

if command -v htpasswd &>/dev/null; then
  log "htpasswd already available"
else
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get install -y -qq apache2-utils
  elif [[ "$OS_FAMILY" == "redhat" ]]; then
    dnf install -y -q httpd-tools
  fi
  log "htpasswd installed"
fi

# =============================================================
# 8. SSH key (for Ansible even on localhost)
# =============================================================
section "Checking SSH Key"

if [ ! -f ~/.ssh/id_rsa ]; then
  info "Generating SSH keypair for localhost..."
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -q
  cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  log "SSH keypair generated and authorized"
else
  log "SSH key already exists: ~/.ssh/id_rsa"
fi

# Ensure localhost is in known_hosts (avoids first-run prompt)
ssh-keyscan -H localhost >> ~/.ssh/known_hosts 2>/dev/null
ssh-keyscan -H 127.0.0.1 >> ~/.ssh/known_hosts 2>/dev/null
log "localhost added to known_hosts"

# =============================================================
# 9. Verify inventory / vars reminder
# =============================================================
section "Pre-flight Checks"

ERRORS=0

if [ -f "inventory/hosts.ini" ]; then
  log "inventory/hosts.ini found"
else
  warn "inventory/hosts.ini NOT found — create it before running playbooks"
  ((ERRORS++)) || true
fi

if [ -f "group_vars/all/vars.yml" ]; then
  log "group_vars/all/vars.yml found"

  # Remind user to set real values
  if grep -q "192.168.1.100" group_vars/all/vars.yml; then
    warn "node_ip is still the default (192.168.1.100) — update group_vars/all/vars.yml"
  fi
  if grep -q "Ch@ngeMe" group_vars/all/vars.yml; then
    warn "Default passwords detected in vars.yml — please change them"
  fi
  if grep -q "example.com" group_vars/all/vars.yml; then
    warn "FQDNs still set to example.com — update argocd_fqdn / awx_fqdn"
  fi
else
  warn "group_vars/all/vars.yml NOT found"
  ((ERRORS++)) || true
fi

if [ -f "site.yml" ]; then
  log "site.yml found"
else
  warn "site.yml NOT found — are you in the project root?"
  ((ERRORS++)) || true
fi

# =============================================================
# 10. Summary
# =============================================================
section "Installation Summary"

echo ""
printf "  %-25s %s\n" "Python3"    "$(python3 --version)"
printf "  %-25s %s\n" "pip3"       "$(pip3 --version | awk '{print $1,$2}')"
printf "  %-25s %s\n" "bcrypt"     "$(python3 -c 'import bcrypt; print(bcrypt.__version__)')"
printf "  %-25s %s\n" "Ansible"    "$(ansible --version | head -1)"
printf "  %-25s %s\n" "Helm"       "$(helm version --short)"
printf "  %-25s %s\n" "kubectl"    "$(kubectl version --client --short 2>/dev/null | tr -d '\n' || echo 'installed')"
printf "  %-25s %s\n" "htpasswd"   "$(command -v htpasswd)"
echo ""

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${YELLOW}[WARN]${NC} $ERRORS configuration issue(s) found above — fix before running playbooks."
else
  echo -e "${GREEN}All dependencies installed successfully!${NC}"
fi

echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Edit  group_vars/all/vars.yml   (set node_ip, FQDNs, passwords, SSL paths)"
echo "  2. Edit  inventory/hosts.ini        (already set to localhost)"
echo "  3. Run:  ansible-playbook -i inventory/hosts.ini site.yml"
echo "     Or phase by phase:"
echo "            ansible-playbook -i inventory/hosts.ini playbooks/phase1_k3s.yml"
echo "            ansible-playbook -i inventory/hosts.ini playbooks/phase2_argocd.yml"
echo "            ansible-playbook -i inventory/hosts.ini playbooks/phase3_awx.yml"
echo ""