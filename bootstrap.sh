#!/usr/bin/env bash
#
# rustplusplus VPS bootstrap
#
# Запускается ОДНОЙ командой на свежем VPS (Ubuntu/Debian, root или sudo):
#
#   curl -fsSL https://raw.githubusercontent.com/<ТВОЙ_ЮЗЕР>/rpp-toolkit/main/bootstrap.sh | \
#     RPP_GH_TOKEN='ghp_xxx' \
#     RPP_DATA_REPO='<ТВОЙ_ЮЗЕР>/rpp-data' \
#     RPP_BACKUP_PASSWORD='SuperSecretPass' \
#     RPP_DISCORD_TOKEN='...' \
#     RPP_DISCORD_CLIENT_ID='...' \
#     sudo -E bash
#
# Что делает:
#   1. Ставит docker + docker compose (если их ещё нет).
#   2. Создаёт swap-файл, если оперативки мало (важно для 512MB!).
#   3. Скачивает CLI `rpp` и docker-compose.yml.
#   4. Сохраняет секреты в /opt/rpp/.env (только на диске этого VPS, в git не попадают).
#   5. Запускает `rpp start`, который сам восстановит последний бэкап и поднимет бота.
#
set -euo pipefail

# !!! поменяй на адрес своего форка/репозитория с этим тулкитом !!!
TOOLKIT_REPO_RAW="${TOOLKIT_REPO_RAW:-https://raw.githubusercontent.com/YOUR_GH_USER/rpp-toolkit/main}"
INSTALL_DIR="/opt/rpp"

log() { echo -e "\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31mОШИБКА:\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти через sudo -E bash (нужны права root для установки docker)."

: "${RPP_GH_TOKEN:?Нужен GitHub Personal Access Token: export RPP_GH_TOKEN=...}"
: "${RPP_DATA_REPO:?Нужен приватный репозиторий для бэкапов, напр. user/rpp-data}"
: "${RPP_BACKUP_PASSWORD:?Нужен пароль для шифрования бэкапа}"
: "${RPP_DISCORD_TOKEN:?Нужен токен Discord-бота}"
: "${RPP_DISCORD_CLIENT_ID:?Нужен Discord Client ID}"

log "Проверяю зависимости"
if ! command -v docker &>/dev/null; then
  log "Ставлю Docker"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git jq whiptail
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  command -v git &>/dev/null || apt-get install -y git
  command -v gpg &>/dev/null || apt-get install -y gnupg
  command -v whiptail &>/dev/null || apt-get install -y whiptail
fi

TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM_MB" -lt 1024 ] && [ ! -f /swapfile ] && ! swapon --show | grep -q .; then
  log "Мало RAM (${TOTAL_MEM_MB}MB) — создаю 1GB swap-файл"
  fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # чуть снижаем агрессивность подкачки, но не убираем совсем
  sysctl -w vm.swappiness=10 >/dev/null || true
fi

log "Устанавливаю CLI и compose-файл в $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
curl -fsSL "$TOOLKIT_REPO_RAW/rpp" -o /usr/local/bin/rpp
chmod +x /usr/local/bin/rpp
curl -fsSL "$TOOLKIT_REPO_RAW/docker-compose.yml" -o "$INSTALL_DIR/docker-compose.yml"

umask 077
cat > "$INSTALL_DIR/.env" <<EOF
RPP_GH_TOKEN=$RPP_GH_TOKEN
RPP_DATA_REPO=$RPP_DATA_REPO
RPP_BACKUP_PASSWORD=$RPP_BACKUP_PASSWORD
RPP_DISCORD_TOKEN=$RPP_DISCORD_TOKEN
RPP_DISCORD_CLIENT_ID=$RPP_DISCORD_CLIENT_ID
EOF
chmod 600 "$INSTALL_DIR/.env"

log "Готово. Запускаю rpp start (восстановление бэкапа + старт бота)"
rpp start

echo
log "Дальше управляй ботом командой: rpp menu"
log "Перед удалением VPS ОБЯЗАТЕЛЬНО выполни: rpp stop"
