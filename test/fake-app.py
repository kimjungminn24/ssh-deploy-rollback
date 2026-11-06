# A stand-in for a real app: /health is healthy while the deployed file starts with "ok".
import http.server, sys

target, port = sys.argv[1], int(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            body = open(target).read().strip()
        except OSError:
            body = ''
        code = 200 if body.startswith('ok') else 500
        self.send_response(code)
        self.end_headers()
        self.wfile.write(f'{{"status":"{"UP" if code == 200 else "DOWN"}","build":"{body}"}}'.encode())

    def log_message(self, *args):
        pass

http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
