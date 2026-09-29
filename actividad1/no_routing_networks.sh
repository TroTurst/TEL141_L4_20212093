#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 2 ] && { echo "Uso: $0 <vlan_id_1> <vlan_id_2>"; exit 1; }

IF1="gw_vlan$1"
IF2="gw_vlan$2"

unrule() { local T="$1"; shift; while iptables -t "$T" -C "$@" 2> /dev/null; do iptables -t "$T" -D "$@"; done; }

unrule filter FORWARD -i "$IF1" -o "$IF2" -j ACCEPT
unrule filter FORWARD -i "$IF2" -o "$IF1" -j ACCEPT

echo "Enrutamiento deshabilitado entre VLAN $1 y VLAN $2"
