#!/bin/bash
# Nexora: inicio automatico solo en sesiones SSH interactivas de root.
# Este archivo se carga desde /etc/profile; no debe cerrar ni reemplazar la shell.
if [[ $- == *i* ]] \
    && [[ ${EUID:-1} -eq 0 ]] \
    && [[ -n ${SSH_CONNECTION:-} ]] \
    && [[ -f /etc/nexora/autostart.enabled ]] \
    && [[ -z ${NEXORA_AUTOSTART_DONE:-} ]]; then
    export NEXORA_AUTOSTART_DONE=1
    /usr/local/bin/nexora || true
fi
