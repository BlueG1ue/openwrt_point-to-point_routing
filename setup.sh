#!/bin/sh
# =================================================================
# Точечный обход блокировок для OpenWrt (WireGuard / AmneziaWG)
# Версия: Неубиваемая 6.0 (Чистые имена интерфейсов и зон)
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

if opkg list-installed | grep -q "^dnsmasq "; then
    echo "Удаляем базовый dnsmasq..."
    opkg remove dnsmasq --force-depends
    echo "Ждем 7 секунд для перезапуска сети..."
    sleep 7
fi

echo "Устанавливаем dnsmasq-full..."
for i in 1 2 3; do
    wait_for_fw
    if opkg install dnsmasq-full --force-overwrite; then
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
    VPN_ZONE="WG"
elif [ "$vpn_choice" = "2" ]; then
    echo -e "\n=== Установка пакетов AmneziaWG ==="
    wait_for_fw
    wget --no-check-certificate -qO /tmp/awg-install.sh https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh
    
    sed -i '/Do you want to configure the amneziawg interface/,$d' /tmp/awg-install.sh
    
    echo "Запускаем сторонний установщик на автопилоте..."
    for i in 1 2 3 4; do
        wait_for_fw
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
    VPN_ZONE="AWG"
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
# Магия: принудительно задаем имя физического устройства, чтобы OpenWrt не лепил префиксы
uci set network.$VPN_IFACE.name="$VPN_IFACE"
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

echo "=== Настройка Firewall (Зона $VPN_ZONE) ==="
uci set firewall.$VPN_ZONE=zone
uci set firewall.$VPN_ZONE.name="$VPN_ZONE"
uci set firewall.$VPN_ZONE.network="$VPN_IFACE"
uci set firewall.$VPN_ZONE.input='ACCEPT'
uci set firewall.$VPN_ZONE.output='ACCEPT'
uci set firewall.$VPN_ZONE.forward='REJECT'
uci set firewall.$VPN_ZONE.masq='1'
uci set firewall.$VPN_ZONE.mtu_fix='1'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest="$VPN_ZONE"

uci commit firewall

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

# --- VPN Domains (nftset) ---
nftset=/rutracker.org/4#inet#fw4#vpn_domains
nftset=/youtube.com/youtu.be/ytimg.com/googlevideo.com/4#inet#fw4#vpn_domains
nftset=/instagram.com/cdninstagram.com/4#inet#fw4#vpn_domains
nftset=/2ip.ru/4#inet#fw4#vpn_domains
EOF

echo "=== Установка службы vpn-routing ==="
cat << EOF > /etc/init.d/vpn-routing
#!/bin/sh /etc/rc.common

START=99

boot() {
    sleep 30
    start
}

start() {
    IFACE="$VPN_IFACE"
    if [ ! -d "/sys/class/net/\$IFACE" ]; then
        return 1
    fi

    nft add set inet fw4 vpn_domains '{ type ipv4_addr; }' 2>/dev/null
    nft flush set inet fw4 vpn_domains

    if [ -f "/etc/static-ips.txt" ]; then
        while read ip; do
            [ -z "\$ip" ] && continue
            echo "\$ip" | grep -q "^#" && continue
            nft add element inet fw4 vpn_domains "{ \$ip }" 2>/dev/null
        done < /etc/static-ips.txt
    fi

    nft add chain inet fw4 vpn_mark
    nft flush chain inet fw4 vpn_mark
    nft add rule inet fw4 vpn_mark ip daddr @vpn_domains meta mark set 0x1
    
    nft add rule inet fw4 srcnat oifname "\$IFACE" masquerade 2>/dev/null
    nft add rule inet fw4 mangle_forward oifname "\$IFACE" tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null

    if ! nft list chain inet fw4 mangle_prerouting | grep -q "vpn_mark"; then
        nft insert rule inet fw4 mangle_prerouting jump vpn_mark
    fi

    ip rule del fwmark 0x1 lookup 100 2>/dev/null
    ip rule add fwmark 0x1 lookup 100
    ip route flush table 100 2>/dev/null
    ip route add default dev \$IFACE table 100

    echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
    echo 0 > /proc/sys/net/ipv4/conf/\$IFACE/rp_filter
}

stop() {
    nft flush chain inet fw4 vpn_mark 2>/dev/null
    ip rule del fwmark 0x1 lookup 100 2>/dev/null
    ip route flush table 100 2>/dev/null
}

restart() {
    stop
    sleep 2
    start
}
EOF
chmod +x /etc/init.d/vpn-routing
/etc/init.d/vpn-routing enable

echo "=== Настройка автозапуска (Hotplug) ==="
mkdir -p /etc/hotplug.d/iface
cat << EOF > /etc/hotplug.d/iface/99-vpn-routing
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
if [ "\$INTERFACE" = "$VPN_IFACE" ] || [ "\$INTERFACE" = "wan" ] || [ "\$INTERFACE" = "wan6" ] || echo "\$INTERFACE" | grep -q "pppoe"; then
    logger -t vpn-routing "Interface \$INTERFACE is UP. Restarting routing in 5s..."
    sleep 5
    /etc/init.d/vpn-routing restart
fi
EOF
chmod +x /etc/hotplug.d/iface/99-vpn-routing

echo "=== Завершение ==="
rm -f /etc/resolv.conf
ln -s /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf

echo "Применяем все сетевые настройки (Возможен кратковременный обрыв связи)..."
/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
/etc/init.d/vpn-routing start

echo ""
echo "✅ ГОТОВО! Роутер настроен."
echo "Зайдите в веб-интерфейс (Сеть -> Интерфейсы), нажмите 'Редактировать' на интерфейсе $VPN_IFACE,"
echo "вставьте ваши ключи и IP-адрес сервера."
