#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""PPriv.py - Socks Python SEGURO (Nexora, Python 2.7 / 3)

Proxy HTTP con banner personalizado.

Parametros compatibles con el original: -p puerto  -t texto  -i ip

Destinos: igual que el original en la practica, NO se bloquea ningun destino
(el "seguro" original mandaba un 403 suelto pero seguia reenviando el flujo, y
solo se caia con puertos distintos de 22/443). Asi los payloads que mandan una URL
externa o encadenan metodos siguen funcionando. Si quieres restringir:
  -S / --strict  solo permite la IP del servidor (-i), 127.0.0.1 y localhost, y
                 en CONNECT solo los puertos de -P (por defecto "22,443").

Metodos soportados (igual que el original):
  * CONNECT  -> tunel; responde "HTTP/1.1 200 <banner>".
  * GET / POST / HEAD planos -> se reenvian y se devuelve la respuesta. Se pueden
    encadenar varias peticiones en la misma conexion (payload "GET ... [split]
    CONNECT ...") porque el bucle sigue leyendo hasta que llega el CONNECT.

Correcciones respecto al original:
  * Con -S el filtro se valida ANTES de conectar (el original abria el tunel y
    seguia reenviando) y la comparacion de host es exacta (antes subcadena).
  * 'hostip' quedaba sin definir con puertos distintos de 22/443 (crash).
  * Ya no borra la pantalla con "clear" (rompia bajo systemd) ni usa StringIO
    para datos binarios.
"""
from __future__ import print_function

import argparse
import select
import socket
import sys
import threading

try:                                    # Python 3
    import http.client as httplib
    from urllib.parse import urlsplit
except ImportError:                     # Python 2
    import httplib
    from urlparse import urlsplit

NET_ERRORS = (socket.error, select.error, IOError, OSError)


def out(msg=''):
    print(msg)
    sys.stdout.flush()


def native(b):
    """bytes -> str nativo (Python 2: igual; Python 3: latin-1)."""
    return b if str is bytes else b.decode('latin-1')


def to_bytes(s):
    if isinstance(s, bytes):
        return s
    return s.encode('utf-8', 'ignore')


def to_bytes_l1(s):
    if isinstance(s, bytes):
        return s
    return s.encode('latin-1', 'replace')


parser = argparse.ArgumentParser()
parser.add_argument("-p", "--port", help="Puerto en el que escucha el proxy")
parser.add_argument("-t", "--texto", help="Mini-banner de la respuesta (texto o HTML)")
parser.add_argument("-i", "--ip", help="IP publica del servidor (destino permitido)")
parser.add_argument("-P", "--ports", default="22,443", help="Puertos CONNECT permitidos (solo con -S)")
parser.add_argument("-S", "--strict", action="store_true", help="Restringe los destinos al propio servidor")
args = parser.parse_args()
STRICT = args.strict

if not args.port:
    out(" Deve ingresar el puerto que usara como socks...")
    sys.exit(1)
try:
    PORT = int(args.port)
    ALLOWED_PORTS = set(int(x) for x in args.ports.split(',') if x.strip())
except ValueError:
    out(" Puertos invalidos...")
    sys.exit(1)

BANNER = args.texto or '<strong><font color="#00FFFF">Nexora</font></strong>'
BANNER = BANNER.replace('\r', ' ').replace('\n', ' ')
SERVER_IP = args.ip or '127.0.0.1'
ALLOWED_HOSTS = set(['127.0.0.1', 'localhost', '::1', SERVER_IP.lower()])

RESPONSE = to_bytes('HTTP/1.1 200 %s\r\n\r\n' % BANNER)

IDLE_TIMEOUT = 300          # igual que el original (timeout = 300)
UPSTREAM_TIMEOUT = 60
MAX_HEAD = 16384
MAX_BODY = 10 * 1024 * 1024
MAX_CONN = 1000
BUFLEN = 16384
PLAIN_METHODS = ('GET', 'POST', 'HEAD')      # los mismos que soportaba el original
HOP_BY_HOP = ('connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
              'te', 'trailers', 'trailer', 'transfer-encoding', 'upgrade')

_active = threading.BoundedSemaphore(MAX_CONN)


def allowed(host, port, plain=False):
    if not STRICT:
        return True
    if host.lower() not in ALLOWED_HOSTS:
        return False
    # HTTP plano (GET/POST/HEAD): ademas de los puertos de CONNECT se permite el 80 local
    return port in ALLOWED_PORTS or (plain and port == 80)


def parse_target(value):
    value = value.strip()
    if value.startswith('['):
        end = value.find(']')
        host = value[1:end]
        rest = value[end + 1:]
        port = int(rest[1:]) if rest.startswith(':') else 443
    elif value.count(':') == 1:
        host, p = value.split(':')
        port = int(p)
    else:
        host, port = value, 443
    if not host or not 1 <= port <= 65535:
        raise ValueError('destino invalido')
    return host.lower(), port


def parse_head(head):
    lines = head.lstrip('\r\n').split('\r\n')
    parts = lines[0].split()
    headers = []
    for line in lines[1:]:
        if ':' in line:
            k, v = line.split(':', 1)
            headers.append((k.strip(), v.strip()))
    return parts, headers


def get_header(headers, name, default=''):
    name = name.lower()
    for k, v in headers:
        if k.lower() == name:
            return v
    return default


class Reader(object):
    """Lector con buffer: permite varias peticiones HTTP seguidas en la misma conexion
    (p. ej. un payload "GET ... [split] CONNECT ...") sin perder datos."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b''

    def read_head(self):
        self.buf = self.buf.lstrip(b'\r\n')          # CRLF sueltos entre peticiones
        while True:
            i = self.buf.find(b'\r\n\r\n')
            if i != -1:
                head, self.buf = self.buf[:i], self.buf[i + 4:]
                return native(head)
            if len(self.buf) > MAX_HEAD:
                raise ValueError('cabecera demasiado grande')
            chunk = self.sock.recv(4096)
            if not chunk:
                return None
            self.buf += chunk

    def read_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(min(65536, n - len(self.buf)))
            if not chunk:
                raise IOError('el cliente cerro durante el cuerpo')
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n:]
        return data


