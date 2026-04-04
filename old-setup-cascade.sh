#!/bin/bash

# Остановка скрипта при критической ошибке
set -e

# =========================================
# Настройки портов SSH
# =========================================
SSH_PORT_1=111
SSH_PORT_2=1111
SSHD_CONF="/etc/ssh/sshd_config"

# =========================================
# Пробросить ssh
# =========================================
CURRENT_SSH=222
DESTINATION_SSH=111

# =========================================
# Текущий IP
# =========================================
CURRENT_IP=$(hostname -I | awk '{print $1}')
if [ -z "$CURRENT_IP" ]; then
    echo "Не удалось определить IP"
    exit 1
fi
echo "Текущий IP $CURRENT_IP"

# =========================================
# Проверка, запущен ли скрипт от root
# =========================================
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root (sudo ./setup.sh)"
  exit 1
fi

echo " "
echo "========================================="
echo " Включить ip_forward"
echo "========================================="
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
sysctl net.ipv4.ip_forward


echo " "
echo "========================================="
echo " Отключить IPv6"
echo "========================================="
cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system

echo " "
echo "========================================="
echo " Сбор данных перед установкой"
echo "========================================="
read -p "Введите имя нового пользователя: " NEW_USER
read -p "Введите IP целевой: " DESTINATION_IP
read -p "Введите AWG порт целевой (запомните его, желательно меньше 1000): " AWG_PORT

echo " "
echo "========================================="
echo " [Установить]"
echo "========================================="
apt update -y
apt upgrade -y

# Заранее отвечаем "Нет" на вопросы iptables-persistent
echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections

# Установка пакетов без интерактивных окон
DEBIAN_FRONTEND=noninteractive apt install -y \
    sudo unattended-upgrades fail2ban curl iptables-persistent

echo " "
echo "========================================="
echo " [Создать пользователей]"
echo "========================================="
if id "$NEW_USER"; then
    echo "Пользователь $NEW_USER уже существует."
else
    echo "Создание пользователя $NEW_USER. Пожалуйста, задайте пароль:"
    adduser "$NEW_USER"
fi
usermod -aG sudo "$NEW_USER"

echo " "
echo "========================================="
echo " [Без пароля sudo]"
echo "========================================="
# Заменяем строку для группы sudo
sed -i 's/^%sudo\s*ALL=(ALL:ALL)\s*ALL/%sudo   ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
echo "Права NOPASSWD для группы sudo выданы."

echo " "
echo "========================================="
echo " [Настройка обновлений]"
echo "========================================="
echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
dpkg-reconfigure -f noninteractive -plow unattended-upgrades
systemctl enable unattended-upgrades
systemctl start unattended-upgrades

echo " "
echo "========================================="
echo " [Сменить SSH порт]"
echo "========================================="
# Удаляем старые порты и ставим новые
sed -i '/^#*Port /d' "$SSHD_CONF"
echo "Port $SSH_PORT_1" >> "$SSHD_CONF"
echo "Port $SSH_PORT_2" >> "$SSHD_CONF"
systemctl restart ssh
echo "Готово"

echo " "
echo "========================================="
echo " [Настроить fail2ban]"
echo "========================================="
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

echo " "
echo "========================================="
echo " [Правила iptables]"
echo "========================================="
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

echo " "
echo "========================================="
echo " [Перезагрузка раз в неделю]"
echo "========================================="
# Добавляем задание в cron для root, если его там еще нет
(crontab -l 2>/dev/null | grep -q "0 1 \* \* 5 /sbin/reboot") || (crontab -l 2>/dev/null; echo "0 1 * * 5 /sbin/reboot") | crontab -

echo " "
echo "========================================="
echo " [Уведомления и Hosts]"
echo "========================================="
# 0. Добавляем hostname в /etc/hosts
CURRENT_HOSTNAME=$(hostname)
if ! grep -q "127.0.0.1.*$CURRENT_HOSTNAME" /etc/hosts; then
    sed -i "s/^127.0.0.1.*/& $CURRENT_HOSTNAME/" /etc/hosts
fi
echo "Готово"

echo " "
echo "========================================="
echo " [Запретить вход root]"
echo "========================================="
read -n 1 -p "Запретить вход root? (y/n): " answer
echo "" # Делаем перенос строки для красоты

if [[ "$answer" =~ ^[yY]$ ]]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONF"
    echo "Запрешено"
else
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONF"
    echo "Разрешено"
fi

echo " "
echo "========================================="
echo " [Перезагрузка SSH]"
echo "========================================="
systemctl restart ssh
echo "Готово"

echo " "
echo "========================================="
echo " Установка успешно завершена!"
echo " SSH-порты изменены на $SSH_PORT_1 и $SSH_PORT_2."
echo " Не забудьте переподключиться по новому порту."
echo " Current IP: $CURRENT_IP"
echo " Destination IP: $DESTINATION_IP"
echo " AWG Port: $AWG_PORT"
echo " Проброс SSH: $CURRENT_SSH -> $DESTINATION_SSH"
echo "========================================="
