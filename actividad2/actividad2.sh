#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="$(cd "$DIR/../actividad1" && pwd)"
SSH_USER="ubuntu"
S1="10.0.10.1"
S2="10.0.10.2"
S3="10.0.10.3"
OVS="br-int"
DATA_IF="ens4"
VM_PASS="gocubsgo"
VM_SSH="sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

declare -A CIDR=( [100]="192.168.0.0/24" [200]="192.168.2.0/24" )
declare -A GW=( [100]="192.168.0.1" [200]="192.168.2.1" )
declare -A CT_IP=( [100]="192.168.0.11" [200]="192.168.2.11" )
declare -A VM_IP=( [100]="192.168.0.12" [200]="192.168.2.12" )

run() {
    local HOST="$1" SCRIPT="$2" FILE
    shift 2
    if [ -f "$DIR/$SCRIPT" ]; then FILE="$DIR/$SCRIPT"; else FILE="$BASE/$SCRIPT"; fi
    [ -f "$FILE" ] || { echo "No se encontro $SCRIPT"; exit 1; }
    echo ">>> [$HOST] $SCRIPT $*"
    ssh -o BatchMode=yes "$SSH_USER@$HOST" "sudo bash -s $(printf '%q ' "$@")" < "$FILE"
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

vm_mac() {
    echo -n "$1" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/'
}

endpoints_ok() {
    for V in 100 200; do
        remote "$S1" "sudo docker ps --format '{{.Names}}' | grep -qx container_vlan$V" || return 1
        remote "$S2" "sudo sh -c '[ -f /var/lib/vms/vm_vlan$V.pid ] && kill -0 \$(cat /var/lib/vms/vm_vlan$V.pid) 2> /dev/null'" || return 1
    done
}

title "0. Verificando acceso a los nodos"
for H in "$S1" "$S2" "$S3"; do
    remote "$H" 'sudo -n true' || { echo "Sin acceso SSH/sudo a $H"; exit 1; }
    echo "$H OK ($(remote "$H" hostname))"
done

title "1. Topologia base (Actividad 1)"
if [ "$1" = "--clean" ]; then
    echo "Despliegue desde cero con actividad1.sh --clean"
    "$BASE/actividad1.sh" --clean
elif ! endpoints_ok; then
    echo "Faltan contenedores o VMs, se despliega la base con actividad1.sh"
    "$BASE/actividad1.sh"
else
    echo "Contenedores y VMs existentes, se reutilizan"
fi

title "2. Server3: IPs actuales de las VMs"
declare -A VM_CUR
for V in 100 200; do
    MAC=$(vm_mac "vm_vlan$V")
    VM_CUR[$V]=$(remote "$S3" "sudo awk -v m=$MAC '\$2==m {print \$3}' /var/lib/misc/dnsmasq-vlan$V.leases 2> /dev/null" || true)
    if [ -z "${VM_CUR[$V]}" ]; then
        VM_CUR[$V]=$(run "$S3" find_ip_by_mac.sh "${CIDR[$V]}" "$MAC" | tail -n 1 | grep -E '^[0-9.]+$' || true)
    fi
    echo "vm_vlan$V ($MAC): ${VM_CUR[$V]:-no encontrada}"
done

title "3. Server3: gateways sin DHCP, con salida a internet y VLANs aisladas"
run "$S3" init_master.sh "$DATA_IF"
for V in 100 200; do
    run "$S3" create_network_vlan.sh "$V" "${CIDR[$V]}" no
    run "$S3" internet_to_network.sh "$V" "${CIDR[$V]}"
done
run "$S3" no_routing_networks.sh 100 200

title "4. Server1: IPs estaticas en contenedores"
for V in 100 200; do
    run "$S1" set_static_ip_container.sh "container_vlan$V" "${CT_IP[$V]}/24" "${GW[$V]}"
done

title "5. Server2: IPs estaticas en VMs (via SSH desde Server3)"
for V in 100 200; do
    if [ -n "${VM_CUR[$V]}" ]; then
        run "$S3" set_static_ip_vm.sh "${VM_CUR[$V]}" "${VM_IP[$V]}/24" "${GW[$V]}"
    else
        echo "ERROR: no se conoce la IP actual de vm_vlan$V, ejecute ./actividad2.sh --clean"
        exit 1
    fi
done

set +e

title "6. Validacion"

echo "--- Server3: OVS (sin puertos dhcp_v*) ---"
remote "$S3" "sudo ovs-vsctl show"

echo
echo "--- Server3: namespaces y dnsmasq (deben estar vacios) ---"
remote "$S3" "echo \"Namespaces: \$(ip netns list | wc -l)\"; pgrep -a dnsmasq || echo 'dnsmasq no esta en ejecucion'"

echo
echo "--- Server3: iptables ---"
remote "$S3" "sudo iptables -S FORWARD; sudo iptables -t nat -S POSTROUTING; sudo iptables -t mangle -S FORWARD"

echo
echo "--- Contenedores: IP estatica e internet ---"
for V in 100 200; do
    echo "## container_vlan$V"
    remote "$S1" "sudo docker exec container_vlan$V ip -4 -o addr show eth0"
    remote "$S1" "sudo docker exec container_vlan$V ping -c 3 -W 2 8.8.8.8"
done

echo
echo "--- VMs: IP estatica e internet ---"
for V in 100 200; do
    echo "## vm_vlan$V (${VM_IP[$V]})"
    remote "$S3" "$VM_SSH cirros@${VM_IP[$V]} 'ip -4 -o addr show eth0; ip route | grep default; ping -c 3 -W 2 8.8.8.8'"
done

echo
echo "--- Aislamiento entre VLANs (debe fallar) ---"
echo "## container_vlan100 -> container_vlan200 (${CT_IP[200]})"
if remote "$S1" "sudo docker exec container_vlan100 ping -c 3 -W 2 ${CT_IP[200]}"; then
    echo "ERROR: las VLANs no estan aisladas"
else
    echo "OK: las VLANs estan aisladas"
fi
echo "## vm_vlan100 -> vm_vlan200 (${VM_IP[200]})"
if remote "$S3" "$VM_SSH cirros@${VM_IP[100]} 'ping -c 3 -W 2 ${VM_IP[200]}'"; then
    echo "ERROR: las VLANs no estan aisladas"
else
    echo "OK: las VLANs estan aisladas"
fi

title "Actividad 2 desplegada"
