#!/bin/sh
# =================================================================
# Точечный обход блокировок для OpenWrt (WireGuard / AmneziaWG)
# =================================================================

echo "=== Выбор протокола ==="
echo "1) Стандартный WireGuard (Пакеты из оф. репозитория)"
echo "2) AmneziaWG (Установка пакетов через скрипт Slava-Shchipunov)"
read -p "Введите цифру (1 или 2): " vpn_choice

echo -e "\n=== Подготовка DNS и репозиториев ==="
# Временно фиксируем DNS, чтобы wget и opkg не отвалились в процессе
echo "nameserver 8.8.8.8" > /tmp/resolv.conf.d/resolv.conf.auto
ln -sf /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf

opkg update
opkg remove dnsmasq
opkg install dnsmasq-full

if [ "$vpn_choice" = "1" ]; then
    echo -e "\n=== Установка пакетов WireGuard ==="
    opkg install wireguard-tools luci-app-wireguard
    VPN_PROTO="wireguard"
    VPN_IFACE="WG_VPN"
elif [ "$vpn_choice" = "2" ]; then
    echo -e "\n=== Установка пакетов AmneziaWG ==="
    echo "ВНИМАНИЕ: Сейчас запустится сторонний скрипт."
    echo "-> На вопрос об установке пакетов ответьте: Y"
    echo "-> На вопрос о создании интерфейса ответьте: n (МЫ СОЗДАДИМ ЕГО САМИ)"
    sleep 3
    sh <(wget -qO - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh)
    VPN_PROTO="amneziawg"
    VPN_IFACE="AWG_VPN"
else
    echo "❌ Ошибка выбора. Скрипт остановлен."
    exit 1
fi

echo -e "\n=== Создание интерфейса $VPN_IFACE ==="
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
/etc/init.d/dnsmasq restart
/etc/init.d/vpn-routing start

echo ""
echo "✅ ГОТОВО! Роутер настроен."
echo "Зайдите в веб-интерфейс (Сеть -> Интерфейсы), нажмите 'Редактировать' на интерфейсе $VPN_IFACE,"
echo "вставьте ваши ключи и IP-адрес сервера."
