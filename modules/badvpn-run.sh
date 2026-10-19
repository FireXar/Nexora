#!/bin/bash
# Lanza un badvpn-udpgw por cada puerto listado en el archivo indicado.
# Uso: badvpn-run.sh /etc/<app>/badvpn.ports
CONF="$1"
BIN="$(command -v badvpn-udpgw)"
[[ -x "$BIN" && -s "$CONF" ]] || exit 1

pids=()
for p in $(cat "$CONF"); do
    "$BIN" --listen-addr "127.0.0.1:$p" --max-clients 500 --max-connections-for-client 10 &
    pids+=($!)
done
trap 'kill "${pids[@]}" 2>/dev/null' TERM INT
wait
