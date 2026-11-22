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


# ==========================================================
# CERTIFICADOS SSL PUBLICOS (Let's Encrypt / Certbot)
# ==========================================================
ssl_certbot_install() {
    if ! command -v certbot >/dev/null 2>&1; then
        warn "Se instalará Certbot desde los repositorios de Ubuntu/Debian."
        apt-get update -y && apt-get install -y certbot || { err "No se pudo instalar Certbot."; return 1; }
    fi
    command -v certbot >/dev/null 2>&1
}

ssl_certificates() {
    header "CERTIFICADOS SSL INSTALADOS"
    if ! command -v certbot >/dev/null 2>&1; then
        warn "Certbot todavía no está instalado."; return
    fi
    certbot certificates 2>&1 || true
}

ssl_issue() {
    local domain email port
    header "SOLICITAR CERTIFICADO LET'S ENCRYPT"
    domain=$(domain_get)
    read -r -p " Dominio (ENTER para usar ${domain:-ninguno}): " entered
    domain=${entered:-$domain}
    domain=$(domain_normalize "$domain")
    domain_valid "$domain" || { err "Dominio inválido. Configura primero un dominio válido."; return 1; }
    read -r -p " Correo para avisos de renovación: " email
    [[ "$email" == *@*.* ]] || { err "Debes indicar un correo válido."; return 1; }
    echo
    warn "Let's Encrypt necesita que el dominio resuelva a este VPS y que el puerto TCP 80 sea accesible desde Internet."
    warn "El modo independiente de Certbot necesita ocupar temporalmente el puerto 80. No detendremos servicios automáticamente."
    if ! domain_check "$domain"; then err "El DNS A del dominio no coincide con la IP pública del VPS."; return 1; fi
    if port_busy 80; then
        err "El puerto 80 está ocupado. Para no interrumpir WebSocket/SSH, no se solicitará el certificado." 
        echo " Detén o reconfigura manualmente el servicio que usa el puerto 80 y vuelve a intentarlo."; return 1
    fi
    read -r -p " ¿Continuar con la validación HTTP-01? Escribe SI: " confirm
    [[ "$confirm" == SI ]] || { warn "Cancelado."; return 0; }
    ssl_certbot_install || return 1
    certbot certonly --standalone --preferred-challenges http -d "$domain" --email "$email" --agree-tos --no-eff-email
    if [[ $? -eq 0 ]]; then
        ok "Certificado emitido: /etc/letsencrypt/live/$domain/"
        systemctl enable --now certbot.timer >/dev/null 2>&1 || true
        ok "Se habilitó el temporizador de renovación automática (si está disponible)."
    else
        err "Certbot no pudo emitir el certificado. Revisa DNS, firewall y acceso al puerto 80."
        return 1
    fi
}

ssl_renew() {
    header "RENOVACIÓN DE CERTIFICADOS"
    command -v certbot >/dev/null 2>&1 || { err "Certbot no está instalado."; return; }
    echo "Se ejecutará una prueba de renovación sin modificar certificados válidos."
    certbot renew --dry-run
}

ssl_delete() {
    local name
    header "ELIMINAR CERTIFICADO"
    command -v certbot >/dev/null 2>&1 || { err "Certbot no está instalado."; return; }
    certbot certificates
    echo
    read -r -p " Nombre exacto del certificado (ENTER cancela): " name
    [[ -n "$name" ]] || return 0
    warn "Se eliminará el certificado '$name' y sus configuraciones de Certbot."
    read -r -p " Escribe SI para confirmar: " confirm
    [[ "$confirm" == SI ]] || { warn "Cancelado."; return 0; }
    certbot delete --cert-name "$name"
}

tools_ssl() {
    local o
    while true; do
        header "ADMINISTRADOR DE CERTIFICADOS SSL"
        if command -v certbot >/dev/null 2>&1; then
            echo -e " Estado: ${G}Certbot instalado${W}"
        else
            echo -e " Estado: ${Y}Certbot no instalado${W}"
        fi
        echo
        item 1 "Solicitar certificado Let's Encrypt" "requiere DNS correcto y puerto 80 libre"
        item 2 "Ver certificados instalados"
        item 3 "Probar renovación automática"
        item 4 "Eliminar certificado"
        item 0 "Volver"; line
        read -r -p " Opción: " o
        case "$o" in
            1) ssl_issue; pause;;
            2) ssl_certificates; pause;;
            3) ssl_renew; pause;;
            4) ssl_delete; pause;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}

