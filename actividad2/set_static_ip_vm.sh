#!/bin/bash

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 3 ] && { echo "Uso: $0 <ip_actual> <ip_nueva/prefijo> <gateway> [usuario] [clave]"; exit 1; }

CUR="$1"
ADDR="$2"
GW="$3"
VM_USER="${4:-cirros}"
VM_PASS="${5:-gocubsgo}"
NEW="${ADDR%/*}"
PREFIX="${ADDR#*/}"
MTU=1400
SSH_OPTS="-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

vm() {
    timeout 30 sshpass -p "$VM_PASS" ssh $SSH_OPTS "$VM_USER@$1" "$2"
}

if ! command -v sshpass > /dev/null 2>&1; then
    apt-get update -qq < /dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass < /dev/null > /dev/null
    command -v sshpass > /dev/null 2>&1 || { echo "No se pudo instalar sshpass"; exit 1; }
fi

if [ "$CUR" != "$NEW" ]; then
    ping -c 1 -W 2 "$CUR" > /dev/null 2>&1 || { echo "La VM no responde en $CUR"; exit 1; }

    vm "$CUR" "sudo sh -c 'echo 1 > /proc/sys/net/ipv4/conf/eth0/promote_secondaries; ip link set eth0 mtu $MTU; ip addr add $ADDR dev eth0; killall -9 udhcpc 2> /dev/null; true'"
    RC=$?
    [ "$RC" -eq 5 ] && { echo "Clave incorrecta para $VM_USER@$CUR"; exit 1; }
    [ "$RC" -eq 124 ] && { echo "Timeout: la sesion SSH con $CUR no respondio en 30 s"; exit 1; }
    [ "$RC" -ne 0 ] && { echo "Error al agregar $ADDR en la VM $CUR (codigo $RC)"; exit 1; }

    for _ in $(seq 1 10); do
        ping -c 1 -W 1 "$NEW" > /dev/null 2>&1 && break
        sleep 1
    done
    ping -c 1 -W 2 "$NEW" > /dev/null 2>&1 || { echo "La VM no responde en la nueva IP $NEW"; exit 1; }

    vm "$NEW" "sudo sh -c 'ip addr del $CUR/$PREFIX dev eth0'"
fi

vm "$NEW" "sudo sh -c 'killall -9 udhcpc 2> /dev/null; ip link set eth0 mtu $MTU; ip route del default 2> /dev/null; ip route add default via $GW; echo nameserver 8.8.8.8 > /etc/resolv.conf'"
RC=$?
[ "$RC" -ne 0 ] && { echo "Error al configurar el gateway en la VM $NEW (codigo $RC)"; exit 1; }

echo "VM configurada con IP estatica $ADDR, gateway $GW"
vm "$NEW" "ip -o link show eth0 | grep -o 'mtu [0-9]*'; ip -4 -o addr show eth0; ip route"
