#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# 1. КОНСТАНТЫ И ПРОВЕРКИ
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}🚀 Инициализация RustPlusPlus (rpp) Toolkit...${NC}"

if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}❌ Скрипт необходимо запускать от root (sudo -E bash)${NC}"
    exit 1
fi

# Проверка обязательных переменных (адаптировано под ваши RPP_ переменные)
GH_PAT="${RPP_GH_TOKEN:-}"
GH_REPO="${RPP_DATA_REPO:-}"
GPG_PASS="${RPP_BACKUP_PASSWORD:-}"

if [[ -z "$GH_PAT" || -z "$GH_REPO" || -z "$GPG_PASS" ]]; then
    echo -e "${RED}❌ Ошибка: Не заданы переменные окружения RPP_GH_TOKEN, RPP_DATA_REPO или RPP_BACKUP_PASSWORD.${NC}"
    exit 1
fi

# ==========================================
# 2. БАЗОВАЯ БЕЗОПАСНОСТЬ И УТИЛИТЫ
# ==========================================
echo -e "${GREEN}[1/7] Установка зависимостей и настройка безопасности...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq curl git gpg ufw fail2ban unattended-upgrades iptables jq tar

# Настройка Swap (2GB) для 512MB RAM VPS
if [ ! -f /swapfile ]; then
    echo "Создание Swap 2GB..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    sysctl vm.swappiness=10
    echo "vm.swappiness=10" >> /etc/sysctl.conf
fi

# Настройка UFW
SSH_PORT=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' || echo 22)
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw --force enable >/dev/null

# Настройка Fail2ban для SSH
cat << EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime = 18000
findtime = 3600
EOF
systemctl restart fail2ban

# Автообновления
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades

# ==========================================
# 3. УСТАНОВКА DOCKER
# ==========================================
if ! command -v docker &> /dev/null; then
    echo -e "${GREEN}[2/7] Установка Docker...${NC}"
    curl -fsSL [https://get.docker.com](https://get.docker.com) | bash
fi

# ==========================================
# 4. ПОДГОТОВКА СРЕДЫ RPP
# ==========================================
echo -e "${GREEN}[3/7] Подготовка рабочей директории...${NC}"
mkdir -p /opt/rpp/{credentials,instances,logs}
cd /opt/rpp

# Генерация docker-compose.yml (Оптимизировано для 512MB RAM)
cat << 'EOF' > /opt/rpp/docker-compose.yml
version: '3.8'
services:
  bot:
    image: ghcr.io/alexemanuelol/rustplusplus:latest
    container_name: rpp_bot
    restart: always
    env_file: .env
    environment:
      - TS_NODE_TRANSPILE_ONLY=true
      - NODE_OPTIONS=--max-old-space-size=400 --dns-result-order=ipv4first
    volumes:
      - ./credentials:/app/credentials
      - ./instances:/app/instances
      - ./logs:/app/logs
    deploy:
      resources:
        limits:
          memory: 450M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      rpp_net:
        ipv4_address: 172.25.0.2

networks:
  rpp_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.25.0.0/24
EOF

# ==========================================
# 5. ВОССТАНОВЛЕНИЕ ИЛИ ИНИЦИАЛИЗАЦИЯ
# ==========================================
echo -e "${GREEN}[4/7] Работа с состоянием (Backup/Restore)...${NC}"
export GH_URL="https://oauth2:${GH_PAT}@[github.com/$](https://github.com/$){GH_REPO}.git"

rm -rf /opt/rpp/.git_backup
if git clone --depth 1 "$GH_URL" /opt/rpp/.git_backup; then
    if [ -f /opt/rpp/.git_backup/backup.tar.gz.gpg ]; then
        echo -e "${YELLOW}Найден бэкап! Восстанавливаем...${NC}"
        gpg --batch --yes --passphrase "$GPG_PASS" --decrypt /opt/rpp/.git_backup/backup.tar.gz.gpg > /opt/rpp/backup.tar.gz
        tar -xzf /opt/rpp/backup.tar.gz -C /opt/rpp
        rm /opt/rpp/backup.tar.gz
    else
        echo -e "${YELLOW}Бэкап не найден в репозитории. Чистая установка.${NC}"
    fi
else
    echo -e "${RED}❌ Не удалось клонировать репозиторий. Проверьте RPP_GH_TOKEN и RPP_DATA_REPO.${NC}"
    exit 1
fi
rm -rf /opt/rpp/.git_backup

# Создание/обновление .env с секретами
touch /opt/rpp/.env
chmod 600 /opt/rpp/.env
echo "GH_PAT=${GH_PAT}" > /opt/rpp/.env
echo "GH_REPO=${GH_REPO}" >> /opt/rpp/.env
echo "GPG_PASS=${GPG_PASS}" >> /opt/rpp/.env
if [[ -n "${RPP_DISCORD_TOKEN:-}" ]]; then
    echo "DISCORD_TOKEN=${RPP_DISCORD_TOKEN}" >> /opt/rpp/.env
fi
if [[ -n "${RPP_DISCORD_CLIENT_ID:-}" ]]; then
    echo "DISCORD_CLIENT_ID=${RPP_DISCORD_CLIENT_ID}" >> /opt/rpp/.env
fi

# ==========================================
# 6. УСТАНОВКА ZAPRET (ОБХОД DPI ДЛЯ DOCKER)
# ==========================================
echo -e "${GREEN}[5/7] Настройка обхода блокировки Discord (Zapret NFQWS)...${NC}"
ZAPRET_DIR="/opt/zapret_core"
rm -rf "$ZAPRET_DIR"
git clone --depth 1 [https://github.com/bol-van/zapret.git](https://github.com/bol-van/zapret.git) "$ZAPRET_DIR"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) BIN_DIR="x86_64" ;;
    aarch64) BIN_DIR="aarch64" ;;
    *) echo "Архитектура $ARCH не поддерживается из коробки. Нужна компиляция." && exit 1 ;;