# ==========================================================
# BANNER SSH / DROPBEAR
# ==========================================================
tools_banner_status() {
    local ssh_banner db_banner
    ssh_banner=$(sshd -T 2>/dev/null | awk '$1=="banner" {print $2; exit}')
    db_banner=$(sed -n 's/^DROPBEAR_BANNER=//p' /etc/default/dropbear 2>/dev/null | tail -n1 | tr -d '"')
    echo " Banner SSH: ${ssh_banner:-ninguno}"
    echo " Banner Dropbear: ${db_banner:-ninguno}"
}

tools_banner_apply_ssh() {
    local textfile="$APP_DIR/banner.txt" tmp backup
    [[ -s "$textfile" ]] || { err "Primero crea el mensaje."; return 1; }
    backup="/etc/ssh/sshd_config.nexora-bak-$(date +%Y%m%d%H%M%S)"
    cp -a /etc/ssh/sshd_config "$backup"
    tmp=$(mktemp)
    awk '!/^[[:space:]]*#?[[:space:]]*Banner[[:space:]]+/' /etc/ssh/sshd_config > "$tmp"
    # Mantiene Banner fuera de bloques Match.
    awk 'BEGIN{done=0} /^[[:space:]]*Match[[:space:]]/ && !done {print "Banner " ENVIRON["NEXORA_BANNER_FILE"]; done=1} {print} END{if(!done) print "Banner " ENVIRON["NEXORA_BANNER_FILE"]}' "$tmp" > "${tmp}.new"
    cat "${tmp}.new" > /etc/ssh/sshd_config
    rm -f "$tmp" "${tmp}.new"
    if sshd -t 2>/dev/null; then
        restart_ssh && ok "Banner SSH aplicado."
    else
        cp -a "$backup" /etc/ssh/sshd_config
        err "Configuración SSH inválida; se restauró la copia de seguridad."; return 1
    fi
}

tools_banner_ssh() {
    local textfile="$APP_DIR/banner.txt"
    mkdir -p "$APP_DIR"
    echo "Escribe el mensaje. Se abrirá nano; guarda con Ctrl+O y sal con Ctrl+X."
    if ! command -v nano >/dev/null 2>&1; then apt-get install -y nano >/dev/null 2>&1 || return 1; fi
    touch "$textfile"; nano "$textfile"
    [[ -s "$textfile" ]] || { warn "El archivo quedó vacío; no se aplicaron cambios."; return 1; }
    NEXORA_BANNER_FILE="$textfile" tools_banner_apply_ssh
}

tools_banner_dropbear() {
    local file=/etc/default/dropbear banner="$APP_DIR/banner.txt" tmp
    if ! command -v dropbear >/dev/null 2>&1; then
        warn "Dropbear no está instalado."; read -r -p "¿Instalarlo ahora? Escribe SI: " confirm
        [[ "$confirm" == SI ]] || return 0
        apt-get update -y && apt-get install -y dropbear || return 1
    fi
    [[ -s "$banner" ]] || { err "Primero crea el banner desde la opción de SSH."; return 1; }
    cp -a "$file" "${file}.nexora-bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    # Debian/Ubuntu Dropbear recibe el archivo de banner mediante -b.
    if grep -q '^DROPBEAR_EXTRA_ARGS=' "$file"; then
        sed -i "s|^DROPBEAR_EXTRA_ARGS=.*|DROPBEAR_EXTRA_ARGS=\"-b $banner\"|" "$file"
    else
        printf '\nDROPBEAR_EXTRA_ARGS="-b %s"\n' "$banner" >> "$file"
    fi
    systemctl restart dropbear && ok "Banner Dropbear configurado." || { err "No se pudo reiniciar Dropbear; revisa /etc/default/dropbear."; return 1; }
}

