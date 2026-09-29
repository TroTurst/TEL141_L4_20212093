#!/bin/bash

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root"; exit 1; }
[ $# -lt 2 ] && { echo "Uso: $0 <red/24> <mac>"; exit 1; }

PFX=$(echo "${1%/*}" | cut -d. -f1-3)
MAC=$(echo "$2" | tr '[:upper:]' '[:lower:]')

ip neigh flush to "$PFX.0/24" 2> /dev/null

for i in $(seq 1 254); do
    ping -c 1 -W 1 "$PFX.$i" > /dev/null 2>&1 < /dev/null &
done
wait

ip neigh show | awk -v m="$MAC" 'tolower($5) == m && $0 !~ /FAILED|INCOMPLETE|STALE/ {print $1; exit}'
