#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PDirect.py - Socks Python DIRECTO (Nexora, Python 2.7 / 3)

Basado en el PDirect.py de ADMRufu. Parametros compatibles:
  -p puerto  -l puerto_local  -r response  -t texto  -c contraseña

Mejoras respecto a la version anterior:
  * Seguridad: sin contraseña, solo se acepta X-Real-Host de un host local
    (comparacion exacta; antes "127.0.0.1.dominio.com" pasaba el filtro y
    el proxy funcionaba como proxy abierto). Igual que el original, se
    respeta el puerto que el cliente mande en X-Real-Host (sin puerto = 22).
  * Modo automatico SSH/raw: se detecta si el destino habla primero (SSH y
    Dropbear envian "SSH-..."). Si es SSH se descarta el payload HTTP; si no
    (OpenVPN, etc.) se reenvia tal cual. Antes todo trafico que no
    contuviera "SSH-" se perdia.
  * Cabeceras HTTP sin distinguir mayusculas, comparacion de clave en tiempo
    constante, timeouts de handshake, limite de conexiones y salida != 0
    cuando faltan parametros (systemd lo reporta como fallo).
"""
from __future__ import print_function

import argparse
import hmac
import re
import select
import socket
import sys
import threading
import time

NET_ERRORS = (socket.error, select.error, IOError, OSError)


def out(msg=''):
    print(msg)
    sys.stdout.flush()


def to_bytes(s):
    """str/unicode -> bytes en Python 2 y 3."""
    if isinstance(s, bytes):
        return s
    return s.encode('utf-8', 'ignore')


try:
    compare_digest = hmac.compare_digest
except AttributeError:          # Python 2 anterior a 2.7.7
    def compare_digest(a, b):
        if len(a) != len(b):
            return False
        r = 0
        for x, y in zip(bytearray(a), bytearray(b)):
            r |= x ^ y
        return r == 0

parser = argparse.ArgumentParser()
parser.add_argument("-l", "--local", help="Puerto local SSH/DROPBEAR/OPENVPN al que se redirige")
parser.add_argument("-p", "--port", help="Puerto en el que escucha el proxy")
parser.add_argument("-c", "--contr", help="Contraseña (header X-Pass)")
parser.add_argument("-r", "--response", help="Codigo de respuesta (200 / 101)")
parser.add_argument("-t", "--texto", help="Mini-banner de la respuesta")
args = parser.parse_args()

LISTENING_ADDR = '0.0.0.0'
DEFAULT_HOST = '127.0.0.1'
LOCAL_HOSTS = ('127.0.0.1', 'localhost', '::1')

BUFLEN = 4096 * 4
HANDSHAKE_TIMEOUT = 15      # segundos para recibir el primer paquete
SSH_PROBE = 0.7             # espera al banner del destino para detectar SSH
IDLE_LIMIT = 60             # ciclos de 3 s sin datos (180 s) antes de cortar
MAX_CONN = 1000


def die(msg):
    out(msg)
    sys.exit(1)


if not args.port:
    die(" Deve ingresar el puerto que usara como socks...")
if not args.local:
    die(" Deve seleccionar un puerto existente para redireccionar el trafico...")
try:
    LISTENING_PORT = int(args.port)
    LOCAL_PORT = int(args.local)
except ValueError:
    die(" Los puertos deben ser numericos...")

PASS = str(args.contr) if args.contr else ''
STATUS_RESP = args.response if args.response else '200'

if args.texto:
    STATUS_TXT = args.texto
elif STATUS_RESP == '101':
    STATUS_TXT = 'Web Socket Protocol Handshake\r\nConnection: Upgrade\r\nUpgrade: websocket'
else:
    STATUS_TXT = '<font color="red">Connection Established</font>\r\nContent-length: 0'

RESPONSE = to_bytes('HTTP/1.1 ' + STATUS_RESP + ' ' + STATUS_TXT +
            '\r\n\r\nHTTP/1.1 200 Connection Established\r\n\r\n')


def find_header(head, name):
    m = re.search(r'^' + re.escape(name) + r':[ \t]*(.*?)\r?$', head, re.I | re.M)
    return m.group(1).strip() if m else ''


def split_hostport(value, default_port=22):
    value = value.strip()
    if value.startswith('['):                      # [::1]:22
        end = value.find(']')
        if end == -1:
            raise ValueError('host invalido')
        host, rest = value[1:end], value[end + 1:]
        port = int(rest[1:]) if rest.startswith(':') else default_port
    elif value.count(':') == 1:
        host, p = value.split(':')
        port = int(p)
    else:
        host, port = value, default_port
    if not host or not 1 <= port <= 65535:
        raise ValueError('host/puerto invalido')
    return host, port


def connect_target(host, port):
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(None)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.daemon = True
        self.host = host
        self.port = port
        self.running = False
        self.threads = []
        self.lock = threading.Lock()

    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(128)
        self.running = True
        try:
            while self.running:
                try:
                    c, addr = self.soc.accept()
                except socket.timeout:
                    continue
                except NET_ERRORS:
                    continue
                with self.lock:
                    full = len(self.threads) >= MAX_CONN
                if full:
                    c.close()
                    continue
                c.setblocking(True)
                c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                conn = ConnectionHandler(c, self, addr)
                with self.lock:
                    self.threads.append(conn)
                conn.start()
        finally:
            self.running = False
            self.soc.close()

    def print_log(self, log):
        out(log)

    def remove(self, conn):
        with self.lock:
            if conn in self.threads:
                self.threads.remove(conn)

    def close(self):
        self.running = False
        with self.lock:
            threads = list(self.threads)
        for c in threads:
            c.close()


class ConnectionHandler(threading.Thread):
    def __init__(self, client, server, addr):
        threading.Thread.__init__(self)
        self.daemon = True
        self.client = client
        self.server = server
        self.target = None
        self.log = 'Connection: %s:%s' % (addr[0], addr[1])
        self.mode = 'ssh'          # 'ssh' = filtra payload hasta "SSH-"; 'raw' = reenvia todo
        self.pending = b''
        self.ssh_ready = False
        self.first_target = b''

    def close(self):
        for s in (self.client, self.target):
            if s is None:
                continue
            try:
                s.shutdown(socket.SHUT_RDWR)
            except NET_ERRORS:
                pass
            try:
                s.close()
            except NET_ERRORS:
                pass

    def run(self):
        try:
            self.handle()
        except Exception as e:
            self.log += ' - error: %s' % e
            self.server.print_log(self.log)
        finally:
            self.close()
            self.server.remove(self)

    def reply(self, data):
        try:
            self.client.sendall(data)
        except NET_ERRORS:
            pass

    def handle(self):
        self.client.settimeout(HANDSHAKE_TIMEOUT)
        first = self.client.recv(BUFLEN)
        if not first:
            return

        # SSH directo, sin payload: no se manda respuesta HTTP
        if first.startswith(b'SSH-'):
            self.log += ' - SSH directo'
            self.target = connect_target(DEFAULT_HOST, LOCAL_PORT)
            self.target.sendall(first)
            self.mode = 'raw'
            self.client.settimeout(None)
            self.server.print_log(self.log)
            self.relay()
            return

        head = first.decode('latin-1')
        host_port = find_header(head, 'X-Real-Host')

        if find_header(head, 'X-Split'):
            try:
                first += self.client.recv(BUFLEN)
            except socket.timeout:
                pass

        try:
            if PASS:
                given = find_header(head, 'X-Pass')
                if not compare_digest(to_bytes(given), to_bytes(PASS)):
                    self.reply(b'HTTP/1.1 400 WrongPass!\r\n\r\n')
                    return
                host, port = split_hostport(host_port) if host_port else (DEFAULT_HOST, LOCAL_PORT)
            elif host_port:
                # Sin contraseña solo se permite un host local, pero se respeta el puerto
                # que mande el cliente en X-Real-Host (igual que el original)
                host, port = split_hostport(host_port)
                if host.lower() not in LOCAL_HOSTS:
                    self.server.print_log(self.log + ' - X-Real-Host denegado: %s' % host_port)
                    self.reply(b'HTTP/1.1 403 Forbidden!\r\n\r\n')
                    return
            else:
                host, port = DEFAULT_HOST, LOCAL_PORT
        except ValueError:
            self.reply(b'HTTP/1.1 400 BadXRealHost!\r\n\r\n')
            return

        self.log += ' - CONNECT %s:%d' % (host, port)
        self.target = connect_target(host, port)
        self.probe_target()
        self.log += ' [%s]' % self.mode

        self.client.sendall(RESPONSE)
        if self.first_target:
            self.client.sendall(self.first_target)
        if self.mode == 'ssh':
            self.forward_client(first)      # rescata un "SSH-" que venga pegado al payload
        self.client.settimeout(None)
        self.server.print_log(self.log)
        self.relay()

    def probe_target(self):
        """SSH/Dropbear hablan primero; OpenVPN y otros no."""
        r, _, _ = select.select([self.target], [], [], SSH_PROBE)
        if r:
            data = self.target.recv(BUFLEN)
            if not data:
                raise OSError('el destino cerro la conexion')
            self.first_target = data
            self.mode = 'ssh' if data.startswith(b'SSH-') else 'raw'
        else:
            self.mode = 'raw'

    def forward_client(self, data):
        if self.mode == 'raw' or self.ssh_ready:
            self.target.sendall(data)
            return
        # hasta ver "SSH-" se descarta todo (payload, split, \r\n sobrantes)
        self.pending += data
        i = self.pending.find(b'SSH-')
        if i != -1:
            self.target.sendall(self.pending[i:])
            self.pending = b''
            self.ssh_ready = True
        elif len(self.pending) > 65536:
            raise Exception('payload demasiado grande sin SSH-')
        else:
            self.pending = self.pending[-3:]

    def relay(self):
        socs = [self.client, self.target]
        idle = 0
        while True:
            try:
                recv, _, err = select.select(socs, [], socs, 3)
            except NET_ERRORS + (ValueError,):
                break
            if err:
                break
            if not recv:
                idle += 1
                if idle >= IDLE_LIMIT:
                    break
                continue
            idle = 0
            try:
                for s in recv:
                    data = s.recv(BUFLEN)
                    if not data:
                        return
                    if s is self.target:
                        self.client.sendall(data)
                    else:
                        self.forward_client(data)
            except NET_ERRORS:
                break


def main():
    print("\n:-------PythonProxy-------:\n")
    print("Listening addr: " + LISTENING_ADDR)
    print("Listening port: " + str(LISTENING_PORT))
    print("Local port    : " + str(LOCAL_PORT) + "\n")
    out(":-------------------------:\n")
    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()
    while True:
        try:
            time.sleep(2)
            if not server.is_alive():
                out('El servidor se detuvo')
                sys.exit(1)
        except KeyboardInterrupt:
            print('Stopping...')
            server.close()
            break


if __name__ == '__main__':
    main()
