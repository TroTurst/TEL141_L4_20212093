#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$DIR/.." && pwd)"
SEARCH=("$DIR" "$LAB/actividad3" "$LAB/actividad2" "$LAB/actividad1")
SSH_USER="ubuntu"
S1="10.0.10.1"
S2="10.0.10.2"
S3="10.0.10.3"
DATA_IF="ens4"
VM_PASS="gocubsgo"
VM_SSH="sshpass -p $VM_PASS ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

declare -A CIDR=( [100]="192.168.0.0/24" [200]="192.168.2.0/24" )
declare -A GW=( [100]="192.168.0.1" [200]="192.168.2.1" )
RANGE200="192.168.2.10,192.168.2.50"
CT100_IP="192.168.0.11"
VM100_IP="192.168.0.12"

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

expect_ok() {
    if eval "$2"; then echo "OK: $1"; else echo "ERROR: $1"; fi
}

expect_fail() {
    eval "$2"
    case $? in
        0) echo "ERROR: $1" ;;
        255) echo "ERROR: no se pudo entrar por SSH" ;;
        *) echo "OK: $1" ;;
    esac
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
    [ -z "${VM_CUR[$V]}" ] && { echo "ERROR: vm_vlan$V no responde, ejecute ./actividad4.sh --clean"; exit 1; }
done

title "3. Server3: DHCP solo en VLAN 200, sin internet y con ruteo entre VLANs"
run "$S3" init_master.sh "$DATA_IF"
run "$S3" create_network_vlan.sh 100 "${CIDR[100]}" no
run "$S3" create_network_vlan.sh 200 "${CIDR[200]}" si "$RANGE200"
for V in 100 200; do
    run "$S3" no_internet_to_network.sh "$V" "${CIDR[$V]}"
done
run "$S3" routing_networks.sh 100 200

title "4. Server1: contenedores (VLAN 100 estatica, VLAN 200 por DHCP)"
run "$S1" set_static_ip_container.sh container_vlan100 "$CT100_IP/24" "${GW[100]}"
run "$S1" set_dhcp_container.sh container_vlan200

title "5. Server2: VMs (VLAN 100 estatica, VLAN 200 por DHCP)"
run "$S3" set_static_ip_vm.sh "${VM_CUR[100]}" "$VM100_IP/24" "${GW[100]}"

if [ "$(lease_ip 200 "${VM_MAC[200]}")" = "${VM_CUR[200]}" ]; then
    echo ">>> vm_vlan200 ya usa DHCP (${VM_CUR[200]}), se reutiliza"
else
    run "$S3" set_dhcp_vm.sh "${VM_CUR[200]}"
fi
echo -n "Esperando que vm_vlan200 responda con su IP de DHCP "
for _ in $(seq 1 30); do
    VM200_IP=$(lease_ip 200 "${VM_MAC[200]}")
    [ -n "$VM200_IP" ] && remote "$S3" "ping -c 1 -W 1 $VM200_IP > /dev/null 2>&1" && break
    echo -n "."
    sleep 2
done
echo
remote "$S3" "ping -c 1 -W 1 ${VM200_IP:-0.0.0.0} > /dev/null 2>&1" || { echo "ERROR: vm_vlan200 no responde con IP de DHCP (lease: ${VM200_IP:-ninguno})"; exit 1; }
echo "vm_vlan200 obtuvo $VM200_IP"

set +e

CT200_IP=$(remote "$S1" "sudo docker exec container_vlan200 ip -4 -o addr show eth0" | awk '{print $4}' | cut -d/ -f1)

title "6. Validacion"

echo "--- Server3: OVS (solo dhcp_v200) ---"
remote "$S3" "sudo ovs-vsctl show"

echo
echo "--- Server3: namespaces y dnsmasq (solo VLAN 200) ---"
remote "$S3" "ip netns list; pgrep -a dnsmasq"

echo
echo "--- Server3: iptables (ruteo entre VLANs, sin internet) ---"
remote "$S3" "sudo iptables -S FORWARD; sudo iptables -t nat -S POSTROUTING; sudo iptables -t mangle -S FORWARD"

echo
echo "--- Server3: leases DHCP VLAN 200 ---"
remote "$S3" "sudo cat /var/lib/misc/dnsmasq-vlan200.leases"

echo
echo "--- Direccionamiento de los endpoints ---"
echo "## container_vlan100 (estatica)"
remote "$S1" "sudo docker exec container_vlan100 sh -c 'ip -4 -o addr show eth0; ip route'"
echo "## container_vlan200 (DHCP)"
remote "$S1" "sudo docker exec container_vlan200 sh -c 'ip -4 -o addr show eth0; ip route'"
echo "## vm_vlan100 (estatica)"
remote "$S3" "$VM_SSH cirros@$VM100_IP 'ip -4 -o addr show eth0; ip route'"
echo "## vm_vlan200 (DHCP)"
remote "$S3" "$VM_SSH cirros@$VM200_IP 'ip -4 -o addr show eth0; ip route'"

echo
echo "--- Ruteo entre VLANs (debe funcionar) ---"
echo "## container_vlan100 ($CT100_IP) -> container_vlan200 ($CT200_IP)"
expect_ok "ruteo contenedor VLAN 100 -> contenedor VLAN 200" "remote $S1 'sudo docker exec container_vlan100 ping -c 3 -W 2 $CT200_IP'"
echo "## container_vlan200 ($CT200_IP) -> vm_vlan100 ($VM100_IP)"
expect_ok "ruteo contenedor VLAN 200 -> VM VLAN 100" "remote $S1 'sudo docker exec container_vlan200 ping -c 3 -W 2 $VM100_IP'"
echo "## vm_vlan100 ($VM100_IP) -> vm_vlan200 ($VM200_IP)"
expect_ok "ruteo VM VLAN 100 -> VM VLAN 200" "remote $S3 \"$VM_SSH cirros@$VM100_IP 'ping -c 3 -W 2 $VM200_IP'\""
echo "## traceroute container_vlan100 -> vm_vlan200 (debe pasar por ${GW[100]})"
remote "$S1" "sudo docker exec container_vlan100 traceroute -n -m 3 -w 2 $VM200_IP"

echo
echo "--- Sin salida a internet (debe fallar) ---"
echo "## container_vlan100"
expect_fail "container_vlan100 sin internet" "remote $S1 'sudo docker exec container_vlan100 ping -c 3 -W 2 8.8.8.8'"
echo "## container_vlan200"
expect_fail "container_vlan200 sin internet" "remote $S1 'sudo docker exec container_vlan200 ping -c 3 -W 2 8.8.8.8'"
echo "## vm_vlan100"
expect_fail "vm_vlan100 sin internet" "remote $S3 \"$VM_SSH cirros@$VM100_IP 'ping -c 3 -W 2 8.8.8.8'\""
echo "## vm_vlan200"
expect_fail "vm_vlan200 sin internet" "remote $S3 \"$VM_SSH cirros@$VM200_IP 'ping -c 3 -W 2 8.8.8.8'\""

title "Actividad 4 desplegada"
