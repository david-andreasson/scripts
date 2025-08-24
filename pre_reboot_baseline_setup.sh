#!/usr/bin/env bash
set -euo pipefail

# ==== Config ====
NEW_USER="deploy"
NEW_USER_PASSWORD="StrongPass123!"
APP_PORT="8080"
# Your laptop's public key allowed to log in as $NEW_USER after reboot
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPMls2kftKWFT/secNqkRdjwGu/cHh3Om9sEKdAzopBc 79davand@gafe.molndal.se"

# ==== UI ====
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok(){   printf "  [${GREEN}OK${NC}]  %s\n" "$1"; }
fail(){ printf "  [${RED}FAIL${NC}] %s\n" "$1"; }
todo(){ printf "  [${YELLOW}TODO${NC}] %s\n" "$1"; }

CURRENT_STEP=""; trap 'echo; fail "${CURRENT_STEP:-Step failed}"; exit 1' ERR
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }; }

# Update to latest packages
update_and_upgrade(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade
}

# Enable unattended security/OS updates
enable_unattended(){
  apt-get install -y unattended-upgrades apt-listchanges
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

# Create deploy user, add sudo, install your laptop's pubkey
create_user_and_key(){
  if ! id -u "$NEW_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    echo "$NEW_USER:$NEW_USER_PASSWORD" | chpasswd
    usermod -aG sudo "$NEW_USER"
  else
    usermod -aG sudo "$NEW_USER" || true
  fi
  install -d -m 0700 -o "$NEW_USER" -g "$NEW_USER" "/home/$NEW_USER/.ssh"
  printf '%s\n' "$PUBKEY" > "/home/$NEW_USER/.ssh/authorized_keys"
  chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh/authorized_keys"
  chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
}

# Harden SSH: no root login, no password login
harden_ssh(){
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
EOF
  sshd -t
  systemctl restart ssh
}

# Firewall: default deny incoming, allow SSH + app port
setup_ufw(){
  apt-get install -y ufw
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow "${APP_PORT}"/tcp
  ufw --force enable
}

# If present, place the post-reboot script in deploy's home (new name)
stage_post_script(){
  if [ -f /root/post_reboot_baseline_setup.sh ]; then
    install -m 0755 -o "$NEW_USER" -g "$NEW_USER" \
      /root/post_reboot_baseline_setup.sh "/home/$NEW_USER/post_reboot_baseline_setup.sh"
  fi
}

# Always generate a fresh server keypair for deploy, print pubkey as last output, then reboot
print_pubkey_and_reboot(){
  local sshdir="/home/$NEW_USER/.ssh"
  rm -f "$sshdir/id_ed25519" "$sshdir/id_ed25519.pub"
  sudo -u "$NEW_USER" ssh-keygen -t ed25519 -N "" -C "$NEW_USER@$(hostname)" -f "$sshdir/id_ed25519" >/dev/null
  chown -R "$NEW_USER:$NEW_USER" "$sshdir"
  echo "Copy this key to your GitHub account: Settings → SSH and GPG keys → New SSH key"
  cat "$sshdir/id_ed25519.pub"
  sync; sleep 1; reboot
}

main(){
  require_root
  echo "  [ ] Update system packages"
  echo "  [ ] Configure UFW (SSH + ${APP_PORT})"
  echo "  [ ] Create user (${NEW_USER})"
  echo "  [ ] Harden SSH (no root/password login)"
  echo "  [ ] Stage post-reboot script (post_reboot_baseline_setup.sh)"
  todo "After reboot: SSH as ${NEW_USER} and run: sudo ./post_reboot_baseline_setup.sh"
  echo

  CURRENT_STEP="Update system";                    update_and_upgrade;  ok "$CURRENT_STEP"
  CURRENT_STEP="Enable unattended upgrades";       enable_unattended;   ok "$CURRENT_STEP"
  CURRENT_STEP="Create user (${NEW_USER}) + key";  create_user_and_key; ok "$CURRENT_STEP"
  CURRENT_STEP="Harden SSH";                       harden_ssh;          ok "$CURRENT_STEP"
  CURRENT_STEP="Configure UFW";                    setup_ufw;           ok "$CURRENT_STEP"
  CURRENT_STEP="Stage post script";                stage_post_script;   ok "$CURRENT_STEP"

  print_pubkey_and_reboot
}

main "$@"
