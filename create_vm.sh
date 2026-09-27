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
URL="https://download.cirros-cloud.net/0.5.1/$BASE_NAME"
DISK="$VM_DIR/$NAME.qcow2"
PIDFILE="$VM_DIR/$NAME.pid"

[ "$VNC" -ge 5900 ] && DISP=$(( VNC - 5900 )) || DISP="$VNC"
TAP="tap${VLAN}_${DISP}"
TAP="${TAP:0:15}"
MAC=$(echo -n "$NAME" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/')

ovs-vsctl br-exists "$OVS" || { echo "No existe el OVS $OVS"; exit 1; }
[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2> /dev/null && { echo "La VM $NAME ya esta en ejecucion"; exit 1; }
ss -ltn | grep -q ":$(( 5900 + DISP )) " && { echo "El puerto VNC $(( 5900 + DISP )) ya esta en uso"; exit 1; }

mkdir -p "$VM_DIR"

if [ ! -f "$BASE" ]; then
    echo "Imagen base no encontrada, descargando..."
    wget -q -O "$BASE" "$URL" || { rm -f "$BASE"; echo "Error al descargar la imagen"; exit 1; }
fi

[ -f "$DISK" ] || qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" > /dev/null

ip link show "$TAP" > /dev/null 2>&1 || ip tuntap add dev "$TAP" mode tap
ip link set "$TAP" up
ovs-vsctl --may-exist add-port "$OVS" "$TAP" tag="$VLAN"

ACCEL=""
[ -e /dev/kvm ] && ACCEL="-enable-kvm"

qemu-system-x86_64 $ACCEL \
    -name "$NAME" \
    -m 256 \
    -vnc 0.0.0.0:"$DISP" \
    -netdev tap,id="$TAP",ifname="$TAP",script=no,downscript=no \
    -device e1000,netdev="$TAP",mac="$MAC" \
    -drive file="$DISK",format=qcow2 \
    -pidfile "$PIDFILE" \
    -daemonize

echo "VM $NAME creada"
echo "  PID:    $(cat "$PIDFILE")"
echo "  Disco:  $DISK (base $BASE_NAME)"
echo "  TAP:    $TAP en $OVS (VLAN $VLAN)"
echo "  MAC:    $MAC"
echo "  VNC:    puerto $(( 5900 + DISP ))"
