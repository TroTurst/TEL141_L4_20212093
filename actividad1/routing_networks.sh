#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 2 ] && { echo "Uso: $0 <vlan_id_1> <vlan_id_2>"; exit 1; }

IF1="gw_vlan$1"
IF2="gw_vlan$2"

rule() { local T="$1"; shift; iptables -t "$T" -C "$@" 2> /dev/null || iptables -t "$T" -A "$@"; }

for IFACE in "$IF1" "$IF2"; do
    ip link show "$IFACE" > /dev/null 2>&1 || { echo "No existe $IFACE, ejecute create_network_vlan.sh"; exit 1; }
done

rule filter FORWARD -i "$IF1" -o "$IF2" -j ACCEPT
rule filter FORWARD -i "$IF2" -o "$IF1" -j ACCEPT

echo "Enrutamiento habilitado entre VLAN $1 y VLAN $2"
iptables -S FORWARD | grep -E -- "$IF1|$IF2" || true
