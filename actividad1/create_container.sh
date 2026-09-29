#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 3 ] && { echo "Uso: $0 <nombre_contenedor> <nombre_ovs> <vlan_id> [imagen]"; exit 1; }

NAME="$1"
OVS="$2"
VLAN="$3"
IMAGE="${4:-alpine}"
MTU=1400

ID=$(echo -n "$NAME" | md5sum | cut -c1-6)
VETH_OVS="vo_$ID"
VETH_CT="vc_$ID"

ovs-vsctl br-exists "$OVS" || { echo "No existe el OVS $OVS"; exit 1; }
docker ps -a --format '{{.Names}}' | grep -qx "$NAME" && { echo "El contenedor $NAME ya existe"; exit 1; }

docker image inspect "$IMAGE" > /dev/null 2>&1 || docker pull "$IMAGE" > /dev/null
docker run -d --name "$NAME" --hostname "$NAME" --network none --cap-add=NET_ADMIN "$IMAGE" sleep infinity > /dev/null

PID=$(docker inspect -f '{{.State.Pid}}' "$NAME")

ip link add "$VETH_OVS" type veth peer name "$VETH_CT"
ip link set "$VETH_CT" netns "$PID"
nsenter -t "$PID" -n ip link set "$VETH_CT" name eth0
nsenter -t "$PID" -n ip link set lo up
nsenter -t "$PID" -n ip link set eth0 mtu "$MTU"
nsenter -t "$PID" -n ip link set eth0 up
ip link set "$VETH_OVS" mtu "$MTU"
ip link set "$VETH_OVS" up
ovs-vsctl --may-exist add-port "$OVS" "$VETH_OVS" tag="$VLAN"

docker exec "$NAME" udhcpc -i eth0 -n -q -t 5 -T 3 > /dev/null 2>&1 || echo "Advertencia: $NAME no obtuvo IP por DHCP"

echo "Contenedor $NAME creado"
echo "  Imagen: $IMAGE"
echo "  veth:   $VETH_OVS en $OVS (VLAN $VLAN)"
echo "  IP:     $(docker exec "$NAME" ip -4 -o addr show eth0 | awk '{print $4}')"
