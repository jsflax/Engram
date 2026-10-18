#!/usr/bin/env python3
"""Serve the workflow artifact directory on the fixed numeric loopback endpoint."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer


class NumericLoopbackServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls getfqdn before listen. This mirror needs
        # no DNS name; preserve TCPServer's bind/socket options and HTTP serving.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args(argv)
    directory = args.directory.resolve(strict=True)
    if not directory.is_dir():
        parser.error('artifact directory is not a directory')
    handler = partial(SimpleHTTPRequestHandler, directory=str(directory))
    with NumericLoopbackServer(('127.0.0.1', 8765), handler) as server:
        server.serve_forever()


if __name__ == '__main__':
    main()
