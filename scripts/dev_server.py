"""Local-only preview server with the same clean routes as Netlify."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
import argparse

class PreviewHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        routes = {'/werkruimte': '/werkruimte.html', '/dashboard': '/dashboard.html'}
        if url.path in routes:
            self.path = urlunsplit(('', '', routes[url.path], url.query, ''))
        super().do_GET()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8767)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1] / 'dist'
    def handler(*a, **kw):
        return PreviewHandler(*a, directory=str(root), **kw)
    print(f'Local preview: http://localhost:{args.port}/werkruimte', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), handler).serve_forever()
