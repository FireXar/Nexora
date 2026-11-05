#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PPriv.py - Socks Python SEGURO para Nexora
import sys, http.client, socket, select, gzip, zlib, re, traceback, subprocess, argparse
from socketserver import ThreadingMixIn
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Lock, Timer
from io import StringIO
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("-p", "--port", help="Puerto de escucha")
parser.add_argument("-t", "--texto", help="Banner HTML o plano")
parser.add_argument("-i", "--ip", help="IP permitida")
args = parser.parse_args()

if args.port:
    port = int(args.port)
else:
    print("Debe ingresar el puerto que usara como socks...")
    sys.exit()

if args.texto:
    msg1 = args.texto
else:
    msg1 = '<strong><font color="#00FFFF">N</font><font color="#6bffff">e</font><font color="#99ffff">x</font><font color="#ebffff">o</font><font color="#ebffff">r</font><font color="#ccffff">a</font></strong>'

if args.ip:
    server = args.ip
else:
    server = "127.0.0.1"

msg2 = 'Server Forbidden'

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    address_family = socket.AF_INET
    def handle_error(self, request, client_address):
        print('-'*40, file=sys.stderr)
        traceback.print_exc()
        print('-'*40, file=sys.stderr)

class SimpleHTTPProxyHandler(BaseHTTPRequestHandler):
    global_lock = Lock()
    conn_table = {}
    timeout = 300
    upstream_timeout = 300
    proxy_via = None

    def log_error(self, format, *args):
        if format == "Request timed out: %r":
            return
        self.log_message(format, *args)

    def do_CONNECT(self):
        req = self
        reqbody = None
        hostip = req.path.replace(':22', '').replace(':443', '')
        req.path = "https://%s/" % req.path.replace(':443', '')

        u = urlsplit(req.path)
        address = (u.hostname, u.port or 443)
        try:
            conn = socket.create_connection(address)
        except socket.error:
            return

        self.send_response(200, msg1)
        self.send_header('Connection', 'close')
        self.end_headers()

        conns = [self.connection, conn]
        keep_connection = True
        while keep_connection:
            if server.find(hostip) == -1:
                self.send_error(403, msg2)
                break
            keep_connection = False
            rlist, wlist, xlist = select.select(conns, [], conns, self.timeout)
            if xlist:
                break
            for r in rlist:
                other = conns[1] if r is conns[0] else conns[0]
                data = r.recv(8192)
                if data:
                    other.sendall(data)
                    keep_connection = True
        conn.close()

def test(HandlerClass=SimpleHTTPProxyHandler, ServerClass=ThreadingHTTPServer, protocol="HTTP/1.1"):
    server_address = ('', port)
    HandlerClass.protocol_version = protocol
    httpd = ServerClass(server_address, HandlerClass)
    sa = httpd.socket.getsockname()
    print("Servidor Nexora Privado en " + str(sa[0]) + " Puerto " + str(sa[1]))
    httpd.serve_forever()

if __name__ == '__main__':
    test()
