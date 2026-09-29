#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$DIR/.." && pwd)"
SEARCH=("$DIR" "$LAB/actividad2" "$LAB/actividad1")
SSH_USER="ubuntu"
S1="10.0.10.1"
S2="10.0.10.2"
S3="10.0.10.3"
DATA_IF="ens4"
VM_PASS="gocubsgo"
VM_SSH="sshpass -p $VM_PASS ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

declare -A CIDR=( [100]="192.168.0.0/24" [200]="192.168.2.0/24" )
declare -A GW=( [100]="192.168.0.1" [200]="192.168.2.1" )
declare -A RANGE=( [100]="192.168.0.10,192.168.0.50" [200]="192.168.2.10,192.168.2.50" )

find_script() {
    for D in "${SEARCH[@]}"; do
        [ -f "$D/$1" ] && { echo "$D/$1"; return 0; }
    done
    return 1
}

run() {
    local HOST="$1" SCRIPT="$2" FILE
    shift 2
    FILE=$(find_script "$SCRIPT") || { echo "No se encontro $SCRIPT"; exit 1; }
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

lease_ip() {
    remote "$S3" "sudo awk -v m=$2 '\$2==m {print \$3}' /var/lib/misc/dnsmasq-vlan$1.leases 2> /dev/null" || true
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
    "$LAB/actividad1/actividad1.sh" --clean
elif ! endpoints_ok; then
    echo "Faltan contenedores o VMs, se despliega la base con actividad1.sh"
    "$LAB/actividad1/actividad1.sh"
else
    echo "Contenedores y VMs existentes, se reutilizan"
fi

title "2. Server3: IPs actuales de las VMs"
declare -A VM_CUR VM_MAC
for V in 100 200; do
    VM_MAC[$V]=$(vm_mac "vm_vlan$V")
    VM_CUR[$V]=$(run "$S3" find_ip_by_mac.sh "${CIDR[$V]}" "${VM_MAC[$V]}" | tail -n 1 | grep -E '^[0-9.]+$' || true)
    echo "vm_vlan$V (${VM_MAC[$V]}): ${VM_CUR[$V]:-no encontrada}"
    [ -z "${VM_CUR[$V]}" ] && { echo "ERROR: vm_vlan$V no responde, ejecute ./actividad3.sh --clean"; exit 1; }
done

title "3. Server3: DHCP habilitado, sin salida a internet y VLANs aisladas"
run "$S3" init_master.sh "$DATA_IF"
for V in 100 200; do
    run "$S3" create_network_vlan.sh "$V" "${CIDR[$V]}" si "${RANGE[$V]}"
    run "$S3" no_internet_to_network.sh "$V" "${CIDR[$V]}"
done
run "$S3" no_routing_networks.sh 100 200

title "4. Server1: contenedores por DHCP"
for V in 100 200; do
    run "$S1" set_dhcp_container.sh "container_vlan$V"
done

title "5. Server2: VMs por DHCP (via SSH desde Server3)"
declare -A VM_IP
for V in 100 200; do
    if [ "$(lease_ip "$V" "${VM_MAC[$V]}")" = "${VM_CUR[$V]}" ]; then
        echo ">>> vm_vlan$V ya usa DHCP (${VM_CUR[$V]}), se reutiliza"
    else
        run "$S3" set_dhcp_vm.sh "${VM_CUR[$V]}"
    fi
done
for V in 100 200; do
    echo -n "Esperando que vm_vlan$V responda con su IP de DHCP "
    for _ in $(seq 1 30); do
        VM_IP[$V]=$(lease_ip "$V" "${VM_MAC[$V]}")
        [ -n "${VM_IP[$V]}" ] && remote "$S3" "ping -c 1 -W 1 ${VM_IP[$V]} > /dev/null 2>&1" && break
        echo -n "."
        sleep 2
    done
    echo
    remote "$S3" "ping -c 1 -W 1 ${VM_IP[$V]:-0.0.0.0} > /dev/null 2>&1" || { echo "ERROR: vm_vlan$V no responde con IP de DHCP (lease: ${VM_IP[$V]:-ninguno})"; exit 1; }
    echo "vm_vlan$V obtuvo ${VM_IP[$V]}"
done

set +e

title "6. Validacion"

echo "--- Server3: OVS (con puertos dhcp_v*) ---"
remote "$S3" "sudo ovs-vsctl show"

echo
echo "--- Server3: namespaces y dnsmasq ---"
remote "$S3" "ip netns list; pgrep -a dnsmasq"

echo
echo "--- Server3: iptables (sin reglas de internet) ---"
remote "$S3" "sudo iptables -S FORWARD; sudo iptables -t nat -S POSTROUTING; sudo iptables -t mangle -S FORWARD"

echo
echo "--- Server3: leases DHCP ---"
for V in 100 200; do
    echo "## VLAN $V"
    remote "$S3" "sudo cat /var/lib/misc/dnsmasq-vlan$V.leases"
done

declare -A CT_IP
for V in 100 200; do
    CT_IP[$V]=$(remote "$S1" "sudo docker exec container_vlan$V ip -4 -o addr show eth0" | awk '{print $4}' | cut -d/ -f1)
done

echo
echo "--- Contenedores: IP por DHCP, gateway alcanzable y sin internet ---"
for V in 100 200; do
    echo "## container_vlan$V (${CT_IP[$V]})"
    remote "$S1" "sudo docker exec container_vlan$V ip route"
    remote "$S1" "sudo docker exec container_vlan$V ping -c 2 -W 2 ${GW[$V]}"
    if remote "$S1" "sudo docker exec container_vlan$V ping -c 3 -W 2 8.8.8.8"; then
        echo "ERROR: container_vlan$V tiene salida a internet"
    else
        echo "OK: container_vlan$V sin salida a internet"
    fi
done

echo
echo "--- VMs: IP por DHCP, gateway alcanzable y sin internet ---"
for V in 100 200; do
    echo "## vm_vlan$V (${VM_IP[$V]})"
    remote "$S3" "$VM_SSH cirros@${VM_IP[$V]} 'ip -4 -o addr show eth0; ip route; ping -c 2 -W 2 ${GW[$V]}'"
    remote "$S3" "$VM_SSH cirros@${VM_IP[$V]} 'ping -c 3 -W 2 8.8.8.8'"
    case $? in
        0) echo "ERROR: vm_vlan$V tiene salida a internet" ;;
        255) echo "ERROR: no se pudo entrar a vm_vlan$V por SSH" ;;
        *) echo "OK: vm_vlan$V sin salida a internet" ;;
    esac
done

echo
echo "--- Misma VLAN entre servidores (debe funcionar) ---"
for V in 100 200; do
    echo "## container_vlan$V -> vm_vlan$V (${VM_IP[$V]})"
    remote "$S1" "sudo docker exec container_vlan$V ping -c 2 -W 2 ${VM_IP[$V]}" && echo "OK" || echo "ERROR: sin conectividad en la VLAN $V"
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
remote "$S3" "$VM_SSH cirros@${VM_IP[100]} 'ping -c 3 -W 2 ${VM_IP[200]}'"
case $? in
    0) echo "ERROR: las VLANs no estan aisladas" ;;
    255) echo "ERROR: no se pudo entrar a vm_vlan100 por SSH" ;;
    *) echo "OK: las VLANs estan aisladas" ;;
esac

title "Actividad 3 desplegada"
