# ==========================================================
# Herramientas extra: espacio para funciones auxiliares futuras
# ==========================================================

tools_domain() {
    local o current
    while true; do
        header "CONFIGURAR DOMINIO"
        current=$(domain_get)
        if [[ -n "$current" ]]; then
            echo -e " Dominio actual: ${G}${current}${W}"
        else
            warn "No hay un dominio configurado."
        fi
        echo
        echo -e " ${G}1)${W} Agregar / cambiar dominio"
        echo -e " ${G}2)${W} Comprobar dominio"
        echo -e " ${G}3)${W} Eliminar dominio"
        echo -e " ${G}0)${W} Volver"; line
        read -r -p " Opción: " o
        case "$o" in
            1) domain_configure_prompt; pause;;
            2)
                if [[ -n "$current" ]]; then
                    domain_check "$current" && ok "El dominio apunta a este VPS." || warn "La comprobación no fue satisfactoria."
                else
                    warn "Primero configura un dominio."
                fi
                pause;;
            3)
                if [[ -n "$current" ]]; then
                    read -r -p "¿Eliminar $current? Escribe SI para confirmar: " confirm
                    if [[ "$confirm" == "SI" ]]; then domain_remove; ok "Dominio eliminado."; else warn "Cancelado."; fi
                else
                    warn "No hay dominio para eliminar."
                fi
                pause;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}


# ==========================================================
# Fecha y hora del sistema (zona horaria, NTP y ajuste manual)
# ==========================================================

timezone_current() {
    local tz=""
    if command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    fi
    if [[ -z "$tz" && -r /etc/timezone ]]; then IFS= read -r tz < /etc/timezone; fi
    if [[ -z "$tz" ]]; then tz=$(readlink -f /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##'); fi
    printf '%s' "${tz:-UTC}"
}

time_ntp_state() {
    local state=""
    if command -v timedatectl >/dev/null 2>&1; then
        state=$(timedatectl show -p NTP --value 2>/dev/null)
    fi
    case "${state,,}" in yes|true|1) printf 'ACTIVADA';; no|false|0) printf 'DESACTIVADA';; *) printf 'NO DISPONIBLE';; esac
}

time_show_status() {
    header "CONFIGURACIÓN DE FECHA Y HORA"
    echo -e " Fecha actual : ${G}$(date '+%d/%m/%Y')${W}"
    echo -e " Hora actual  : ${G}$(date '+%H:%M:%S')${W}"
    echo -e " Zona horaria : ${C}$(timezone_current)${W}"
    echo -e " Sincronización NTP: ${Y}$(time_ntp_state)${W}"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl status 2>/dev/null | sed 's/^/ /'
    else
        warn "timedatectl no está disponible en este sistema."
    fi
}

time_set_timezone() {
    local o tz custom
    while true; do
        header "SELECCIONAR ZONA HORARIA"
        echo " Zona actual: $(timezone_current)"
        echo
        echo -e " ${G}1)${W} Argentina - Buenos Aires"
        echo -e " ${G}2)${W} Brasil - São Paulo"
        echo -e " ${G}3)${W} Brasil - Manaus"
        echo -e " ${G}4)${W} Colombia - Bogotá"
        echo -e " ${G}5)${W} Chile - Santiago"
        echo -e " ${G}6)${W} México - Ciudad de México"
        echo -e " ${G}7)${W} Uruguay - Montevideo"
        echo -e " ${G}8)${W} UTC"
        echo -e " ${G}9)${W} Introducir zona horaria manualmente"
        echo -e " ${G}0)${W} Volver"; line
        read -r -p " Opción: " o
        case "$o" in
            1) tz="America/Argentina/Buenos_Aires";;
            2) tz="America/Sao_Paulo";;
            3) tz="America/Manaus";;
            4) tz="America/Bogota";;
            5) tz="America/Santiago";;
            6) tz="America/Mexico_City";;
            7) tz="America/Montevideo";;
            8) tz="Etc/UTC";;
            9)
                echo " Ejemplo: America/Argentina/Cordoba o Europe/Madrid"
                read -r -p " Zona horaria: " custom
                tz="$custom";;
            0) return;;
            *) warn "Opción inválida"; sleep 1; continue;;
        esac
        [[ -n "$tz" ]] || continue
        if [[ ! -e "/usr/share/zoneinfo/$tz" || "$tz" == *".."* ]]; then
            err "Zona horaria no válida o no instalada: $tz"; pause; continue
        fi
        if timedatectl set-timezone "$tz"; then
            ok "Zona horaria configurada: $tz"
            echo " La fecha y hora del panel se actualizarán automáticamente."
        else
            err "No se pudo cambiar la zona horaria. Comprueba que systemd/timedatectl esté disponible."
        fi
        pause
        return
    done
}

