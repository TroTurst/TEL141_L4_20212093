#!/bin/bash

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 1 ] && { echo "Uso: $0 <nombre_contenedor>"; exit 1; }

NAME="$1"
MTU=1400

docker ps --format '{{.Names}}' | grep -qx "$NAME" || { echo "El contenedor $NAME no esta en ejecucion"; exit 1; }

docker exec "$NAME" sh -c "
pkill udhcpc 2> /dev/null
ip addr flush dev eth0
ip link set eth0 mtu $MTU
ip link set eth0 up
udhcpc -i eth0 -n -q -t 5 -T 3 > /dev/null 2>&1
" || { echo "El contenedor $NAME no obtuvo IP por DHCP"; exit 1; }

echo "Contenedor $NAME configurado por DHCP"
docker exec "$NAME" ip -4 -o addr show eth0
docker exec "$NAME" ip route
