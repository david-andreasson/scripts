#!/usr/bin/env bash
set -euo pipefail

# ==== Config ====
NEW_USER="deploy"
REPO_URL="https://github.com/briceburg/docker-2048.git"
APP_DIR="/home/${NEW_USER}/docker-2048"
APP_PORT="8080"                                    # host port (opened in script 1)
HEALTH_ENDPOINT="http://127.0.0.1:${APP_PORT}/"    # 2048 returns 200 OK on "/"
HEALTH_TIMEOUT=120

# ==== UI ====
GREEN='\033[32m'; RED='\033[31m'; NC='\033[0m'
ok(){   printf "  [${GREEN}OK${NC}]  %s\n" "$1"; }   # print green OK line
fail(){ printf "  [${RED}FAIL${NC}] %s\n" "$1"; }    # print red FAIL line

CURRENT_STEP=""
on_error(){ echo; fail "${CURRENT_STEP:-Step failed}"; exit 1; }  # fail on any error
trap on_error ERR

require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }; }  # ensure root

# Install Docker Engine + Compose plugin from Docker’s official repo
install_docker(){  
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release git
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  usermod -aG docker "${NEW_USER}" || true
}

# Generate an SSH keypair for ${NEW_USER} (useful if you later switch to SSH clones)
gen_ssh_key(){  
  local key="/home/${NEW_USER}/.ssh/id_ed25519"
  install -d -m 0700 -o "${NEW_USER}" -g "${NEW_USER}" "/home/${NEW_USER}/.ssh"
  if [[ ! -f "${key}" ]]; then
    sudo -u "${NEW_USER}" ssh-keygen -q -t ed25519 -N "" -f "${key}"
    cat "${key}.pub"
    cp "${key}.pub" "/home/${NEW_USER}/GITHUB_SSH_KEY.pub"
    chown "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/GITHUB_SSH_KEY.pub"
  fi
}

# Clone or update the target repository into APP_DIR
clone_repo(){
  install -d -m 0755 -o "${NEW_USER}" -g "${NEW_USER}" "$(dirname "${APP_DIR}")"
  if [[ -d "${APP_DIR}/.git" ]]; then
    sudo -u "${NEW_USER}" git -C "${APP_DIR}" pull --ff-only
  else
    sudo -u "${NEW_USER}" git clone "${REPO_URL}" "${APP_DIR}"
  fi
}

# Bring up the stack via Docker Compose on the selected port and show status
compose_up(){
  local compose_file
  if   [[ -f "${APP_DIR}/docker-compose.yml" ]];   then compose_file="docker-compose.yml"
  elif [[ -f "${APP_DIR}/docker-compose.yaml" ]]; then compose_file="docker-compose.yaml"
  elif [[ -f "${APP_DIR}/compose.yaml" ]];        then compose_file="compose.yaml"
  else echo "Compose file not found in ${APP_DIR}"; exit 1
  fi
  (cd "${APP_DIR}" && PORT="${APP_PORT}" docker compose -f "${compose_file}" up -d --build)
  docker compose -f "${APP_DIR}/${compose_file}" ps
}

# Poll HEALTH_ENDPOINT until HTTP 200 or HEALTH_TIMEOUT expires
health_check(){
  local end=$(( $(date +%s) + HEALTH_TIMEOUT ))
  until curl -fsS "${HEALTH_ENDPOINT}" >/dev/null 2>&1; do
    if (( $(date +%s) >= end )); then
      return 1
    fi
    sleep 2
  done
  return 0
}

# Execute steps and report status
main(){
  require_root
  echo "  [ ] Install Docker"
  echo "  [ ] Install Docker Compose (plugin)"
  echo "  [ ] Generate SSH keypair for ${NEW_USER} (optional for HTTPS)"
  echo "  [ ] Clone repository (docker-2048)"
  echo "  [ ] Start container with Docker Compose (PORT=${APP_PORT})"
  echo "  [ ] Health-check application (${HEALTH_ENDPOINT})"
  echo

  CURRENT_STEP="Install Docker";                        install_docker; ok "${CURRENT_STEP}"
  CURRENT_STEP="Verify Docker Compose";                 docker compose version >/dev/null 2>&1 && ok "${CURRENT_STEP}"
  CURRENT_STEP="Generate SSH keypair for ${NEW_USER}";  gen_ssh_key;    ok "${CURRENT_STEP}"
  CURRENT_STEP="Clone repository (${REPO_URL})";        clone_repo;     ok "${CURRENT_STEP}"
  CURRENT_STEP="Compose up (PORT=${APP_PORT})";         compose_up;     ok "${CURRENT_STEP}"
  CURRENT_STEP="Health-check (${HEALTH_ENDPOINT})"
  if health_check; then
    ok "${CURRENT_STEP}"
  else
    fail "${CURRENT_STEP}"
    echo "Hint: docker compose -f ${APP_DIR}/docker-compose.yml logs --tail=100"
    exit 1
  fi

  echo
  ok "All steps completed"
}

main "$@"
