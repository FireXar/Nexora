# ==========================================================
#  Servicios: instaladores + menú con estado ON/OFF
# ==========================================================

svc_on() {
    # "<app>-ws" es el servicio de SOCKS PYTHON: activo si algún puerto está activo
    if [[ "$1" == "${APP_ID}-ws" ]] && declare -F sp_any_active >/dev/null; then sp_any_active; return; fi
    systemctl is-active --quiet "$1" 2>/dev/null
}

# ---------- Dropbear ----------
svc_dropbear() {
    header "DROPBEAR · INSTALAR"
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
    svc_on dropbear && ok "Dropbear activo en el puerto $p" || err "No pudo iniciar"
    pause
}
svc_dropbear_remove() {
    header "DROPBEAR · DESINSTALAR"; confirm_si || return
    systemctl disable --now dropbear 2>/dev/null
    apt-get remove -y dropbear >/dev/null 2>&1
    ok "Dropbear desinstalado"; pause
}

# ---------- Stunnel (SSL) ----------
svc_stunnel() {
    header "STUNNEL · INSTALAR (SSL → SSH)"
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
    svc_on stunnel4 && ok "Stunnel activo: $p → $d" || err "No pudo iniciar"
    pause
}
svc_stunnel_remove() {
    header "STUNNEL · DESINSTALAR"; confirm_si || return
    systemctl disable --now stunnel4 2>/dev/null
    rm -f /etc/stunnel/${APP_ID}.conf /etc/stunnel/${APP_ID}.pem
    ok "Configuración de Stunnel eliminada"; pause
}

# (SOCKS PYTHON vive en modules/sockspy.sh: modos DIRECTO, SEGURO, OPENVPN, GETTUNNEL y SIMPLE, con varios puertos cada uno)

# ---------- Ajustes SSH ----------
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
    header "ESTADO DE SERVICIOS Y PUERTOS"
    local s st
    for s in ssh sshd dropbear stunnel4 squid ${APP_ID}-xray ${APP_ID}-badvpn ${APP_ID}-slowdns; do
        unit_exists "$s" || continue
        if svc_on "$s"; then st="${G}● activo${W}"; else st="${R}● inactivo${W}"; fi
        printf " %-18s %b\n" "$s" "$st"
    done
    declare -F sp_status_lines >/dev/null && sp_status_lines     # un renglón por cada puerto de SOCKS PYTHON
    echo; echo -e " ${Y}Puertos en escucha:${W}"
    ss -tlnp 2>/dev/null | awk 'NR>1{split($4,a,":"); print "  " a[length(a)] "  " $6}' | sort -n -u
    pause
}
svc_ssh_menu() {
    local o
    while true; do
        header "AJUSTES SSH"
        item 1 "Cambiar puerto SSH"
        item 2 "Banner SSH"
        item 3 "Estado de servicios y puertos"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        case $o in 1) svc_ssh_port;; 2) svc_banner;; 3) svc_status;; 0) return;; esac
    done
}

# ---------- Submenú genérico (instalar · iniciar/detener · reiniciar · desinstalar) ----------
svc_toggle() {
    if svc_on "$1"; then systemctl stop "$1" && warn "Detenido"
    else systemctl start "$1" && ok "Iniciado"; fi
    sleep 1
}
svc_generic_menu() {   # svc_generic_menu <ETIQUETA> <unidad> <fn_instalar> <fn_desinstalar>
    local label="$1" unit="$2" inst="$3" rem="$4" o st
    while true; do
        header "$label"
        if svc_on "$unit"; then st="${G}● ACTIVO${W}"
        elif unit_exists "$unit"; then st="${R}● DETENIDO${W}"
        else st="${Y}no instalado${W}"; fi
        echo -e " Estado: $st"; thin
        item 1 "Instalar / reconfigurar"
        item 2 "Iniciar o detener"
        item 3 "Reiniciar"
        item 4 "Desinstalar"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        case $o in
            1) "$inst";;
            2|3) if unit_exists "$unit"; then
                     if [[ $o == 2 ]]; then svc_toggle "$unit"; else systemctl restart "$unit" && ok "Reiniciado"; sleep 1; fi
                 else err "Instálalo primero"; sleep 1; fi;;
            4) "$rem";;
            0) return;;
        esac
    done
}
svc_dropbear_menu() { svc_generic_menu "DROPBEAR" dropbear svc_dropbear svc_dropbear_remove; }
svc_stunnel_menu()  { svc_generic_menu "STUNNEL (SSL)" stunnel4 svc_stunnel svc_stunnel_remove; }

# ---------- Registro de servicios (agrega una línea para sumar uno nuevo) ----------
#  id | etiqueta (máx. 15) | unidad systemd | función que abre su menú
svc_registry() {
cat <<EOF
ssh|AJUSTES SSH|$(ssh_unit)|svc_ssh_menu
dropbear|DROPBEAR|dropbear|svc_dropbear_menu
ws|SOCKS PYTHON|${APP_ID}-ws|sockspy_menu
stunnel|STUNNEL (SSL)|stunnel4|svc_stunnel_menu
xray|V2RAY/XRAY|${APP_ID}-xray|menu_xray
badvpn|BADVPN-UDPGW|${APP_ID}-badvpn|badvpn_menu
squid|SQUID|squid|squid_menu
hcr|HCR CUSTOM|hcr-server|hcr_menu
bhttp|BHTTP TUNNEL|${APP_ID}-bhttp|bhttp_menu
slowdns|SLOWDNS|${APP_ID}-slowdns|slowdns_menu
EOF
}

svc_cell() {   # svc_cell <numero> <etiqueta> <unidad>   (sin salto de línea)
    local st
    if svc_on "$3"; then st="${G}[ON] ${W}"; else st="${R}[OFF]${W}"; fi
    printf " ${C}[%s]${W} %-15s %b" "$1" "$2" "$st"
}

menu_services() {
    local ids=() labels=() units=() handlers=()
    local id label unit handler n half i j o
    while IFS='|' read -r id label unit handler; do
        [[ -z "$id" ]] && continue
        declare -F "$handler" >/dev/null || continue     # si el módulo no está, no se muestra
        ids+=("$id"); labels+=("$label"); units+=("$unit"); handlers+=("$handler")
    done < <(svc_registry)
    n=${#ids[@]}

    while true; do
        header "SERVICIOS"
        if (( $(ui_width) >= 54 )); then          # PC: dos columnas
            half=$(( (n + 1) / 2 ))
            for (( i = 0; i < half; i++ )); do
                svc_cell $((i+1)) "${labels[i]}" "${units[i]}"
                j=$(( i + half ))
                if (( j < n )); then svc_cell $((j+1)) "${labels[j]}" "${units[j]}"; fi
                echo
            done
        else                                       # celular: una columna
            for (( i = 0; i < n; i++ )); do
                svc_cell $((i+1)) "${labels[i]}" "${units[i]}"; echo
            done
        fi
        line
        item 0 "Volver"
        line
        echo -ne " ${Y}❯${W} Ingresa una opción: "; read -r o
        [[ "$o" == "0" ]] && return
        if is_num "$o" && (( o >= 1 && o <= n )); then "${handlers[o-1]}"; fi
    done
}
