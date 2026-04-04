#!/bin/bash

# Остановка скрипта при критической ошибке
set -euo pipefail

# ----------------------------------------
# Параметры
# ----------------------------------------
SSH_PORT_1=111
SSH_PORT_2=1111
SSHD_CONF="/etc/ssh/sshd_config"

# Настройки проброса ssh для cascade
CURRENT_SSH=222
DESTINATION_SSH=111

# ----------------------------------------
# Функции
# ----------------------------------------

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

disable_ipv6() {
    print_header "Отключить IPv6"
    cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    ysctl --system
}

get_user_input() {
    print_header "Сбор данных перед установкой"
    read -p "Введите имя нового пользователя: " NEW_USER
    read -p "Введите Telegram BOT_TOKEN: " TG_BOT_TOKEN
    read -p "Введите Telegram CHAT_ID: " TG_CHAT_ID
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
    (crontab -l 2>/dev/null | grep -q "0 1 \* \* 5 /sbin/reboot") || (crontab -l 2>/dev/null; echo "0 1 * * 5 /sbin/reboot") | crontab -
}

fix_hosts() {
    print_header "Уведомления и Hosts"
    # 0. Добавляем hostname в /etc/hosts
    CURRENT_HOSTNAME=$(hostname)
    if ! grep -q "127.0.0.1.*$CURRENT_HOSTNAME" /etc/hosts; then
        sed -i "s/^127.0.0.1.*/& $CURRENT_HOSTNAME/" /etc/hosts
    fi
    echo "Готово"
}

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
    print_header "Создание скрипта уведомлений"
    # 1. Создание скрипта уведомлений
    NOTIFY_DIR="/home/$NEW_USER/notify"
    NOTIFY_FILE="$NOTIFY_DIR/notify.sh"

    mkdir -p "$NOTIFY_DIR"

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

BOT_TOKEN="${TG_BOT_TOKEN}"
CHAT_ID="${TG_CHAT_ID}"

USER="\$PAM_USER"
IP="\$PAM_RHOST"
DATE=\$(date "+%d.%m.%Y %H:%M:%S")
HOSTNAME=\$(hostname)

MESSAGE="✅ srv
👤 User: \$USER
🌐 IP: \$IP
📅 Date: \$DATE"

curl -s -X POST \\
  https://api.telegram.org/bot\$BOT_TOKEN/sendMessage \\
  -d chat_id=\$CHAT_ID \\
  -d text="\$MESSAGE" \\
  -d parse_mode="Markdown" >/dev/null 2>&1 &

exit 0
EOF

    # 2. Дать права и владельца
    chmod +x "$NOTIFY_FILE"
    chown -R "$NEW_USER:$NEW_USER" "$NOTIFY_DIR"

    # 3. Добавить в PAM sshd (если еще не добавлено)
    if ! grep -q "pam_exec.so.*notify.sh" /etc/pam.d/sshd; then
        echo "session optional pam_exec.so $NOTIFY_FILE" >> /etc/pam.d/sshd
    fi
    echo "Готово"
}

common_done() {
    echo " "
    echo "========================================="
    echo " Базовая настройка завершена!"
    echo " SSH-порты изменены на $SSH_PORT_1 и $SSH_PORT_2."
    echo " Не забудьте переподключиться по новому порту."
    echo "========================================="
}

# ----------------------------------------
# Prepare
# ----------------------------------------

prepare_base_mode() {
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

prepare_cascade_mode() {
    read -p "Введите IP целевой: " DESTINATION_IP
    read -p "Введите AWG порт целевой (запомните его, желательно меньше 1000): " AWG_PORT

    # ----------------------------------------
    print_header "Текущий IP"
    # ----------------------------------------

    CURRENT_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$CURRENT_IP" ]; then
        echo "Не удалось определить IP"
        exit 1
    fi
    echo "Текущий IP $CURRENT_IP"

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


    # ----------------------------------------
    print_header "Правила iptables"
    # ----------------------------------------

    systemctl enable netfilter-persistent

    cat > /etc/iptables/rules.v4 << EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Общее
-A INPUT -i lo -j ACCEPT
-A INPUT -p icmp -m limit --limit 1/sec --limit-burst 10 -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Разрешить SSH
-A INPUT -p tcp -m tcp --dport ${SSH_PORT_1} -j ACCEPT
-A INPUT -p tcp -m tcp --dport ${SSH_PORT_2} -j ACCEPT

# Проброс AWG соединения
-A FORWARD -p udp -d ${DESTINATION_IP} --dport ${AWG_PORT} -j ACCEPT

# Проброс SSH соединения
-A FORWARD -p tcp -d ${DESTINATION_IP} --dport ${DESTINATION_SSH} -j ACCEPT

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# Проброс AWG соединения
-A PREROUTING -p udp --dport ${AWG_PORT} -j DNAT --to-destination ${DESTINATION_IP}:${AWG_PORT}
-A POSTROUTING -p udp -d ${DESTINATION_IP} --dport ${AWG_PORT} -j SNAT --to-source ${CURRENT_IP}

# Проброс SSH соединения
-A PREROUTING -p tcp --dport ${CURRENT_SSH} -j DNAT --to-destination ${DESTINATION_IP}:${DESTINATION_SSH}
-A POSTROUTING -p tcp -d ${DESTINATION_IP} --dport ${DESTINATION_SSH} -j SNAT --to-source ${CURRENT_IP}

COMMIT
EOF

    # Применить правила без перезагрузки сервера
    iptables-restore < /etc/iptables/rules.v4
}

prepapre_common() {
    check_root
    disable_ipv6
    get_user_input
    setup
    create_user
    no_sudo
    configure_updates
    change_ssh_port
    fail_to_ban
    plan_reboot
    fix_hosts
    disable_root_ask
    reboot_ssh
    configure_notifications
    common_done
}

# ----------------------------------------
# RUN
# ----------------------------------------

# ----------------------------------------
# В каком режиме запушено --mode base или --mode cascade
# ----------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            mode="$2"
            shift 2
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            exit 1
            ;;
    esac
done

# Запуск разного кода в зависимости от mode
case "$mode" in
    base)
        echo "Запуск кода для режима base"
        prepapre_common
        prepare_base_mode
        ;;
    cascade)
        echo "Запуск кода для режима cascade"
        prepapre_common
        prepare_cascade_mode
        ;;
    "")
        echo "Ошибка: не указан --mode (нужен base или cascade)"
        exit 1
        ;;
    *)
        echo "Ошибка: неизвестный режим '$mode'. Используйте base или cascade."
        exit 1
        ;;
esac

