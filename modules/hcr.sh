# ==========================================================
#  Módulo HCR (servidor de los creadores de HTTP Custom)
#
#  Nexora NO incluye ni redistribuye el binario. Vos ponés los archivos
#  oficiales (install.sh y hcr-server) en una carpeta del VPS y este módulo
#  los instala usando el instalador del propio fabricante.
#  El servicio se llama "hcr-server" porque así lo define ese instalador.
# ==========================================================
HCR_SVC="hcr-server"
HCR_DIR="${APP_DIR}/hcr"
HCR_STAGE_DEFAULT="/root/hcr"
HCR_CONF="${DB_DIR}/hcr.conf"          # puerto y transporte elegidos

hcr_installed() { [[ -x "$HCR_DIR/hcr-server" && -x "$HCR_DIR/install.sh" ]]; }
hcr_conf_get()  { grep -E "^$1=" "$HCR_CONF" 2>/dev/null | cut -d= -f2; }

# Ejecuta el instalador oficial:  hcr_run_installer <puerto> <transporte>
hcr_run_installer() { ( cd "$HCR_DIR" && ./install.sh --port "$1" --transport "$2" ); }

hcr_install() {
    header "HCR · INSTALAR"
    local stage p t c sum
    echo -e " ${DIM}Poné los archivos oficiales en una carpeta del VPS:${W}"
    echo -e " ${DIM}  install.sh y hcr-server (y fullchain.pem + privkey.pem si usás TLS)${W}"
    echo
    read -rp " Carpeta de origen [$HCR_STAGE_DEFAULT]: " stage; stage=${stage:-$HCR_STAGE_DEFAULT}
    if [[ ! -f "$stage/install.sh" || ! -f "$stage/hcr-server" ]]; then
        err "No encuentro install.sh y hcr-server en $stage"; pause; return
    fi

    read -rp " Puerto (1024-65535) [8880]: " p; p=${p:-8880}
    if ! { is_num "$p" && (( p >= 1024 && p <= 65535 )); }; then
        err "Puerto inválido (usá 1024 o más)"; pause; return
    fi
    if port_busy "$p" hcr-server; then err "El puerto $p ya está en uso"; pause; return; fi

    read -rp " Transporte [plain/tls/auto] (plain): " t; t=${t:-plain}
    case "$t" in plain|tls|auto) ;; *) err "Transporte inválido"; pause; return;; esac
    if [[ "$t" != "plain" ]]; then
        if [[ ! -f "$stage/fullchain.pem" || ! -f "$stage/privkey.pem" ]]; then
            err "Para '$t' hacen falta fullchain.pem y privkey.pem en $stage"; pause; return
        fi
    fi

    sum=$(sha256sum "$stage/hcr-server" | awk '{print $1}')
    echo; echo -e " Huella SHA-256 del binario:"; echo -e " ${Y}${sum}${W}"; echo
    warn "Es un programa cerrado y va a correr como root (con restricciones de systemd)."
    warn "Compará la huella con la del canal oficial de los creadores."
    read -rp " ¿Coincide y querés continuar? [s/N]: " c
    [[ "$c" =~ ^[sS]$ ]] || { warn "Cancelado"; pause; return; }

    mkdir -p "$HCR_DIR"; chown root:root "$HCR_DIR"; chmod 755 "$HCR_DIR"
    # Si el archivo vino de Windows puede traer saltos de línea CRLF: se corrigen
    if grep -q $'\r' "$stage/install.sh"; then sed -i 's/\r$//' "$stage/install.sh"; fi
    install -m 755 -o root -g root "$stage/install.sh" "$HCR_DIR/install.sh"
    install -m 755 -o root -g root "$stage/hcr-server" "$HCR_DIR/hcr-server"
    if [[ "$t" != "plain" ]]; then
        install -m 644 -o root -g root "$stage/fullchain.pem" "$HCR_DIR/fullchain.pem"
        install -m 600 -o root -g root "$stage/privkey.pem"   "$HCR_DIR/privkey.pem"
    fi

    echo
    if hcr_run_installer "$p" "$t"; then
        printf 'port=%s\ntransport=%s\n' "$p" "$t" > "$HCR_CONF"
        open_port "$p"
        ok "HCR activo en el puerto $p (transporte $t)"
    else
        err "El instalador oficial reportó un error (mirá el mensaje de arriba)"
    fi
    pause
}

