#!/bin/sh
# =================================================================
# Точечный обход блокировок для OpenWrt (WireGuard / AmneziaWG)
# Версия: Неубиваемая (С лоботомией сторонних скриптов)
# =================================================================

wait_for_fw() {
    echo -n "Ожидание сети"
    while ! ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; do
        echo -n "."
        sleep 2
    done
    while ! wget -q --spider --no-check-certificate https://downloads.openwrt.org >/dev/null 2>&1; do
        echo -n "."
        sleep 2
    done
    echo " OK!"
}

safe_update() {
    local attempt=1
    local max_attempts=5
    while [ $attempt -le $max_attempts ]; do
        echo "Обновление репозиториев (Попытка $attempt из $max_attempts)..."
        wait_for_fw
        if opkg update 2>&1 | grep -q "wget returned 4\|Failed to download"; then
            echo "⚠️ Ошибка при скачивании списков. Ждем 5 сек и пробуем снова..."
            sleep 5
            attempt=$((attempt+1))
        else
            echo "✅ Репозитории успешно обновлены!"
            return 0
        fi
    done
    echo "❌ Не удалось обновить репозитории. Скрипт остановлен."
    exit 1
}

echo "=== Выбор протокола ==="
echo "1) Стандартный WireGuard (Пакеты из оф. репозитория)"
echo "2) AmneziaWG (Установка пакетов через скрипт Slava-Shchipunov)"
read -p "Введите цифру (1 или 2): " vpn_choice

echo -e "\n=== Подготовка DNS и репозиториев ==="
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

safe_update

if opkg list-installed | grep -q "^dnsmasq$"; then
    echo "Удаляем базовый dnsmasq..."
    opkg remove dnsmasq
    echo "Ждем 7 секунд для перезапуска сети..."
    sleep 7
fi

echo "Устанавливаем dnsmasq-full..."
for i in 1 2 3; do
    wait_for_fw
    if opkg install dnsmasq-full; then
        echo "✅ dnsmasq-full успешно установлен!"
        echo "⏳ Даем системе 10 секунд на стабилизацию..."
        sleep 10
        break
    else
        echo "⚠️ Ошибка скачивания. Ждем 5 сек и пробуем снова..."
        sleep 5
    fi
done

if [ "$vpn_choice" = "1" ]; then
    echo -e "\n=== Установка пакетов WireGuard ==="
    for i in 1 2 3; do
        wait_for_fw
        if opkg install wireguard-tools luci-app-wireguard; then
            echo "✅ Пакеты WireGuard установлены!"
            break
        else
            echo "⚠️ Ошибка скачивания пакетов WG. Пробуем снова..."
            sleep 5
        fi
    done
    VPN_PROTO="wireguard"
    VPN_IFACE="WG_VPN"
elif [ "$vpn_choice" = "2" ]; then
    echo -e "\n=== Установка пакетов AmneziaWG ==="
    wait_for_fw
    wget --no-check-certificate -qO /tmp/awg-install.sh https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh
    
    # ЛОБОТОМИЯ: Удаляем кусок скрипта, который настраивает интерфейс и вызывает сбои в автоматизации
    sed -i '/Do you want to configure the amneziawg interface/,$d' /tmp/awg-install.sh
    
    echo "Запускаем сторонний установщик на автопилоте..."
    for i in 1 2 3 4; do
        wait_for_fw
        # yes "y" бесконечно отвечает Да на любые оставшиеся вопросы (установка пакетов и языка)
        if yes "y" | sh /tmp/awg-install.sh; then
            echo "✅ Пакеты AmneziaWG успешно установлены!"
            break
        else
            echo "⚠️ Ошибка стороннего скрипта. Ждем 10 сек и пробуем снова..."
            sleep 10
        fi
    done
    VPN_PROTO="amneziawg"
    VPN_IFACE="AWG_VPN"
else
    echo "❌ Ошибка выбора."
    rm -f /etc/resolv.conf
    ln -s /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf
    exit 1
fi

echo -e "\n=== Создание интерфейса $VPN_IFACE ==="
sleep 5

uci set network.$VPN_IFACE=interface
uci set network.$VPN_IFACE.proto="$VPN_PROTO"
uci set network.$VPN_IFACE.listen_port='51820'
uci add_list network.$VPN_IFACE.addresses='10.8.1.10/32'

uci set network.vpn_peer="${VPN_PROTO}_${VPN_IFACE}"
uci set network.vpn_peer.public_key='ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ'
uci set network.vpn_peer.endpoint_host='ВСТАВЬ_IP_СЕРВЕРА'
uci set network.vpn_peer.endpoint_port='51820'
uci set network.vpn_peer.persistent_keepalive='25'
uci set network.vpn_peer.route_allowed_ips='0'
uci add_list network.vpn_peer.allowed_ips='0.0.0.0/0'

uci commit network
/etc/init.d/network restart

echo "=== Настройка Firewall (Зона VPN) ==="
uci set firewall.VPN_ZONE=zone
uci set firewall.VPN_ZONE.name='VPN_ZONE'
uci set firewall.VPN_ZONE.network="$VPN_IFACE"
uci set firewall.VPN_ZONE.input='ACCEPT'
uci set firewall.VPN_ZONE.output='ACCEPT'
uci set firewall.VPN_ZONE.forward='REJECT'
uci set firewall.VPN_ZONE.masq='1'
uci set firewall.VPN_ZONE.mtu_fix='1'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='VPN_ZONE'

uci commit firewall
/etc/init.d/firewall restart

echo "=== Создание списков маршрутизации ==="
cat << 'EOF' > /etc/static-ips.txt
# Telegram
91.105.192.100
149.154.167.0/24
# Instagram / Meta
31.13.72.52
72.145.26.121
EOF

cat << 'EOF' >> /etc/dnsmasq.conf

# --- VPN Domains