esac

cp "$ZAPRET_DIR/binaries/my/$BIN_DIR/nfqws" /usr/local/bin/nfqws
chmod +x /usr/local/bin/nfqws

# Создаем systemd-сервис для nfqws
cat << 'EOF' > /etc/systemd/system/nfqws-rpp.service
[Unit]
Description=NFQWS DPI bypass for RPP Docker
After=network.target docker.service

[Service]
Type=simple
ExecStartPre=-/sbin/iptables -D FORWARD -s 172.25.0.0/24 -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass
ExecStartPre=/sbin/iptables -I FORWARD -s 172.25.0.0/24 -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass
# Стратегия split2 обычно лучшая для Discord (TLS/HTTPS+WSS)
ExecStart=/usr/local/bin/nfqws --qnum=200 --dpi-desync=split2 --dpi-desync-split-pos=1 --dpi-desync-fooling=md5sig
ExecStopPost=-/sbin/iptables -D FORWARD -s 172.25.0.0/24 -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nfqws-rpp.service

# ==========================================
# 7. ГЕНЕРАЦИЯ CLI-УТИЛИТЫ `rpp`
# ==========================================
echo -e "${GREEN}[6/7] Создание CLI тулкита...${NC}"
cat << 'EOF' > /usr/local/bin/rpp
#!/usr/bin/env bash
set -euo pipefail

cd /opt/rpp
source /opt/rpp/.env

cmd_start() {
    echo "Запуск бота..."
    docker compose up -d
}

cmd_backup() {
    echo "Создание зашифрованного архива..."
    tar -czf backup.tar.gz credentials/ instances/
    gpg --batch --yes --passphrase "$GPG_PASS" --symmetric --cipher-algo AES256 -o backup.tar.gz.gpg backup.tar.gz
    rm backup.tar.gz

    echo "Отправка в GitHub..."
    rm -rf .git_backup
    git clone "https://oauth2:${GH_PAT}@[github.com/$](https://github.com/$){GH_REPO}.git" .git_backup
    cd .git_backup
    
    # Сиротская ветка перезаписывает всю историю одним коммитом
    git checkout --orphan backups 2>/dev/null || true
    cp ../backup.tar.gz.gpg .
    git add backup.tar.gz.gpg
    git commit -m "Backup $(date +'%Y-%m-%d %H:%M:%S')"
    git push -f origin backups
    
    cd ..
    rm -rf .git_backup backup.tar.gz.gpg
    echo -e "\033[0;32mБэкап успешно сохранён!\033[0m"
}

