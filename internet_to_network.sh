#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 2 ] && { echo "Uso: $0 <vlan_id> <red/prefijo>"; exit 1; }

VLAN="$1"
CIDR="$2"

ip2int() { local IFS=.; read -r a b c d <<< "$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
rule() { local T="$1"; shift; iptables -t "$T" -C "$@" 2> /dev/null || iptables -t "$T" -A "$@"; }

PREFIX="${CIDR#*/}"
MASK_INT=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
NET="$(int2ip $(( $(ip2int "${CIDR%/*}") & MASK_INT )))/$PREFIX"
GW_IF="vlan${VLAN}"
WAN=$(ip route show default | awk '{print $5; exit}')

[ -z "$WAN" ] && { echo "No se encontro interfaz con ruta por defecto"; exit 1; }
ip link show "$GW_IF" > /dev/null 2>&1 || { echo "No existe $GW_IF, ejecute create_network_vlan.sh"; exit 1; }

rule nat POSTROUTING -s "$NET" -o "$WAN" -j MASQUERADE
rule filter FORWARD -i "$GW_IF" -o "$WAN" -s "$NET" -j ACCEPT
rule filter FORWARD -i "$WAN" -o "$GW_IF" -d "$NET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "Salida a internet habilitada para VLAN $VLAN ($NET) via $WAN"
iptables -t nat -S POSTROUTING | grep -- "$NET" || true
iptables -S FORWARD | grep -- "$GW_IF" || true
