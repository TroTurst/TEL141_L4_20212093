#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 1 ] && { echo "Uso: $0 <interfaz1> [interfaz2 ...]"; exit 1; }

ovs-vsctl --may-exist add-br br-int
ip link set br-int up

for IFACE in "$@"; do
    ip link show "$IFACE" > /dev/null 2>&1 || { echo "La interfaz $IFACE no existe"; exit 1; }
    ip link set "$IFACE" up
    ovs-vsctl --may-exist add-port br-int "$IFACE"
done

sysctl -w net.ipv4.ip_forward=1 > /dev/null
iptables -P FORWARD DROP

ovs-vsctl show
echo "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"
iptables -L FORWARD -n | head -1
