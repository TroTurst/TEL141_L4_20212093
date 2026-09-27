#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 3 ] && { echo "Uso: $0 <vlan_id> <red/prefijo> <dhcp: si|no> [inicio,fin]"; exit 1; }

VLAN="$1"
CIDR="$2"
DHCP=$(echo "$3" | tr '[:upper:]' '[:lower:]')
RANGE="$4"

ip2int() { local IFS=.; read -r a b c d <<< "$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }

[[ "$VLAN" =~ ^[0-9]+$ ]] && [ "$VLAN" -ge 1 ] && [ "$VLAN" -le 4094 ] || { echo "VLAN ID invalido"; exit 1; }
[[ "$CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { echo "Formato CIDR invalido"; exit 1; }

IP="${CIDR%/*}"
PREFIX="${CIDR#*/}"
MASK_INT=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
NET_INT=$(( $(ip2int "$IP") & MASK_INT ))
MASK=$(int2ip "$MASK_INT")
GW=$(int2ip $(( NET_INT + 1 )))
DHCP_IP=$(int2ip $(( NET_INT + 2 )))

ovs-vsctl br-exists br-int || { echo "No existe br-int, ejecute init_master.sh"; exit 1; }

GW_IF="vlan${VLAN}"
ovs-vsctl --may-exist add-port br-int "$GW_IF" tag="$VLAN" -- set interface "$GW_IF" type=internal
ip addr replace "$GW/$PREFIX" dev "$GW_IF"
ip link set "$GW_IF" up

case "$DHCP" in
    si|yes|on|1|true|habilitado)
        [ -z "$RANGE" ] && { echo "Debe indicar el rango DHCP (inicio,fin)"; exit 1; }
        START="${RANGE%%[,-]*}"
        END="${RANGE##*[,-]}"
        NS="ns-dhcp-${VLAN}"
        DHCP_IF="dhcp${VLAN}"
        PIDFILE="/var/run/dnsmasq-vlan${VLAN}.pid"

        ip netns list | grep -qw "$NS" || ip netns add "$NS"
        ovs-vsctl --may-exist add-port br-int "$DHCP_IF" tag="$VLAN" -- set interface "$DHCP_IF" type=internal
        ip link show "$DHCP_IF" > /dev/null 2>&1 && ip link set "$DHCP_IF" netns "$NS"
        ip netns exec "$NS" ip link set lo up
        ip netns exec "$NS" ip addr replace "$DHCP_IP/$PREFIX" dev "$DHCP_IF"
        ip netns exec "$NS" ip link set "$DHCP_IF" up

        [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2> /dev/null || true
        ip netns exec "$NS" dnsmasq \
            --interface="$DHCP_IF" \
            --bind-interfaces \
            --port=0 \
            --dhcp-range="$START,$END,$MASK,12h" \
            --dhcp-option=3,"$GW" \
            --dhcp-option=6,8.8.8.8 \
            --pid-file="$PIDFILE"

        echo "DHCP activo en $NS ($DHCP_IP) rango $START - $END, gateway $GW"
        ;;
    no|off|0|false|deshabilitado)
        echo "DHCP deshabilitado para VLAN $VLAN"
        ;;
    *)
        echo "Valor de DHCP invalido (si|no)"; exit 1
        ;;
esac

echo "VLAN $VLAN creada: red $(int2ip $NET_INT)/$PREFIX, gateway $GW en $GW_IF"
