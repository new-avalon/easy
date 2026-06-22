#!/bin/bash

# Остановка скрипта при критической ошибке
set -euo pipefail

# ----------------------------------------
# Параметры
# ----------------------------------------
SSH_PORT_1=111
SSH_PORT_2=1111
SSHD_CONF="/etc/ssh/sshd_config"

CURRENT_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

# ----------------------------------------
# Читаем аргументы если есть
# ----------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --new-user)
            NEW_USER="$2"
            shift 2
            ;;
        --server-name)
            SERVER_NAME="$2"
            shift 2
            ;;
        --tg-bot-token)
            TG_BOT_TOKEN="$2"
            shift 2
            ;;
        --tg-chat-id)
            TG_CHAT_ID="$2"
            shift 2
            ;;
        --tg-proxy)
            TG_PROXY="$2"
            shift 2
            ;;
        *)
            echo "Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

timedatectl set-timezone Asia/Yekaterinburg
timedatectl

# ----------------------------------------
# Функции
# ----------------------------------------

# Цветовые коды
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
NC='\033[0m'  # Сброс цвета

function log {
    echo -e "${GREEN}$*${NC}"
}

function read_orange {
    # Первый аргумент — текст приглашения
    # Второй аргумент — имя переменной (необязательно)
    local prompt="$1"
    local var_name="$2"
    
    # Выводим приглашение оранжевым цветом без перевода строки
    echo -en "${ORANGE}${prompt}${NC}"
    
    # Читаем ввод
    if [[ -n "$var_name" ]]; then
        read -r "$var_name"
    else
        read -r
    fi
}

print_header() {
    local text="$1"
    echo " "
    echo "========================================="
    echo " $text"
    echo "========================================="
}


check_root() {
    print_header "Проверка, запущен ли скрипт от root"
    if [ "$EUID" -ne 0 ]; then
        echo "Пожалуйста, запустите скрипт с правами root (sudo ./setup.sh)"
        exit 1
    fi
}

update_hostname() {
        print_header "Обновляем hostname"
  cp /etc/hosts /etc/hosts.bak
    hostnamectl set-hostname "$SERVER_NAME"
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $SERVER_NAME
EOF
}

update_dns() {
        print_header "Обновляем DNS"
    RESOLV="/etc/resolv.conf"
cat > "$RESOLV" <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF
    log "Обновлён $RESOLV"

    INTERFACES="/etc/network/interfaces"
    cp "$INTERFACES" "$INTERFACES.bak"
    # Если строка dns-nameservers существует – заменяем её целиком
    if grep -q "^[[:space:]]*dns-nameservers" "$INTERFACES"; then
        sed -i "s/^[[:space:]]*dns-nameservers.*/    dns-nameservers $DNS/" "$INTERFACES"
    else
        # Если нет – добавляем после первой строки с gateway
        sed -i "/^[[:space:]]*gateway/a\    dns-nameservers $DNS" "$INTERFACES"
    fi
    log "Обновлён $INTERFACES"
}

disable_ipv6() {
    print_header "Отключить IPv6"
    cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system
}

get_user_input() {
    print_header "Сбор данных перед установкой"
    [ -n "${SERVER_NAME:-}" ] || read -p "Введите имя сервера (hostname): " SERVER_NAME
    [ -n "${NEW_USER:-}" ] || read -p "Введите имя нового пользователя: " NEW_USER
}

setup() {
    print_header "Установить"
    apt update -y
    apt upgrade -y

    # Заранее отвечаем "Нет" на вопросы iptables-persistent
    echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections

    # Установка пакетов без интерактивных окон
    DEBIAN_FRONTEND=noninteractive apt install -y \
        sudo unattended-upgrades fail2ban curl iptables-persistent
}

create_user() {
    print_header "Создать пользователей"
    if id "$NEW_USER"; then
        echo "Пользователь $NEW_USER уже существует."
    else
        echo "Создание пользователя $NEW_USER. Пожалуйста, задайте пароль:"
        adduser "$NEW_USER"
    fi
    usermod -aG sudo "$NEW_USER"
}

no_sudo() {
    print_header "Без пароля sudo"
    # Заменяем строку для группы sudo
    sed -i 's/^%sudo\s*ALL=(ALL:ALL)\s*ALL/%sudo   ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
    echo "Права NOPASSWD для группы sudo выданы."
}

