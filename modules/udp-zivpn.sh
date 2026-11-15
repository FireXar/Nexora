# Nexora · UDP-ZIVPN / ZipVPN basado en el original LACASITAMX
ZIVPN_SVC="${APP_ID}-udp-zivpn"; ZIVPN_DIR="${APP_DIR}/udp-zivpn"; ZIVPN_BIN="/usr/local/bin/nexora-zipvpn"; ZIVPN_AUTH="${ZIVPN_DIR}/authSSH"
zivpn_port(){ python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("listen",":5667").rsplit(":",1)[-1])' "$ZIVPN_DIR/config.json" 2>/dev/null || echo 5667; }
zivpn_fw_add(){ local i="$1" p="$2"; iptables -t nat -C PREROUTING -i "$i" -p udp --dport 6000:19999 -m comment --comment nexora-zivpn -j DNAT --to-destination ":$p" 2>/dev/null || iptables -t nat -A PREROUTING -i "$i" -p udp --dport 6000:19999 -m comment --comment nexora-zivpn -j DNAT --to-destination ":$p"; }
zivpn_install(){
 header 'UDP-ZIVPN · INSTALAR'; mkdir -p "$ZIVPN_DIR"; apt-get install -y curl openssl python3 iptables >/dev/null 2>&1; local t; t=$(mktemp)
 if ! curl -fL --retry 2 'https://raw.githubusercontent.com/lacasitamx/BIN/main/BINARIOS/UDP/ZipVPN/udp-x64_v1.bin' -o "$t"; then rm -f "$t"; err 'Falló descarga ZipVPN'; pause; return; fi
 install -m755 "$t" "$ZIVPN_BIN"; rm -f "$t"
 if ! curl -fL --retry 2 'https://github.com/lacasitamx/UDP/raw/main/autSSH' -o "$ZIVPN_AUTH"; then rm -f "$ZIVPN_BIN"; err 'Falló descarga authSSH'; pause; return; fi; chmod 750 "$ZIVPN_AUTH"
 openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=nexora-zivpn' -keyout "$ZIVPN_DIR/zivpn.key" -out "$ZIVPN_DIR/zivpn.crt" >/dev/null 2>&1 || { err 'Falló certificado'; pause; return; }
 cat > "$ZIVPN_DIR/config.json" <<CFG
{
 "listen": ":5667", "cert": "$ZIVPN_DIR/zivpn.crt", "key": "$ZIVPN_DIR/zivpn.key", "obfs": "lacasita",
 "auth": {"mode": "external", "config": {"cmd": "$ZIVPN_AUTH"}}
}
CFG
 cat > "/etc/systemd/system/${ZIVPN_SVC}.service" <<UNIT
[Unit]
Description=Nexora UDP-ZIVPN (ZipVPN)
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$ZIVPN_DIR
ExecStart=$ZIVPN_BIN -config $ZIVPN_DIR/config.json server
Restart=always
RestartSec=3
Environment=PATH=$ZIVPN_DIR:/usr/bin:/bin
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
 sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1; sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1; systemctl daemon-reload && systemctl enable --now "$ZIVPN_SVC"
 local iface; iface=$(ip -4 route show default 2>/dev/null|awk 'NR==1{print $5}'); [[ -n "$iface" ]] && zivpn_fw_add "$iface" 5667
 if command -v ufw >/dev/null && ufw status 2>/dev/null|grep -q 'Status: active'; then ufw allow 6000:19999/udp >/dev/null; ufw allow 5667/udp >/dev/null; fi
 if svc_on "$ZIVPN_SVC"; then ok 'UDP-ZIVPN activo · 5667 · rango 6000:19999'; else err "No inició. journalctl -u $ZIVPN_SVC -n 40"; fi; pause
}
zivpn_change_port(){ local p; read -rp ' Nuevo puerto UDP [5667]: ' p; p=${p:-5667}; [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1&&p<=65535)) || { err 'Puerto inválido'; pause; return; }; python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["listen"]=":"+sys.argv[2]; json.dump(d,open(f,"w"),indent=2)' "$ZIVPN_DIR/config.json" "$p"; systemctl restart "$ZIVPN_SVC"; [[ -n "$i" ]] && zivpn_fw_add "$i" "$p"; ok "Puerto actualizado a $p"; pause; }
zivpn_change_obfs(){ local v; read -rp ' Nuevo OBFS [lacasita]: ' v; [[ -n "$v" ]] || return; python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["obfs"]=sys.argv[2]; json.dump(d,open(f,"w"),indent=2)' "$ZIVPN_DIR/config.json" "$v"; systemctl restart "$ZIVPN_SVC"; ok 'OBFS actualizado'; pause; }
zivpn_remove(){ header 'UDP-ZIVPN · DESINSTALAR'; confirm_si || return; systemctl disable --now "$ZIVPN_SVC" 2>/dev/null; local i p; i=$(ip -4 route show default 2>/dev/null|awk 'NR==1{print $5}'); p=$(zivpn_port); if [[ -n "$i" ]]; then while iptables -t nat -C PREROUTING -i "$i" -p udp --dport 6000:19999 -m comment --comment nexora-zivpn -j DNAT --to-destination ":$p" 2>/dev/null; do iptables -t nat -D PREROUTING -i "$i" -p udp --dport 6000:19999 -m comment --comment nexora-zivpn -j DNAT --to-destination ":$p"; done; fi; rm -f "/etc/systemd/system/${ZIVPN_SVC}.service" "$ZIVPN_BIN"; rm -rf "$ZIVPN_DIR"; systemctl daemon-reload; ok 'UDP-ZIVPN eliminado'; warn 'Las reglas UFW no se borran para no afectar reglas compartidas'; pause; }
zivpn_menu(){ local o; while true; do header 'UDP-ZIVPN'; if svc_on "$ZIVPN_SVC"; then ok 'Estado: ACTIVO'; elif unit_exists "$ZIVPN_SVC"; then warn 'Estado: DETENIDO'; else warn 'Estado: NO INSTALADO'; fi; item 1 'Instalar / reconfigurar'; item 2 'Cambiar puerto'; item 3 'Cambiar OBFS'; item 4 'Iniciar / detener'; item 5 'Reiniciar'; item 6 'Desinstalar'; item 0 'Volver'; line; read -rp ' Opción: ' o; case $o in 1) zivpn_install;; 2) [[ -f "$ZIVPN_DIR/config.json" ]] && zivpn_change_port || { err 'Instala primero'; pause; };; 3) [[ -f "$ZIVPN_DIR/config.json" ]] && zivpn_change_obfs || { err 'Instala primero'; pause; };; 4) unit_exists "$ZIVPN_SVC" && svc_toggle "$ZIVPN_SVC" || { err 'Instala primero'; pause; };; 5) unit_exists "$ZIVPN_SVC" && systemctl restart "$ZIVPN_SVC";; 6) zivpn_remove;; 0) return;; esac; done; }
