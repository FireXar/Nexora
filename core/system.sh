sys_info() {
    header "INFORMACIÓN DEL SISTEMA"
    echo -e " SO        : $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo -e " Kernel    : $(uname -r)"
    echo -e " IP        : $(get_ip)"
    echo -e " CPU       : $(nproc) núcleos · carga $(cut -d' ' -f1-3 /proc/loadavg)"
    echo -e " RAM       : $(free -h | awk '/Mem:/{print $3 " / " $2}')"
    echo -e " Swap      : $(free -h | awk '/Swap:/{print $3 " / " $2}')"
    echo -e " Disco     : $(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
    echo -e " Uptime    : $(uptime -p)"
    pause
}

sys_bbr() {
    header "ACTIVAR BBR"
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        ok "BBR ya está activo"
    else
        grep -q 'tcp_congestion_control=bbr' /etc/sysctl.conf || {
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        }
        sysctl -p >/dev/null 2>&1; ok "BBR activado"
    fi
    pause
}

sys_swap() {
    header "CREAR SWAP"
    if swapon --show | grep -q .; then warn "Ya existe swap"; pause; return; fi
    read -rp " Tamaño en MB [1024]: " s; s=${s:-1024}
    is_num "$s" || { err "Número inválido"; pause; return; }
    fallocate -l "${s}M" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap de ${s}MB activa"; pause
}

sys_update() {
    header "ACTUALIZAR SISTEMA"
    apt-get update -y && apt-get upgrade -y
    pause
}

sys_cron() {
    header "LIMPIEZA AUTOMÁTICA"
    {
        echo "0 0 * * * root $BIN_LINK --clean >/dev/null 2>&1"
        echo "* * * * * root $BIN_LINK --tick >/dev/null 2>&1"
    } > "/etc/cron.d/${APP_ID}"
    ok "Los usuarios expirados se borrarán a diario a las 00:00"; pause
}

# Autoinicio del panel al abrir una sesion SSH interactiva como root.
sys_autostart() {
    local o flag="/etc/${APP_ID}/autostart.enabled"
    local profile="/etc/profile.d/${APP_ID}-autostart.sh"

    while true; do
        header "AUTOINICIAR ${APP_NAME}"
        if [[ -f "$flag" ]]; then
            echo -e " Estado: ${G}ACTIVADO${W}"
        else
            echo -e " Estado: ${Y}DESACTIVADO${W}"
        fi
        echo
        echo -e " ${G}1)${W} Activar autoinicio"
        echo -e " ${G}2)${W} Desactivar autoinicio"
        echo -e " ${G}3)${W} Consultar estado"
        echo -e " ${G}0)${W} Volver"; line
        read -rp " Opción: " o
        case "$o" in
            1)
                if [[ ! -f "$profile" ]]; then
                    err "No se encuentra el archivo de inicio. Reinstala/actualiza Nexora."
                else
                    touch "$flag"
                    chmod 600 "$flag"
                    ok "Autoinicio activado para nuevas sesiones SSH interactivas de root."
                    echo " Al salir de Nexora volverás a la terminal."
                fi
                pause;;
            2)
                rm -f "$flag"
                ok "Autoinicio desactivado. Las sesiones nuevas abrirán la terminal normalmente."
                pause;;
            3)
                if [[ -f "$flag" ]]; then
                    ok "Autoinicio ACTIVADO"
                else
                    warn "Autoinicio DESACTIVADO"
                fi
                echo " Archivo de inicio: $profile"
                pause;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}

sys_selfupdate() {
    header "ACTUALIZAR $APP_NAME"
    if [[ "$APP_REPO" == *TU_USUARIO* ]]; then
        err "Configura APP_REPO en core/config.sh con la URL de tu repositorio."; pause; return
    fi
    command -v git >/dev/null || apt-get install -y git >/dev/null 2>&1
    if [[ -d "$SRC_DIR/.git" ]]; then
        git -C "$SRC_DIR" pull --ff-only || { err "No se pudo actualizar"; pause; return; }
    else
        git clone "$APP_REPO" "$SRC_DIR" || { err "No se pudo clonar el repositorio"; pause; return; }
    fi
    ok "Código actualizado. Reinstalando..."
    bash "$SRC_DIR/install.sh" && ok "Listo. Vuelve a abrir: $APP_ID"
    pause; exit 0
}

sys_uninstall() {
    header "DESINSTALAR $APP_NAME"
    warn "Se borra el panel; los usuarios SSH creados NO se eliminan."
    read -rp " Escribe SI para confirmar: " c
    [[ "$c" == "SI" ]] || return
    local f u
    [[ -x "$APP_DIR/slowdns/fw.sh" ]] && "$APP_DIR/slowdns/fw.sh" down      # quita las reglas UDP 53 de SlowDNS
    for f in /etc/systemd/system/${APP_ID}-ws*.service /etc/systemd/system/${APP_ID}-xray.service /etc/systemd/system/${APP_ID}-slowdns*.service; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f" .service)
        systemctl disable --now "$u" 2>/dev/null
        rm -f "$f"
    done
    rm -f /etc/cron.d/${APP_ID} /etc/cron.d/${APP_ID}-nexguard "$BIN_LINK" "/etc/profile.d/${APP_ID}-autostart.sh" "$APP_DIR/autostart.enabled"
    # Quitar cadenas iptables de NexGuard si existen
    iptables -D OUTPUT -j NEXGUARD_LOG 2>/dev/null
    iptables -D OUTPUT -j NEXGUARD_BLOCK 2>/dev/null
    iptables -F NEXGUARD_LOG 2>/dev/null; iptables -X NEXGUARD_LOG 2>/dev/null
    iptables -F NEXGUARD_BLOCK 2>/dev/null; iptables -X NEXGUARD_BLOCK 2>/dev/null
    systemctl daemon-reload
    rm -rf "$APP_DIR"
    echo " Desinstalado."; exit 0
}

menu_system() {
    local o
    while true; do
        header "SISTEMA"
        echo -e " ${G}1)${W} Información del servidor"
        echo -e " ${G}2)${W} Activar BBR"
        echo -e " ${G}3)${W} Crear swap"
        echo -e " ${G}4)${W} Actualizar sistema"
        echo -e " ${G}5)${W} Activar limpieza automática de expirados"
        echo -e " ${G}6)${W} Actualizar $APP_NAME desde GitHub"
        echo -e " ${G}7)${W} Autoiniciar $APP_NAME"
        echo -e " ${G}8)${W} Desinstalar $APP_NAME"
        echo -e " ${G}0)${W} Volver"; line
        read -rp " Opción: " o
        case $o in
            1) sys_info;; 2) sys_bbr;; 3) sys_swap;;
            4) sys_update;; 5) sys_cron;; 6) sys_selfupdate;;
            7) sys_autostart;; 8) sys_uninstall;;
            0) return;;
        esac
    done
}