cmd_stop() {
    echo "Остановка бота..."
    docker compose down
    cmd_backup
    echo "Бот остановлен, бэкап сделан."
}

cmd_restart() {
    cmd_backup
    docker compose restart
    echo "Бот перезапущен."
}

cmd_status() {
    echo "=== Статус Контейнера ==="
    docker ps -f name=rpp_bot
    echo ""
    echo "=== Потребление ресурсов ==="
    docker stats rpp_bot --no-stream || echo "Контейнер выключен"
    echo ""
    echo "=== Память сервера ==="
    free -m
    echo ""
    echo "=== Обход DPI (NFQWS) ==="
    systemctl is-active --quiet nfqws-rpp && echo -e "\033[0;32mАктивен и работает\033[0m" || echo -e "\033[0;31mНе работает\033[0m"
}

cmd_logs() {
    docker compose logs -f --tail=100
}

cmd_update() {
    echo "Обновление системы и бота..."
    apt-get update && apt-get upgrade -y
    cmd_backup
    docker compose pull
    docker compose up -d
    echo "Обновление завершено."
}

cmd_check_dpi() {
    echo "Проверка связи с Discord API через бота..."
    if ! docker ps | grep -q rpp_bot; then
        echo "Контейнер не запущен. Сначала выполните rpp start."
        exit 1
    fi
    HTTP_CODE=$(docker exec -it rpp_bot curl -s -o /dev/null -w "%{http_code}" -m 5 [https://discord.com/api/v10/gateway](https://discord.com/api/v10/gateway) || echo "TIMEOUT")
    if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "200" || "$HTTP_CODE" == "429" ]]; then
        echo -e "\033[0;32mУСПЕХ!\033[0m Подключение к Discord работает (Код: $HTTP_CODE)."
    else
        echo -e "\033[0;31mОШИБКА!\033[0m Блокировка DPI всё ещё действует или нет сети (Ответ: $HTTP_CODE)."
        echo "Попробуйте выполнить: systemctl restart nfqws-rpp.service"
    fi
}

cmd_menu() {
    PS3="Выберите действие (введите номер): "
    options=("Start" "Stop (с бэкапом)" "Restart" "Logs" "Status" "Backup (без остановки)" "Check DPI Bypass" "Update (OS + Bot)" "Exit")
    select opt in "${options[@]}"; do
        case $opt in
            "Start") cmd_start; break ;;
            "Stop (с бэкапом)") cmd_stop; break ;;
            "Restart") cmd_restart; break ;;
            "Logs") cmd_logs; break ;;
            "Status") cmd_status; break ;;
            "Backup (без остановки)") cmd_backup; break ;;
            "Check DPI Bypass") cmd_check_dpi; break ;;
            "Update (OS + Bot)") cmd_update; break ;;
            "Exit") exit 0 ;;
            *) echo "Неверный вариант" ;;
        esac
    done
}

case "${1:-menu}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    backup) cmd_backup ;;
    check-dpi) cmd_check_dpi ;;
    update) cmd_update ;;
    menu) cmd_menu ;;
    *)
        echo "Использование: rpp {start|stop|restart|status|logs|backup|check-dpi|update|menu}"
        exit 1
        ;;
esac
EOF
chmod +x /usr/local/bin/rpp

# ==========================================
# 8. ФИНАЛ
# ==========================================
echo -e "${GREEN}[7/7] Запуск бота...${NC}"
rpp start

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}✅ RustPlusPlus успешно установлен и запущен!${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo -e "Папки смонтированы в: /opt/rpp"
echo -e "Трафик Discord заворачивается в Anti-DPI (Zapret)."
echo -e "Для управления введите команду: ${YELLOW}rpp${NC}"
echo ""
rpp check-dpi
