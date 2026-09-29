#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 4 ] && { echo "Uso: $0 <nombre_vm> <nombre_ovs> <vlan_id> <puerto_vnc>"; exit 1; }

NAME="$1"
OVS="$2"
VLAN="$3"
VNC="$4"

VM_DIR="/var/lib/vms"
BASE_NAME="cirros-0.5.1-x86_64-disk.img"
BASE="$VM_DIR/$BASE_NAME"
DISK="$VM_DIR/$NAME.qcow2"
PIDFILE="$VM_DIR/$NAME.pid"

[ "$VNC" -ge 5900 ] && DISP=$(( VNC - 5900 )) || DISP="$VNC"
TAP="tap${VLAN}_${DISP}"
TAP="${TAP:0:15}"

if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    kill "$PID" 2> /dev/null || true
    for _ in $(seq 1 10); do kill -0 "$PID" 2> /dev/null || break; sleep 1; done
    kill -9 "$PID" 2> /dev/null || true
    rm -f "$PIDFILE"
else
    pkill -f "qemu-system-x86_64.*-name $NAME " 2> /dev/null || true
fi

ovs-vsctl --if-exists del-port "$OVS" "$TAP"
ip link show "$TAP" > /dev/null 2>&1 && ip tuntap del dev "$TAP" mode tap

rm -f "$DISK"
echo "VM $NAME eliminada (proceso, puerto $TAP, disco $DISK)"

if [ -f "$BASE" ]; then
    DELTAS=0
    for F in "$VM_DIR"/*.qcow2; do
        [ -f "$F" ] || continue
        qemu-img info -U "$F" 2> /dev/null | grep -q "backing file: .*$BASE_NAME" && DELTAS=$(( DELTAS + 1 ))
    done
    if [ "$DELTAS" -eq 0 ]; then
        rm -f "$BASE"
        echo "La imagen base no tenia mas deltas, fue eliminada"
    else
        echo "La imagen base aun tiene $DELTAS delta(s), se conserva"
    fi
fi
