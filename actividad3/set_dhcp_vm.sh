#!/bin/bash

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 1 ] && { echo "Uso: $0 <ip_actual> [usuario] [clave]"; exit 1; }

CUR="$1"
VM_USER="${2:-cirros}"
VM_PASS="${3:-gocubsgo}"
MTU=1400
SSH_OPTS="-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

if ! command -v sshpass > /dev/null 2>&1; then
    apt-get update -qq < /dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass < /dev/null > /dev/null
    command -v sshpass > /dev/null 2>&1 || { echo "No se pudo instalar sshpass"; exit 1; }
fi

ping -c 1 -W 2 "$CUR" > /dev/null 2>&1 || { echo "La VM no responde en $CUR"; exit 1; }

CMD="sudo sh -c \"trap '' HUP; (sleep 2; killall -9 udhcpc; ip addr flush dev eth0; ip route flush dev eth0; ifdown -f eth0; ip link set eth0 mtu $MTU; ifup eth0; ip link set eth0 mtu $MTU) < /dev/null > /dev/null 2>&1 &\""

timeout 30 sshpass -p "$VM_PASS" ssh $SSH_OPTS "$VM_USER@$CUR" "$CMD"
RC=$?
case "$RC" in
    0|255) ;;
    5) echo "Clave incorrecta para $VM_USER@$CUR"; exit 1 ;;
    124) echo "Timeout: la sesion SSH con $CUR no respondio en 30 s"; exit 1 ;;
    *) echo "Error de sshpass/ssh con $CUR (codigo $RC)"; exit 1 ;;
esac

echo "VM $CUR: IP estatica eliminada, cliente DHCP iniciado"
