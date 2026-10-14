svc_dropbear() {
    header "DROPBEAR"
    read -rp " Puerto [443]: " p; p=${p:-443}
    is_num "$p" || { err "Puerto inválido"; pause; return; }
    apt-get install -y dropbear >/dev/null 2>&1
    sed -i 's/^NO_START=.*/NO_START=0/' /etc/default/dropbear
    if grep -q '^#\?DROPBEAR_PORT=' /etc/default/dropbear; then
        sed -i "s/^#\?DROPBEAR_PORT=.*/DROPBEAR_PORT=$p/" /etc/default/dropbear
    else
        echo "DROPBEAR_PORT=$p" >> /etc/default/dropbear
    fi
    systemctl enable dropbear >/dev/null 2>&1; systemctl restart dropbear
    open_port "$p"
    systemctl is-active --quiet dropbear && ok "Dropbear activo en el puerto $p" || err "No pudo iniciar"
    pause
}

svc_stunnel() {
    header "STUNNEL (SSL → SSH)"
    read -rp " Puerto SSL público [8443]: " p; p=${p:-8443}
    read -rp " Puerto SSH destino   [22]: " d; d=${d:-22}
    is_num "$p" && is_num "$d" || { err "Puerto inválido"; pause; return; }
    apt-get install -y stunnel4 openssl >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -nodes -subj "/CN=${APP_ID}" \
        -out /etc/stunnel/${APP_ID}.pem -keyout /etc/stunnel/${APP_ID}.pem 2>/dev/null
    cat > /etc/stunnel/${APP_ID}.conf <<EOF
pid = /var/run/stunnel4-${APP_ID}.pid
cert = /etc/stunnel/${APP_ID}.pem
client = no
socket = a:SO_REUSEADDR=1
[ssh-ssl]
accept = $p
connect = 127.0.0.1:$d
EOF
    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
    systemctl enable stunnel4 >/dev/null 2>&1; systemctl restart stunnel4
    open_port "$p"
    systemctl is-active --quiet stunnel4 && ok "Stunnel activo: $p → $d" || err "No pudo iniciar"
    pause
}

svc_ws() {
    header "PROXY WEBSOCKET → SSH"
    read -rp " Puerto público [80]: " p; p=${p:-80}
    read -rp " Puerto SSH destino [22]: " d; d=${d:-22}
    is_num "$p" && is_num "$d" || { err "Puerto inválido"; pause; return; }
    if ss -tln | awk '{print $4}' | grep -q ":$p\$"; then
        err "El puerto $p ya está en uso"; pause; return
    fi
    cat > /etc/systemd/system/${APP_ID}-ws.service <<EOF
[Unit]
Description=${APP_NAME} WebSocket proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 ${MOD_DIR}/ws-proxy.py $p $d
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now ${APP_ID}-ws >/dev/null 2>&1
    open_port "$p"
    systemctl is-active --quiet ${APP_ID}-ws && ok "WebSocket activo: $p → $d" || err "No pudo iniciar"
    pause
}

svc_ssh_port() {
    header "CAMBIAR PUERTO SSH"
    read -rp " Nuevo puerto: " p
    is_num "$p" || { err "Puerto inválido"; pause; return; }
    open_port "$p"
    sed -i "s/^#\?Port .*/Port $p/" /etc/ssh/sshd_config
    restart_ssh
    warn "Prueba conectarte al nuevo puerto ANTES de cerrar esta sesión."
    pause
}

svc_banner() {
    header "BANNER SSH"
    read -rp " Texto del banner: " t
    echo "$t" > "$APP_DIR/banner.txt"
    if grep -q '^#\?Banner' /etc/ssh/sshd_config; then
        sed -i "s|^#\?Banner.*|Banner $APP_DIR/banner.txt|" /etc/ssh/sshd_config
    else
        echo "Banner $APP_DIR/banner.txt" >> /etc/ssh/sshd_config
    fi
    restart_ssh; ok "Banner aplicado"; pause
}

svc_status() {
    header "ESTADO DE SERVICIOS"
    local s st
    for s in ssh sshd dropbear stunnel4 ${APP_ID}-ws; do
        systemctl list-unit-files 2>/dev/null | grep -q "^$s.service" || continue
        if systemctl is-active --quiet "$s"; then st="${G}● activo${W}"; else st="${R}● inactivo${W}"; fi
        printf " %-16s %b\n" "$s" "$st"
    done
    echo; echo -e " ${Y}Puertos en escucha:${W}"
    ss -tlnp 2>/dev/null | awk 'NR>1{split($4,a,":"); print "  " a[length(a)] "  " $6}' | sort -n -u
    pause
}

menu_services() {
    local o
    while true; do
        header "SERVICIOS"
        echo -e " ${G}1)${W} Instalar Dropbear"
        echo -e " ${G}2)${W} Instalar Stunnel (SSL)"
        echo -e " ${G}3)${W} Proxy WebSocket"
        echo -e " ${G}4)${W} Cambiar puerto SSH"
        echo -e " ${G}5)${W} Banner SSH"
        echo -e " ${G}6)${W} Estado de servicios y puertos"
        echo -e " ${G}0)${W} Volver"; line
        read -rp " Opción: " o
        case $o in
            1) svc_dropbear;; 2) svc_stunnel;; 3) svc_ws;;
            4) svc_ssh_port;; 5) svc_banner;; 6) svc_status;;
            0) return;;
        esac
    done
}
