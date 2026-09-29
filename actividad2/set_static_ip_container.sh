#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 3 ] && { echo "Uso: $0 <nombre_contenedor> <ip/prefijo> <gateway>"; exit 1; }

NAME="$1"
ADDR="$2"
GW="$3"
MTU=1400

docker ps --format '{{.Names}}' | grep -qx "$NAME" || { echo "El contenedor $NAME no esta en ejecucion"; exit 1; }

docker exec "$NAME" sh -c "
pkill udhcpc 2> /dev/null
ip addr flush dev eth0
ip addr add $ADDR dev eth0
ip link set eth0 mtu $MTU
ip link set eth0 up
ip route del default 2> /dev/null
ip route add default via $GW
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
"

echo "Contenedor $NAME configurado con IP estatica $ADDR, gateway $GW"
docker exec "$NAME" ip -4 -o addr show eth0
docker exec "$NAME" ip route