tools_banner_menu() {
    local o
    while true; do
        header "ADMINISTRADOR BANNER SSH/DROPBEAR"
        tools_banner_status
        echo
        item 1 "Crear / editar mensaje" "archivo compartido SSH y Dropbear"
        item 2 "Aplicar banner a SSH"
        item 3 "Aplicar banner a Dropbear"
        item 4 "Desactivar banner SSH"
        item 0 "Volver"; line
        read -r -p " Opción: " o
        case "$o" in
            1) tools_banner_ssh; pause;;
            2) NEXORA_BANNER_FILE="$APP_DIR/banner.txt" tools_banner_apply_ssh; pause;;
            3) tools_banner_dropbear; pause;;
            4)
                cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.nexora-bak-$(date +%Y%m%d%H%M%S)"
                sed -i '/^[[:space:]]*Banner[[:space:]]/d' /etc/ssh/sshd_config
                if sshd -t 2>/dev/null; then restart_ssh && ok "Banner SSH desactivado."; else err "No se pudo validar SSH."; fi
                pause;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}

# ==========================================================
# CLAVE Y ACCESO ROOT (compatible con cloud-init / OVH / AWS)
# ==========================================================
root_ssh_effective() {
    local output
    output=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null) || return 1
    printf '%s\n' "$output" | awk '$1=="permitrootlogin" || $1=="passwordauthentication" || $1=="pubkeyauthentication" {print "  " $1 ": " $2}'
}

root_ssh_apply() {
    local mode="$1" conf=/etc/ssh/sshd_config.d/00-nexora-root-access.conf
    local stamp backup_conf="" backup_main="" service="" effective

    command -v sshd >/dev/null 2>&1 || { err "No se encontró sshd. Instala/ verifica el servidor OpenSSH."; return 1; }
    mkdir -p /etc/ssh/sshd_config.d || return 1

    # OpenSSH usa el primer valor encontrado. El prefijo 00 hace que Nexora
    # se lea antes que 50-cloud-init.conf y otros archivos habituales.
    if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        err "Este sshd_config no incluye /etc/ssh/sshd_config.d/*.conf. No se modificó nada para evitar una configuración insegura."
        warn "Se necesita adaptar manualmente el archivo principal antes de continuar."
        return 1
    fi

    stamp=$(date +%Y%m%d%H%M%S)
    if [[ -e "$conf" ]]; then
        backup_conf="${conf}.nexora-bak-${stamp}"
        cp -a "$conf" "$backup_conf" || { err "No se pudo respaldar $conf"; return 1; }
    fi
    backup_main="/etc/ssh/sshd_config.nexora-bak-${stamp}"
    cp -a /etc/ssh/sshd_config "$backup_main" || { err "No se pudo respaldar sshd_config"; return 1; }

    case "$mode" in
        password)
            cat > "$conf" <<'EOF'
# Administrado por Nexora. Tiene prioridad sobre cloud-init en instalaciones compatibles.
PermitRootLogin yes
PasswordAuthentication yes
EOF
            ;;
        key)
            cat > "$conf" <<'EOF'
# Administrado por Nexora. Permite root con clave pública, no con contraseña SSH.
PermitRootLogin prohibit-password
EOF
            ;;
        disable)
            cat > "$conf" <<'EOF'
