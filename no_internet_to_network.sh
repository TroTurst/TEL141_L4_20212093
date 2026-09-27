#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 2 ] && { echo "Uso: $0 <vlan_id> <red/prefijo>"; exit 1; }

VLAN="$1"
CIDR="$2"

ip2int() { local IFS=.; read -r a b c d <<< "$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
unrule() { local T="$1"; shift; while iptables -t "$T" -C "$@" 2> /dev/null; do iptables -t "$T" -D "$@"; done; }

PREFIX="${CIDR#*/}"
MASK_INT=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
NET="$(int2ip $(( $(ip2int "${CIDR%/*}") & MASK_INT )))/$PREFIX"
GW_IF="vlan${VLAN}"
WAN=$(ip route show default | awk '{print $5; exit}')

[ -z "$WAN" ] && { echo "No se encontro interfaz con ruta por defecto"; exit 1; }

unrule nat POSTROUTING -s "$NET" -o "$WAN" -j MASQUERADE
unrule filter FORWARD -i "$GW_IF" -o "$WAN" -s "$NET" -j ACCEPT
unrule filter FORWARD -i "$WAN" -o "$GW_IF" -d "$NET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "Salida a internet deshabilitada para VLAN $VLAN ($NET)"