configure_updates() {
    print_header "Настройка обновлений"
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    dpkg-reconfigure -f noninteractive -plow unattended-upgrades
    systemctl enable unattended-upgrades
    systemctl start unattended-upgrades
}

change_ssh_port() {
    print_header "Сменить SSH порт"
    # Удаляем старые порты и ставим новые
    sed -i '/^#*Port /d' "$SSHD_CONF"
    echo "Port $SSH_PORT_1" >> "$SSHD_CONF"
    echo "Port $SSH_PORT_2" >> "$SSHD_CONF"
    systemctl restart ssh
    echo "Готово"
}

fail_to_ban() {
    print_header "Настроить fail2ban"
    cat <<EOF > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
port = $SSH_PORT_1,$SSH_PORT_2
backend = systemd
maxretry = 5
findtime = 60m
bantime = 1d
EOF

    systemctl enable fail2ban
    sleep 1
    systemctl restart fail2ban
    sleep 1
    fail2ban-client status sshd
}

plan_reboot() {
    print_header "Перезагрузка раз в неделю"
    # Добавляем задание в cron для root, если его там еще нет
    (crontab -l 2>/dev/null | grep -q "0 1 \* \* 5 /sbin/reboot") || (crontab -l 2>/dev/null; echo "0 1 * * 5 /sbin/reboot") | crontab - || true
}

#fix_hosts() {
#    print_header "Уведомления и Hosts"
#    # 0. Добавляем hostname в /etc/hosts
#    CURRENT_HOSTNAME=$(hostname)
#    if ! grep -q "127.0.0.1.*$CURRENT_HOSTNAME" /etc/hosts; then
#        sed -i "s/^127.0.0.1.*/& $CURRENT_HOSTNAME/" /etc/hosts
#    fi
#    echo "Готово"
#}

disable_root_ask() {
    print_header "Запретить вход root"
    read -n 1 -p "Запретить вход root? (y/n): " answer
    echo "" # Делаем перенос строки для красоты

    if [[ "$answer" =~ ^[yY]$ ]]; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONF"
        echo "Запрешено"
    else
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONF"
        echo "Разрешено"
    fi
}

reboot_ssh() {
    print_header "Перезагрузка SSH"
    systemctl restart ssh
    echo "Готово"
}

configure_notifications() {
    [ -n "${TG_BOT_TOKEN:-}" ] || read -p "TG_BOT_TOKEN: " TG_BOT_TOKEN
    [ -n "${TG_CHAT_ID:-}" ] || read -p "TG_CHAT_ID: " TG_CHAT_ID
    [ -n "${TG_PROXY:-}" ] || read -p "TG_PROXY (опционально): " TG_PROXY

    # Проверка: если хотя бы один токен пуст → ошибка
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        echo "Уведомления не будут созданы"
        # TODO: удалять файлы
        return 0
    fi

    log "Сохранение конфиг файла: /etc/tg-send"


    cat > /etc/tg-send << EOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_CHAT_ID=$TG_CHAT_ID
TG_PROXY=$TG_PROXY
EOF

    log "Сохранение рабочего скрипта: /usr/bin/tg-send" 
    cat > /usr/bin/tg-send << 'EOF2'
#!/bin/sh
CONFIG="/etc/tg-send"

if [ -f "$CONFIG" ]; then
    . "$CONFIG"
fi

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo "ERROR: TG_BOT_TOKEN or TG_CHAT_ID not set in $CONFIG" >&2
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "Usage: $0 <message>" >&2
    exit 1
fi

# объединяем все переданные аргументы в одну строку
MSG="$*"
HOST=${TG_PROXY:-api.telegram.org}

curl -s --http1.1 -X POST "https://${HOST}/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    >/dev/null 2>&1
EOF2

    chmod +x /usr/bin/tg-send
    tg-send "test"
    log "Отправлено тестовое сообщение"


    print_header "Создание скрипта уведомлений при логине"

    # 1. Создание скрипта уведомлений
    NOTIFY_FILE="/usr/bin/notify-login.sh"

    # Внимание: переменные PAM экранированы (\$PAM_SERVICE), 
    # а токены подставятся напрямую из наших переменных bash.
    cat << EOF > "$NOTIFY_FILE"
#!/bin/bash
# Только для SSH (игнорируем login, sudo и другие)
if [ "\$PAM_SERVICE" != "sshd" ]; then
    exit 0
fi

# Работаем только при открытии сессии (игнорируем выход)
if [ "\$PAM_TYPE" != "open_session" ]; then
    exit 0
fi

USER="\$PAM_USER"
IP="\$PAM_RHOST"
DATE=\$(date "+%d.%m.%Y %H:%M:%S")

MESSAGE="✅ ${SERVER_NAME}
👤 User: \$USER
🌐 IP: \$IP
📅 Date: \$DATE"

tg-send "\$MESSAGE"
exit 0
EOF

    # 2. Дать права и владельца
    chown root:root "$NOTIFY_FILE"
    chmod 700 "$NOTIFY_FILE"

    # 3. Добавить в PAM sshd (если еще не добавлено)
    if ! grep -q "pam_exec.so.*notify.sh" /etc/pam.d/sshd; then
        echo "session optional pam_exec.so $NOTIFY_FILE" >> /etc/pam.d/sshd
    fi
    echo "Готово"
}

