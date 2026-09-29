#!/bin/bash

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }

echo "Limpiando $(hostname)"

pkill -f qemu-system-x86_64 2> /dev/null
sleep 2
pkill -9 -f qemu-system-x86_64 2> /dev/null

if command -v docker > /dev/null 2>&1; then
    docker ps -aq --filter "name=container_" | xargs -r docker rm -f > /dev/null
fi

pkill dnsmasq 2> /dev/null
ip -all netns delete 2> /dev/null

ovs-vsctl --if-exists del-br br-int

for IFACE in $(ip -o link show type tun | awk -F': ' '{print $2}' | cut -d@ -f1); do
    ip link del "$IFACE" 2> /dev/null
done
for IFACE in $(ip -o link show type veth | awk -F': ' '{print $2}' | cut -d@ -f1); do
    ip link del "$IFACE" 2> /dev/null
done

iptables -t mangle -S FORWARD | grep -E 'gw_vlan[0-9]+' | sed 's/^-A/-D/' | while read -r R; do iptables -t mangle $R; done
iptables -t nat -S POSTROUTING | grep -E '192\.168\.(0|2)\.0/24' | sed 's/^-A/-D/' | while read -r R; do iptables -t nat $R; done

if ip link show docker0 > /dev/null 2>&1; then
    iptables -S FORWARD | grep -E 'vlan[0-9]+|192\.168\.(0|2)\.' | sed 's/^-A/-D/' | while read -r R; do iptables $R; done
else
    iptables -F FORWARD
fi

rm -f /var/lib/vms/*.qcow2 /var/lib/vms/*.pid
rm -f /var/lib/misc/dnsmasq*.leases /var/run/dnsmasq-vlan*.pid

echo "$(hostname) limpio"
