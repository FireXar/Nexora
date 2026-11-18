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

menu_tools() {
    local o
    while true; do
        header "HERRAMIENTAS EXTRA"
        item 1 "Configurar dominio" "agregar · comprobar · eliminar"
        item 0 "Volver"
        line
        read -r -p " Opción: " o
        case "$o" in
            1) tools_domain;;
            0) return;;
            *) warn "Opción inválida"; sleep 1;;
        esac
    done
}
