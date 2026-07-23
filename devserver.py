# 開発用サーバー: キャッシュ無効ヘッダ付き（本番はVercel等の静的ホスティングを使用）
import http.server, functools, sys

class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()

    def log_message(self, *args):  # ログを静かに
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8642
    handler = functools.partial(NoCacheHandler, directory=sys.argv[2] if len(sys.argv) > 2 else ".")
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