time_toggle_ntp() {
    local state
    state=$(time_ntp_state)
    header "SINCRONIZACIÓN AUTOMÁTICA (NTP)"
    echo " Estado actual: $state"
    echo
    echo "NTP permite que Linux mantenga el reloj sincronizado automáticamente."
    echo
    echo -e " ${G}1)${W} Activar sincronización automática"
    echo -e " ${G}2)${W} Desactivar sincronización automática"
    echo -e " ${G}0)${W} Volver"; line
    read -r -p " Opción: " o
    case "$o" in
        1|2)
            if ! command -v timedatectl >/dev/null 2>&1; then
                err "timedatectl no está disponible."; pause; return
            fi
            if [[ "$o" == 1 ]]; then
                timedatectl set-ntp true && ok "Sincronización NTP activada." || err "No se pudo activar NTP."
            else
                warn "Al desactivar NTP, el reloj dejará de corregirse automáticamente."
                read -r -p "¿Continuar? Escribe SI: " confirm
                [[ "$confirm" == "SI" ]] || { warn "Cancelado."; pause; return; }
                timedatectl set-ntp false && ok "Sincronización NTP desactivada." || err "No se pudo desactivar NTP."
            fi
            ;;
        0) return;;
        *) warn "Opción inválida";;
    esac
    pause
}

time_set_manual() {
    local value
    header "CONFIGURAR FECHA Y HORA MANUALMENTE"
    warn "Este ajuste cambia el reloj del servidor y puede afectar registros, vencimientos y conexiones."
    if [[ "$(time_ntp_state)" == "ACTIVADA" ]]; then
        warn "NTP está activado. Desactívalo primero para evitar que vuelva a corregir el reloj."
        pause
        return
    fi
    echo " Formato requerido: AAAA-MM-DD HH:MM:SS"
    echo " Ejemplo: 2026-11-19 15:30:00"
    read -r -p " Nueva fecha y hora (ENTER para cancelar): " value
    [[ -n "$value" ]] || { warn "Cancelado."; return; }
    if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || ! date -d "$value" >/dev/null 2>&1 || [[ "$(date -d "$value" '+%F %T' 2>/dev/null)" != "$value" ]]; then
        err "Formato o fecha inválida."; pause; return
    fi
    echo " Se establecerá: $value"
    read -r -p "¿Confirmas el cambio? Escribe SI: " confirm
    [[ "$confirm" == "SI" ]] || { warn "Cancelado."; pause; return; }
    if timedatectl set-time "$value"; then
        ok "Fecha y hora actualizadas."
    else
        err "No se pudo cambiar el reloj. Comprueba permisos y el servicio de hora del sistema."
    fi
    pause
}

tools_time() {
    local o
    while true; do
        time_show_status
        echo
        echo -e " ${G}1)${W} Seleccionar país / zona horaria"
        echo -e " ${G}2)${W} Activar / desactivar sincronización automática (NTP)"
        echo -e " ${G}3)${W} Configurar fecha y hora manualmente"
        echo -e " ${G}4)${W} Consultar configuración actual"
        echo -e " ${G}0)${W} Volver"; line
        read -r -p " Opción: " o
        case "$o" in
            1) time_set_timezone;;
            2) time_toggle_ntp;;
            3) time_set_manual;;
            4) time_show_status; pause;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}

menu_tools() {
    local o
    while true; do
        header "HERRAMIENTAS EXTRA"
        item 1 "Configurar dominio" "agregar · comprobar · eliminar"
        item 2 "Configurar fecha y hora" "zona horaria · NTP · manual"
        item 0 "Volver"
        line
        read -r -p " Opción: " o
        case "$o" in
            1) tools_domain;;
            2) tools_time;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}