# Administrado por Nexora.
PermitRootLogin no
EOF
            ;;
        *) err "Modo de acceso root desconocido."; return 1;;
    esac

    if ! sshd -t 2>/dev/null; then
        rm -f "$conf"
        [[ -n "$backup_conf" ]] && cp -a "$backup_conf" "$conf"
        cp -a "$backup_main" /etc/ssh/sshd_config
        err "La configuración SSH no pasó la validación. Se restauraron los archivos anteriores."
        return 1
    fi

    effective=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null) || effective=""
    case "$mode" in
        password)
            if ! grep -qx 'permitrootlogin yes' <<<"$effective" || ! grep -qx 'passwordauthentication yes' <<<"$effective"; then
                rm -f "$conf"
                [[ -n "$backup_conf" ]] && cp -a "$backup_conf" "$conf"
                cp -a "$backup_main" /etc/ssh/sshd_config
                err "La configuración efectiva no permite root por contraseña. Se restauró el estado anterior."
                return 1
            fi
            ;;
        key)
            if ! grep -qx 'permitrootlogin prohibit-password' <<<"$effective"; then
                rm -f "$conf"
                [[ -n "$backup_conf" ]] && cp -a "$backup_conf" "$conf"
                cp -a "$backup_main" /etc/ssh/sshd_config
                err "No se pudo verificar el acceso root mediante clave. Se restauró el estado anterior."
                return 1
            fi
            ;;
        disable)
            if ! grep -qx 'permitrootlogin no' <<<"$effective"; then
                rm -f "$conf"
                [[ -n "$backup_conf" ]] && cp -a "$backup_conf" "$conf"
                cp -a "$backup_main" /etc/ssh/sshd_config
                err "No se pudo verificar el bloqueo de root. Se restauró el estado anterior."
                return 1
            fi
            ;;
    esac

    if systemctl list-unit-files ssh.service >/dev/null 2>&1 && systemctl is-active --quiet ssh 2>/dev/null; then
        service=ssh
    elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        service=sshd
    else
        err "No se identificó el servicio SSH para recargarlo. La configuración quedó validada, pero no se aplicó en ejecución."
        return 1
    fi
    if ! systemctl reload "$service"; then
        err "No se pudo recargar $service. Mantén abierta esta sesión y revisa el servicio. Respaldo: $backup_main"
        return 1
    fi

    ok "Configuración aplicada y verificada. Respaldo: $backup_main"
    warn "Mantén abierta esta sesión y prueba una segunda conexión antes de salir."
    case "$mode" in
        password) echo " Acceso root por contraseña habilitado. Asegúrate de haber establecido una contraseña con la opción 1.";;
        key) echo " Root acepta clave pública. Debes instalar tu clave pública en /root/.ssh/authorized_keys.";;
        disable) echo " El acceso root por SSH quedó deshabilitado.";;
    esac
}

tools_root_access() {
    local choice
    while true; do
        header "CONFIGURAR CLAVE Y ACCESO ROOT"
        echo " Estado efectivo para root:"
        if ! root_ssh_effective; then
            warn "No se pudo consultar la configuración efectiva de sshd."
        fi
        echo
        item 1 "Establecer / cambiar contraseña root"
        item 2 "Habilitar root por SSH y contraseña"
        item 3 "Permitir root solamente con clave SSH" "no desactiva contraseñas de otros usuarios"
        item 4 "Desactivar acceso root por SSH"
        item 0 "Volver"; line
        read -r -p " Opción: " choice
        case "$choice" in
            1)
                if passwd root; then
                    ok "Contraseña root actualizada."
                    warn "Esto no habilita por sí solo el acceso SSH; usa la opción 2 si lo necesitas."
                else
                    err "No se pudo cambiar la contraseña root."
                fi
                pause
                ;;
            2|3|4)
                case "$choice" in
                    2)
                        warn "Esto permitirá iniciar sesión como root usando contraseña SSH. Usa una contraseña fuerte."
                        read -r -p " ¿Continuar? Escribe SI: " confirm
                        [[ "$confirm" == SI ]] || { warn "Cancelado."; continue; }
                        root_ssh_apply password
                        ;;
                    3)
                        warn "Asegúrate de que /root/.ssh/authorized_keys contiene tu clave pública antes de aplicar."
                        read -r -p " ¿Continuar? Escribe SI: " confirm
                        [[ "$confirm" == SI ]] || { warn "Cancelado."; continue; }
                        root_ssh_apply key
                        ;;
                    4)
                        warn "Se bloqueará el inicio de sesión SSH directo como root. Tu sesión actual no debería cerrarse."
                        read -r -p " ¿Continuar? Escribe SI: " confirm
                        [[ "$confirm" == SI ]] || { warn "Cancelado."; continue; }
                        root_ssh_apply disable
                        ;;
                esac
                pause
                ;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}

menu_tools() {
    local o
    while true; do
        header "HERRAMIENTAS EXTRA"
        item 1 "Administrador de certificados SSL" "Let's Encrypt · renovación"
        item 2 "Administrador Banner SSH/Dropbear"
        item 3 "Configurar clave y acceso root"
        item 4 "Configurar dominio" "agregar · comprobar · eliminar"
        item 5 "Configurar fecha y hora" "zona horaria · NTP · manual"
        item 0 "Volver"
        line
        read -r -p " Opción: " o
        case "$o" in
            1) tools_ssl;;
            2) tools_banner_menu;;
            3) tools_root_access;;
            4) tools_domain;;
            5) tools_time;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}
