#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_USER="ubuntu"
S1="10.0.10.1"
S2="10.0.10.2"
S3="10.0.10.3"
OVS="br-int"
DATA_IF="ens4"
CLEAN=0
[ "$1" = "--clean" ] && CLEAN=1

run() {
    local HOST="$1" SCRIPT="$2"
    shift 2
    echo ">>> [$HOST] $SCRIPT $*"
    ssh -o BatchMode=yes "$SSH_USER@$HOST" "sudo bash -s $(printf '%q ' "$@")" < "$DIR/$SCRIPT"
}

remote() {
    ssh -o BatchMode=yes "$SSH_USER@$1" "$2"
}

title() {
    echo
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

title "0. Verificando acceso a los nodos"
for H in "$S1" "$S2" "$S3"; do
    remote "$H" 'sudo -n true' || { echo "Sin acceso SSH/sudo a $H"; exit 1; }
    echo "$H OK ($(remote "$H" hostname))"
done

if [ "$CLEAN" -eq 1 ]; then
    title "1. Limpieza de los nodos"
    for H in "$S1" "$S2" "$S3"; do
        run "$H" cleanup.sh
    done
else
    title "1. Sin limpieza: se reutilizan los recursos existentes"
fi

title "2. Server3: master (gateways, DHCP, internet y VLANs aisladas)"
run "$S3" init_master.sh "$DATA_IF"
run "$S3" create_network_vlan.sh 100 192.168.0.0/24 si 192.168.0.10,192.168.0.50
run "$S3" create_network_vlan.sh 200 192.168.2.0/24 si 192.168.2.10,192.168.2.50
run "$S3" internet_to_network.sh 100 192.168.0.0/24
run "$S3" internet_to_network.sh 200 192.168.2.0/24
run "$S3" no_routing_networks.sh 100 200

title "3. Server1: worker con contenedores"
run "$S1" init_worker.sh "$DATA_IF"
for V in 100 200; do
    if remote "$S1" "sudo docker ps --format '{{.Names}}' | grep -qx container_vlan$V"; then
        echo ">>> [$S1] container_vlan$V ya existe, se reutiliza"
    else
        run "$S1" create_container.sh "container_vlan$V" "$OVS" "$V"
    fi
done

title "4. Server2: worker con VMs"
run "$S2" init_worker.sh "$DATA_IF"
for V in 100 200; do
    VNC=$(( V == 100 ? 5901 : 5902 ))
    if remote "$S2" "sudo sh -c '[ -f /var/lib/vms/vm_vlan$V.pid ] && kill -0 \$(cat /var/lib/vms/vm_vlan$V.pid) 2> /dev/null'"; then
        echo ">>> [$S2] vm_vlan$V ya esta en ejecucion, se reutiliza"
    else
        run "$S2" create_vm.sh "vm_vlan$V" "$OVS" "$V" "$VNC"
    fi
done

set +e

title "5. Validacion"
echo "Esperando 60 s a que las VMs obtengan IP..."
sleep 60

echo
echo "--- Topologia OVS ---"
for H in "$S1" "$S2" "$S3"; do
    echo "## $(remote "$H" hostname)"
    remote "$H" "sudo ovs-vsctl show"
done

echo
echo "--- Server3: iptables ---"
remote "$S3" "sudo iptables -S FORWARD; sudo iptables -t nat -S POSTROUTING"

echo
echo "--- Server3: leases DHCP ---"
for V in 100 200; do
    echo "## VLAN $V"
    remote "$S3" "sudo cat /var/lib/misc/dnsmasq-vlan$V.leases"
done

echo
echo "--- Conectividad de VMs desde su gateway ---"
for V in 100 200; do
    for IP in $(remote "$S3" "sudo awk '{print \$3}' /var/lib/misc/dnsmasq-vlan$V.leases"); do
        echo "## ping $IP (VLAN $V)"
        remote "$S3" "ping -c 2 -W 2 $IP"
    done
done

echo
echo "--- Contenedores: IP e internet ---"
for C in container_vlan100 container_vlan200; do
    echo "## $C"
    remote "$S1" "sudo docker exec $C ip -4 -o addr show eth0"
    remote "$S1" "sudo docker exec $C ping -c 3 -W 2 8.8.8.8"
done

echo
echo "--- Aislamiento entre VLANs (debe fallar) ---"
IP200=$(remote "$S1" "sudo docker exec container_vlan200 ip -4 -o addr show eth0" | awk '{print $4}' | cut -d/ -f1)
echo "## container_vlan100 -> container_vlan200 ($IP200)"
if remote "$S1" "sudo docker exec container_vlan100 ping -c 3 -W 2 $IP200"; then
    echo "ERROR: las VLANs no estan aisladas"
else
    echo "OK: las VLANs estan aisladas"
fi

title "Actividad 1 desplegada"
