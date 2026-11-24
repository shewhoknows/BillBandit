import contextlib
import http.client
import http.server
import json
import socket
import threading


@contextlib.contextmanager
def qa_proxy(upstream_port):
    lock = threading.Lock()
    settings = {"offline": False, "drop": False}

    class Handler(http.server.BaseHTTPRequestHandler):
        def proxy(self):
            size = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(size) if size else None
            if self.command == "PUT" and self.path == "/__qa/network":
                control = json.loads(body or b"{}")
                with lock:
                    settings["offline"] = control.get("offline", False)
                    settings["drop"] = control.get("dropNextExpenseResponse", False)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")
                return
            if settings["offline"]:
                self.send_error(503)
                return
            connection = http.client.HTTPConnection("127.0.0.1", upstream_port)
            try:
                headers = {k: v for k, v in self.headers.items() if k.lower() not in {"host", "connection", "accept-encoding"}}
                connection.request(self.command, self.path, body=body, headers=headers)
                response = connection.getresponse()
                payload = response.read()
                with lock:
                    drop = settings["drop"] and self.command == "POST" and self.path == "/api/mobile/expenses" and 200 <= response.status < 300
                    if drop:
                        settings["drop"] = False
                if drop:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.close_connection = True
                    return
                self.send_response(response.status)
                for key in ("Content-Type",):
                    if response.getheader(key):
                        self.send_header(key, response.getheader(key))
                self.end_headers()
                self.wfile.write(payload)
            except ConnectionError:
                self.send_error(502)
            finally:
                connection.close()

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = proxy

        def log_message(self, *_):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .05}, daemon=True)
        thread.start()
        try:
            yield server.server_port
        finally:
            server.shutdown()
            thread.join()