base_iptables() {
    # ----------------------------------------
    print_header "Правила iptables"
    # ----------------------------------------

    systemctl enable netfilter-persistent

    cat <<EOF > /etc/iptables/rules.v4
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -p icmp -m limit --limit 1/sec --limit-burst 10 -j ACCEPT
-A INPUT -p tcp -m tcp --dport ${SSH_PORT_1} -j ACCEPT
-A INPUT -p tcp -m tcp --dport ${SSH_PORT_2} -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
EOF

    # Применить правила без перезагрузки сервера
    iptables-restore < /etc/iptables/rules.v4
}

install_zram() {
    print_header "Установка zram"
    apt install -y zram-tools
    systemctl enable zramswap
    systemctl start zramswap
    if systemctl is-active --quiet zramswap; then
        log "[ОК] Служба zramswap успешно запущена!"
    else
        log "[ОШИБКА!!!] Что-то пошло не так, служба zramswap не активна."
        exit 1
    fi
}

optimize_net() {
    print_header "Оптимизация сети"
    grep -q "^net.core.default_qdisc" /etc/sysctl.conf \
        && sed -i 's/^net.core.default_qdisc.*/net.core.default_qdisc = fq/' /etc/sysctl.conf \
        || echo "net.core.default_qdisc = fq" | tee -a /etc/sysctl.conf > /dev/null

    grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf \
        && sed -i 's/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/' /etc/sysctl.conf \
        || echo "net.ipv4.tcp_congestion_control = bbr" | tee -a /etc/sysctl.conf > /dev/null

    sysctl -p
    print_header "Оптимизация сети. Готово"
}

common_done() {
    echo " "
    echo "========================================="
    echo " Базовая настройка завершена!"
    echo " SSH-порты изменены на $SSH_PORT_1 и $SSH_PORT_2."
    echo " Не забудьте переподключиться по новому порту."
    echo "========================================="
}

configure_logs() {
    print_header "Хранить логи 1 день"
    sed -i -E 's/^[# ]*MaxRetentionSec=.*/MaxRetentionSec=1d/; s/^[# ]*MaxFileSec=.*/MaxFileSec=1d/' /etc/systemd/journald.conf
    journalctl --rotate
    journalctl --vacuum-time=1d
    systemctl restart systemd-journald
}

# ----------------------------------------
# Prepare
# ----------------------------------------

