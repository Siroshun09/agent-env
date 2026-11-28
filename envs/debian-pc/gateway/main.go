// agent-env-gateway は、ブラウザから PC 内の画面を開くための入口。
//
// 入口は 2 つあり、どちらの入口で受けたかで認証を決める（Host ヘッダーは送る側が自由に決められるので、認証の判断には使わない）。
//   - SSH の転送の入口（-listen）: Mac からの SSH の転送を 1 本にまとめ、ホスト名で PC 内のサービスに振り分ける。
//     SSH の認証を通っているので、Basic 認証は求めない。
//   - tailnet の入口（-tailnet-listen）: 外出先から、tailscale serve が tailnet（Tailscale）で受けた HTTPS を中継する。
//     どのリクエストにも Basic 認証を求める。-tailnet-host を指定したときだけ待ち受ける。
//
// 外部のライブラリは使わない（標準ライブラリだけ）。
package main

import (
	"flag"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"
)

// 振り分け先のサービス。どれも PC 内の 127.0.0.1 だけで待ち受けている
var defaultUpstreams = upstreams{
	term:    &url.URL{Scheme: "http", Host: "127.0.0.1:7681"}, // ブラウザの端末（ttyd）
	llm:     &url.URL{Scheme: "http", Host: "127.0.0.1:8080"}, // ローカル LLM（llama-server）
	metrics: &url.URL{Scheme: "http", Host: "127.0.0.1:8428"}, // 指標（VictoriaMetrics）
	logs:    &url.URL{Scheme: "http", Host: "127.0.0.1:9428"}, // ログ（VictoriaLogs）
}

func main() {
	addr := flag.String("listen", "127.0.0.1:8700", "SSH の転送の入口のアドレス")
	tailnetAddr := flag.String("tailnet-listen", "127.0.0.1:8701", "tailnet の入口（tailscale serve の中継先）のアドレス")
	tailnetHost := flag.String("tailnet-host", "", "tailnet でのこの PC のホスト名（例: agent-box.example.ts.net）。空なら tailnet の入口は待ち受けない")
	flag.Parse()

	errc := make(chan error)
	go func() { errc <- serve(*addr, newHandler(defaultUpstreams)) }()
	if *tailnetHost != "" {
		// Basic 認証のパスワード（ブラウザの端末と同じ）。コマンドラインに出さないよう、環境変数で受け取る
		password := os.Getenv("TERMINAL_PASSWORD")
		if password == "" {
			log.Fatal("-tailnet-host を使うには、環境変数 TERMINAL_PASSWORD が必要です")
		}
		go func() { errc <- serve(*tailnetAddr, newTailnetHandler(defaultUpstreams, *tailnetHost, password)) }()
	}
	log.Fatal(<-errc)
}

func serve(addr string, h http.Handler) error {
	srv := &http.Server{
		Addr:    addr,
		Handler: h,
		// 端末（WebSocket）と LLM の応答（SSE）は長く続くので、読み書き全体の時間は制限しない
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	log.Printf("listening on %s", addr)
	return srv.ListenAndServe()
}