def relay(a, b):
    socs = [a, b]
    while True:
        try:
            r, _, x = select.select(socs, [], socs, IDLE_TIMEOUT)
            if x or not r:
                return
            for s in r:
                data = s.recv(BUFLEN)
                if not data:
                    return
                (b if s is a else a).sendall(data)
        except NET_ERRORS + (ValueError,):
            return


def do_connect(client, reader, who, target):
    try:
        host, port = parse_target(target)
    except ValueError:
        client.sendall(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n')
        return
    if not allowed(host, port):
        out('%s DENEGADO -> %s:%d' % (who, host, port))
        client.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
        return
    try:
        remote = socket.create_connection((host, port), timeout=10)
    except NET_ERRORS:
        client.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
        return
    try:
        remote.settimeout(None)
        remote.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client.settimeout(None)
        client.sendall(RESPONSE)
        if reader.buf:                       # datos que el cliente mando pegados al CONNECT
            remote.sendall(reader.buf)
            reader.buf = b''
        out('%s -> %s:%d' % (who, host, port))
        relay(client, remote)
    finally:
        try:
            remote.close()
        except NET_ERRORS:
            pass


def do_plain(client, reader, who, method, target, headers, keep):
    """GET / POST / HEAD planos, como el original: se reenvian al destino y se devuelve la
    respuesta. Si el destino no responde (o no esta permitido) no se envia nada y la
    conexion sigue abierta, para que pueda llegar el CONNECT siguiente del payload."""
    try:
        length = int(get_header(headers, 'content-length', '0') or 0)
    except ValueError:
        length = 0
    body = None
    if length > MAX_BODY:
        raise ValueError('cuerpo demasiado grande')
    if length > 0:
        body = reader.read_exact(length)

    try:
        u = urlsplit(target)
        selector = (u.path or '/') + ('?' + u.query if u.query else '')
        if u.scheme in ('http', 'https') and u.hostname:
            scheme, host, netloc = u.scheme, u.hostname, u.netloc
            port = u.port or (443 if scheme == 'https' else 80)
        else:                                # "GET / HTTP/1.1": igual que el original, puerto 80 local
            scheme, host, port, netloc = 'http', '127.0.0.1', 80, ''
    except ValueError:
        return
    if not allowed(host, port, True):
        out('%s DENEGADO (HTTP) -> %s:%d' % (who, host, port))
        return

    drop = set(HOP_BY_HOP)
    drop.add('host')
    for t in get_header(headers, 'connection').split(','):
        if t.strip():
            drop.add(t.strip().lower())
    fwd = dict((k, v) for k, v in headers if k.lower() not in drop)
    fwd['Host'] = netloc
    fwd['Connection'] = 'close'

    try:
        if scheme == 'https':
            up = httplib.HTTPSConnection(host, port, timeout=UPSTREAM_TIMEOUT)
        else:
            up = httplib.HTTPConnection(host, port, timeout=UPSTREAM_TIMEOUT)
        try:
            up.request(method, selector, body, headers=fwd)
            res = up.getresponse()
            data = res.read()
            status, reason, rheaders = res.status, res.reason, res.getheaders()
        finally:
            up.close()
    except NET_ERRORS + (httplib.HTTPException,):
        out('%s %s %s:%d sin respuesta' % (who, method, host, port))
        return

    hdrs = [(k, v) for k, v in rheaders if k.lower() not in HOP_BY_HOP and k.lower() != 'content-length']
    no_body = method == 'HEAD' or status in (204, 304) or 100 <= status < 200
    if method == 'HEAD':
        for k, v in rheaders:
            if k.lower() == 'content-length':
                hdrs.append(('Content-Length', v))
    elif not no_body:
        hdrs.append(('Content-Length', str(len(data))))
    hdrs.append(('Connection', 'Keep-Alive' if keep else 'close'))
    text = 'HTTP/1.1 %d %s\r\n' % (status, reason) + ''.join('%s: %s\r\n' % kv for kv in hdrs) + '\r\n'
    client.sendall(to_bytes_l1(text) + (b'' if no_body else data))
    out('%s %s %s:%d -> %d' % (who, method, host, port, status))


def serve(client, addr):
    reader = Reader(client)
    who = '%s:%s' % (addr[0], addr[1])
    while True:
        head = reader.read_head()
        if head is None:
            return
        parts, headers = parse_head(head)
        if not parts:
            continue
        if len(parts) == 2:
            parts.append('HTTP/1.0')
        if len(parts) != 3:
            client.sendall(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            return
        method, target, version = parts[0].upper(), parts[1], parts[2].upper()
        if method == 'CONNECT':
            do_connect(client, reader, who, target)
            return
        if method in PLAIN_METHODS:
            conn_hdr = get_header(headers, 'connection').lower()
            keep = ('keep-alive' in conn_hdr) if version == 'HTTP/1.0' else ('close' not in conn_hdr)
            do_plain(client, reader, who, method, target, headers, keep)
            if not keep:
                return
            continue
        client.sendall(b'HTTP/1.1 501 Unsupported method\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
        return


def handle(client, addr):
    try:
        client.settimeout(IDLE_TIMEOUT)
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        serve(client, addr)
    except socket.timeout:
        pass
    except Exception as e:
        out('%s:%s error: %s' % (addr[0], addr[1], e))
    finally:
        try:
            client.close()
        except NET_ERRORS:
            pass
        _active.release()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', PORT))
    srv.listen(128)
    out(("Servidor: 0.0.0.0 Porta %d  (modo estricto: destinos %s, puertos %s)" % (
        PORT, ','.join(sorted(ALLOWED_HOSTS)), ','.join(str(p) for p in sorted(ALLOWED_PORTS)))
        if STRICT else "Servidor: 0.0.0.0 Porta %d  (sin restriccion de destino)" % PORT))
    try:
        while True:
            c, addr = srv.accept()
            if not _active.acquire(False):
                c.close()
                continue
            t = threading.Thread(target=handle, args=(c, addr))
            t.daemon = True
            t.start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()


if __name__ == '__main__':
    main()