# Ajusta MAX_DOWNLOAD_FRAME y DOWNLOAD_POLL_TIMEOUT (las variables que el
# fabricante indica modificar dentro de su install.sh) y reinstala.
hcr_tuning() {
    header "HCR · AJUSTE DE RENDIMIENTO"
    hcr_installed || { err "Instalá HCR primero"; pause; return; }
    local cur_f cur_t f t port transport
    cur_f=$(grep -E '^MAX_DOWNLOAD_FRAME=' "$HCR_DIR/install.sh" | cut -d'"' -f2)
    cur_t=$(grep -E '^DOWNLOAD_POLL_TIMEOUT=' "$HCR_DIR/install.sh" | cut -d'"' -f2)
    echo -e " Valores actuales: frame ${G}${cur_f}${W} · timeout ${G}${cur_t}${W}"; echo
    read -rp " MAX_DOWNLOAD_FRAME [$cur_f]: " f; f=${f:-$cur_f}
    read -rp " DOWNLOAD_POLL_TIMEOUT, ej. 8s [$cur_t]: " t; t=${t:-$cur_t}
    is_num "$f" || { err "El frame tiene que ser un número"; pause; return; }
    [[ "$t" =~ ^[0-9]+(ms|s|m)$ ]] || { err "Timeout inválido (ej: 8s, 500ms, 1m)"; pause; return; }

    sed -i "s/^MAX_DOWNLOAD_FRAME=.*/MAX_DOWNLOAD_FRAME=\"$f\"/; s/^DOWNLOAD_POLL_TIMEOUT=.*/DOWNLOAD_POLL_TIMEOUT=\"$t\"/" "$HCR_DIR/install.sh"
    port=$(hcr_conf_get port); transport=$(hcr_conf_get transport)
    if [[ -z "$port" || -z "$transport" ]]; then
        err "No tengo guardado el puerto; reinstalá desde la opción 1"; pause; return
    fi
    if hcr_run_installer "$port" "$transport"; then ok "Ajustes aplicados"; else err "No se pudo reaplicar"; fi
    pause
}

hcr_uninstall() {
    header "HCR · DESINSTALAR"; confirm_si || return
    local c
    if hcr_installed; then ( cd "$HCR_DIR" && ./install.sh --uninstall ); fi
    read -rp " ¿Borrar también los archivos de $HCR_DIR? [s/N]: " c
    if [[ "$c" =~ ^[sS]$ ]]; then rm -rf "$HCR_DIR" "$HCR_CONF"; fi
    ok "HCR desinstalado"; pause
}

hcr_menu() {
    local o st
    while true; do
        header "HCR · SERVIDOR HTTP CUSTOM"
        if svc_on "$HCR_SVC"; then st="${G}● ACTIVO${W}  ${DIM}puerto $(hcr_conf_get port) · $(hcr_conf_get transport)${W}"
        elif hcr_installed; then st="${R}● DETENIDO${W}"
        else st="${Y}no instalado${W}"; fi
        echo -e " Estado: $st"; thin
        item 1 "Instalar / reconfigurar"
        item 2 "Ajuste de rendimiento"
        item 3 "Iniciar o detener"
        item 4 "Desinstalar"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        case $o in
            1) hcr_install;;
            2) hcr_tuning;;
            3) if hcr_installed; then svc_toggle "$HCR_SVC"; else err "Instalá HCR primero"; sleep 1; fi;;
            4) hcr_uninstall;;
            0) return;;
        esac
    done
}