prepare_cascade_mode() {
    CONFIG="/etc/cascade_firewall.conf"

    # --- Создать дефолтный конфиг, если отсутствует ---
    if [[ ! -f "$CONFIG" ]]; then
      cat > "$CONFIG" << 'DEFAULT'
# icmp: on/off
icmp off

# Проброс: локальный_порт  адрес:порт_назначения
# ssh
#forward_tcp 211  99.99.99.99:111
#forward_tcp 2111  99.99.99.99:1111

# amnezia
#forward_udp 401  88.88.88.88:401
#forward_udp 402  99.99.99.99:402
DEFAULT
      echo "Создан дефолтный конфиг: $CONFIG"
      echo "Отредактируйте его и запустите скрипт повторно."
      exit 0
    fi

    # ----------------------------------------
    print_header "Включить ip_forward"
    # ----------------------------------------

    # Удаляем все возможные упоминания параметра из всех конфигураций
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null
    # Создаём отдельный файл с высоким приоритетом
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
    # Применяем настройки
    sysctl -p /etc/sysctl.d/99-ip-forward.conf
    # И сразу в ядро (на случай, если нужно без перезагрузки)
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Дефолты
    ICMP="off"
    SSH_PORTS=()
    FWD_TCP=()
    FWD_UDP=()

    # Парсинг конфига
    while IFS= read -r line; do
      line="${line%%#*}"
      [[ -z "$line" ]] && continue
      read -r key rest <<< "$line"
      case "$key" in
        icmp)        ICMP="$rest" ;;
        ssh_port)    SSH_PORTS+=("$rest") ;;
        forward_tcp) FWD_TCP+=("$rest") ;;
        forward_udp) FWD_UDP+=("$rest") ;;
      esac
    done < "$CONFIG"

    # --- SSH порты из sshd_config ---
    SSH_PORTS=()
    while IFS= read -r line; do
      line="${line%%#*}"
      [[ -z "$line" ]] && continue
      read -r key val <<< "$line"
      [[ "${key,,}" == "port" ]] && SSH_PORTS+=("$val")
    done < /etc/ssh/sshd_config
    [[ ${#SSH_PORTS[@]} -eq 0 ]] && SSH_PORTS=(22)



    # --- Генерация правил ---
    {
    cat <<'HEADER'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
HEADER

    if [[ "$ICMP" == "on" ]]; then
      echo "-A INPUT -p icmp -m limit --limit 1/sec --limit-burst 10 -j ACCEPT"
    fi

    for port in "${SSH_PORTS[@]}"; do
      echo "-A INPUT -p tcp -m tcp --dport $port -j ACCEPT"
    done

    for entry in "${FWD_TCP[@]}"; do
      read -r lp dest <<< "$entry"
      echo "-A FORWARD -p tcp -d ${dest%%:*} --dport ${dest##*:} -j ACCEPT"
    done

    for entry in "${FWD_UDP[@]}"; do
      read -r lp dest <<< "$entry"
      echo "-A FORWARD -p udp -d ${dest%%:*} --dport ${dest##*:} -j ACCEPT"
    done

    echo "COMMIT"
    echo ""

    cat <<'NAT'
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
NAT

    for entry in "${FWD_TCP[@]}"; do
      read -r lp dest <<< "$entry"
      echo "-A PREROUTING -p tcp --dport $lp -j DNAT --to-destination $dest"
      echo "-A POSTROUTING -p tcp -d ${dest%%:*} --dport ${dest##*:} -j SNAT --to-source $CURRENT_IP"
    done

    for entry in "${FWD_UDP[@]}"; do
      read -r lp dest <<< "$entry"
      echo "-A PREROUTING -p udp --dport $lp -j DNAT --to-destination $dest"
      echo "-A POSTROUTING -p udp -d ${dest%%:*} --dport ${dest##*:} -j SNAT --to-source $CURRENT_IP"
    done

    echo "COMMIT"

    } > /etc/iptables/rules.v4

    # Применить
    systemctl enable netfilter-persistent 2>/dev/null
    iptables-restore < /etc/iptables/rules.v4

    echo "=== Применённый конфиг ==="
    echo "IP: $CURRENT_IP | ICMP: $ICMP | SSH (sshd_config): ${SSH_PORTS[*]}"
    echo "TCP форварды: ${#FWD_TCP[@]} | UDP форварды: ${#FWD_UDP[@]}"
    echo ""
    iptables -L -n --line-numbers
    echo ""
    iptables -t nat -L -n --line-numbers
}

prepapre_common() {
    check_root
    get_user_input
    update_hostname
    update_dns
    disable_ipv6
    setup
    create_user
    no_sudo
    configure_updates
    change_ssh_port
    fail_to_ban
    plan_reboot
    #fix_hosts
    disable_root_ask
    reboot_ssh
    configure_notifications
    base_iptables
    install_zram
    optimize_net
    common_done
    configure_logs
}

# ----------------------------------------
# RUN
# ----------------------------------------

while true; do
    clear
    log "========================="
    log "        МЕНЮ            "
    log "    (что-то одно)       "
    log "========================="
    log "1) Базовая настройка"
    log "2) Настрока под RU мост"
    log "0) Выход"
    log "========================="
    read_orange "Выберите пункт: " choice

    case $choice in
        1)
            echo "Базовая настройка"
            prepapre_common
            ;;
        2)
            echo "Настройка под RU мост"
            prepare_cascade_mode
            ;;
        0)
            log "Выход из программы."
            exit 0
            ;;
        *)
            log "Неверный ввод. Попробуйте снова."
            ;;
    esac
done

