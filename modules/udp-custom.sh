# Nexora · UDP-CUSTOM basado en el original Epro Dev Team
UDP_CUSTOM_SVC="${APP_ID}-udp-custom"; UDP_CUSTOM_DIR="${APP_DIR}/udp-custom"; UDP_CUSTOM_BIN="/usr/local/bin/nexora-udp-custom"
udp_custom_install(){
 header 'UDP-CUSTOM · INSTALAR'; mkdir -p "$UDP_CUSTOM_DIR"; local t; t=$(mktemp)
 if ! curl -fL --retry 2 'https://raw.githubusercontent.com/karl1999x/PandaScript/main/BINARIOS/udp-amd64.bin' -o "$t"; then rm -f "$t"; err 'Falló descarga UDP-Custom'; pause; return; fi
 install -m755 "$t" "$UDP_CUSTOM_BIN"; rm -f "$t"
 if ! curl -fL --retry 2 'https://raw.githubusercontent.com/joaquin1444/udp/main/config.json' -o "$UDP_CUSTOM_DIR/config.json"; then rm -f "$UDP_CUSTOM_BIN"; err 'Falló descarga config.json'; pause; return; fi
 chmod 640 "$UDP_CUSTOM_DIR/config.json"
 cat > "/etc/systemd/system/${UDP_CUSTOM_SVC}.service" <<UNIT
[Unit]
Description=Nexora UDP-CUSTOM (Epro Dev Team)
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$UDP_CUSTOM_DIR
ExecStart=$UDP_CUSTOM_BIN server --config $UDP_CUSTOM_DIR/config.json
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
 systemctl daemon-reload && systemctl enable --now "$UDP_CUSTOM_SVC"
 if svc_on "$UDP_CUSTOM_SVC"; then ok 'UDP-CUSTOM activo'; else err "No inició. journalctl -u $UDP_CUSTOM_SVC -n 40"; fi; pause
}
udp_custom_remove(){ header 'UDP-CUSTOM · DESINSTALAR'; confirm_si || return; systemctl disable --now "$UDP_CUSTOM_SVC" 2>/dev/null; rm -f "/etc/systemd/system/${UDP_CUSTOM_SVC}.service" "$UDP_CUSTOM_BIN"; rm -rf "$UDP_CUSTOM_DIR"; systemctl daemon-reload; ok 'UDP-CUSTOM eliminado'; pause; }
udp_custom_menu(){ svc_generic_menu 'UDP-CUSTOM' "$UDP_CUSTOM_SVC" udp_custom_install udp_custom_remove; }
