#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# POpen.py - Socks Python OPENVPN para Nexora
import sys, http.client, socket, select, gzip, zlib, re, traceback, argparse
from socketserver import ThreadingMixIn
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Lock
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("-p", "--port", help="Puerto de escucha")
args = parser.parse_args()

if args.port:
    port = int(args.port)
else:
    print("Debe ingresar el puerto que usara como socks...")
    sys.exit()

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    address_family = socket.AF_INET

class SimpleHTTPProxyHandler(BaseHTTPRequestHandler):
    timeout = 300

    def do_CONNECT(self):
        req = self
        req.path = "https://%s/" % req.path.replace(':443', '')
        u = urlsplit(req.path)
        address = (u.hostname, u.port or 443)
        try:
            conn = socket.create_connection(address)
        except socket.error:
            return
        self.send_response(200, 'SOCKS5')
        self.send_header('Connection', 'close')
        self.end_headers()

        conns = [self.connection, conn]
        keep_connection = True
        while keep_connection:
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
    print("Servidor Nexora OpenVPN en puerto " + str(sa[1]))
    httpd.serve_forever()

if __name__ == '__main__':
    test()
