# Nexora · UDP-HYSTERIA v1 basado en PandaScript
HYSTERIA_SVC="${APP_ID}-udp-hysteria"; HYSTERIA_DIR="${APP_DIR}/udp-hysteria"; HYSTERIA_BIN="/usr/local/bin/nexora-hysteria"; HYSTERIA_AUTH="${HYSTERIA_DIR}/authSSH"
hysteria_port(){ python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("listen",":36712").rsplit(":",1)[-1])' "$HYSTERIA_DIR/config.json" 2>/dev/null || echo 36712; }
hysteria_fw_add(){ local i="$1" p="$2"; iptables -t nat -C PREROUTING -i "$i" -p udp --dport 1:65535 -m comment --comment nexora-hysteria -j DNAT --to-destination ":$p" 2>/dev/null || iptables -t nat -A PREROUTING -i "$i" -p udp --dport 1:65535 -m comment --comment nexora-hysteria -j DNAT --to-destination ":$p"; iptables -C INPUT -p udp --dport "$p" -m comment --comment nexora-hysteria -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$p" -m comment --comment nexora-hysteria -j ACCEPT; }
hysteria_remove_fw(){ local i p; i=$(ip -4 route show default 2>/dev/null|awk 'NR==1{print $5}'); p=$(hysteria_port); [[ -n "$i" ]] && while iptables -t nat -C PREROUTING -i "$i" -p udp --dport 1:65535 -m comment --comment nexora-hysteria -j DNAT --to-destination ":$p" 2>/dev/null; do iptables -t nat -D PREROUTING -i "$i" -p udp --dport 1:65535 -m comment --comment nexora-hysteria -j DNAT --to-destination ":$p"; done; while iptables -C INPUT -p udp --dport "$p" -m comment --comment nexora-hysteria -j ACCEPT 2>/dev/null; do iptables -D INPUT -p udp --dport "$p" -m comment --comment nexora-hysteria -j ACCEPT; done; }
hysteria_install(){
 header 'UDP-HYSTERIA · INSTALAR'; local domain arch bin t; read -rp ' Dominio/subdominio: ' domain; [[ -n "$domain" ]] || { err 'Debes indicar dominio'; pause; return; }; mkdir -p "$HYSTERIA_DIR"; apt-get install -y curl openssl python3 iptables >/dev/null 2>&1
 case "$(uname -m)" in x86_64|amd64) bin=hysteria-linux-amd64;; aarch64|arm64) bin=hysteria-linux-arm64;; *) err 'Arquitectura no soportada'; pause; return;; esac
 t=$(mktemp); if ! curl -fL --retry 2 "https://github.com/apernet/hysteria/releases/download/v1.3.5/$bin" -o "$t"; then rm -f "$t"; err 'Falló descarga Hysteria'; pause; return; fi; install -m755 "$t" "$HYSTERIA_BIN"; rm -f "$t"
 if ! curl -fL --retry 2 'https://raw.githubusercontent.com/karl1999x/PandaScript/refs/heads/main/PandaScript/authSSH' -o "$HYSTERIA_AUTH"; then err 'Falló descarga authSSH'; pause; return; fi; chmod 750 "$HYSTERIA_AUTH"
 openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$HYSTERIA_DIR/server.key" -out "$HYSTERIA_DIR/server.crt" -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1 || { err 'Falló certificado'; pause; return; }
 cat > "$HYSTERIA_DIR/config.json" <<CFG
{
 "listen": ":36712", "cert": "$HYSTERIA_DIR/server.crt", "key": "$HYSTERIA_DIR/server.key", "obfs": "modv",
 "auth": {"mode": "external", "config": {"cmd": "$HYSTERIA_AUTH"}}
}
CFG
 echo "$domain" > "$HYSTERIA_DIR/domain.conf"
 cat > "/etc/systemd/system/${HYSTERIA_SVC}.service" <<UNIT
[Unit]
Description=Nexora UDP-HYSTERIA v1 (PandaScript)
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$HYSTERIA_DIR
ExecStart=$HYSTERIA_BIN server --config $HYSTERIA_DIR/config.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
 systemctl daemon-reload && systemctl enable --now "$HYSTERIA_SVC"; local i; i=$(ip -4 route show default 2>/dev/null|awk 'NR==1{print $5}'); [[ -n "$i" ]] && hysteria_fw_add "$i" 36712
 if svc_on "$HYSTERIA_SVC"; then ok 'UDP-HYSTERIA activo · puerto 36712 · OBFS modv'; else err "No inició. journalctl -u $HYSTERIA_SVC -n 40"; fi; warn 'Certificado autofirmado: verifica compatibilidad con tu cliente'; pause
}
hysteria_change_port(){ local p; read -rp ' Nuevo puerto UDP [36712]: ' p; p=${p:-36712}; [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1&&p<=65535)) || { err 'Puerto inválido'; pause; return; }; local old i; old=$(hysteria_port); i=$(ip -4 route show default 2>/dev/null|awk 'NR==1{print $5}'); hysteria_remove_fw; python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["listen"]=":"+sys.argv[2]; json.dump(d,open(f,"w"),indent=2)' "$HYSTERIA_DIR/config.json" "$p"; systemctl restart "$HYSTERIA_SVC"; [[ -n "$i" ]] && hysteria_fw_add "$i" "$p"; ok "Puerto actualizado a $p"; pause; }
hysteria_change_obfs(){ local v; read -rp ' Nuevo OBFS [modv]: ' v; [[ -n "$v" ]] || return; python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["obfs"]=sys.argv[2]; json.dump(d,open(f,"w"),indent=2)' "$HYSTERIA_DIR/config.json" "$v"; systemctl restart "$HYSTERIA_SVC"; ok 'OBFS actualizado'; pause; }
hysteria_remove(){ header 'UDP-HYSTERIA · DESINSTALAR'; confirm_si || return; systemctl disable --now "$HYSTERIA_SVC" 2>/dev/null; hysteria_remove_fw; rm -f "/etc/systemd/system/${HYSTERIA_SVC}.service" "$HYSTERIA_BIN"; rm -rf "$HYSTERIA_DIR"; systemctl daemon-reload; ok 'UDP-HYSTERIA eliminado'; pause; }
hysteria_menu(){ local o; while true; do header 'UDP-HYSTERIA'; if svc_on "$HYSTERIA_SVC"; then ok 'Estado: ACTIVO'; elif unit_exists "$HYSTERIA_SVC"; then warn 'Estado: DETENIDO'; else warn 'Estado: NO INSTALADO'; fi; item 1 'Instalar / reconfigurar'; item 2 'Cambiar puerto'; item 3 'Cambiar OBFS'; item 4 'Iniciar / detener'; item 5 'Reiniciar'; item 6 'Desinstalar'; item 0 'Volver'; line; read -rp ' Opción: ' o; case $o in 1) hysteria_install;; 2) [[ -f "$HYSTERIA_DIR/config.json" ]] && hysteria_change_port || { err 'Instala primero'; pause; };; 3) [[ -f "$HYSTERIA_DIR/config.json" ]] && hysteria_change_obfs || { err 'Instala primero'; pause; };; 4) unit_exists "$HYSTERIA_SVC" && svc_toggle "$HYSTERIA_SVC" || { err 'Instala primero'; pause; };; 5) unit_exists "$HYSTERIA_SVC" && systemctl restart "$HYSTERIA_SVC";; 6) hysteria_remove;; 0) return;; esac; done; }
