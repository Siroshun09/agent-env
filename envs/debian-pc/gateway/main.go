// agent-env-gateway は、Mac のブラウザから PC 内の画面を開くための入口。
//
// Mac からの SSH の転送を 1 本（127.0.0.1:8700）にまとめ、ホスト名で PC 内のサービスに振り分ける。
// 外部のライブラリは使わない（標準ライブラリだけ）。
package main

import (
	"flag"
	"log"
	"net/http"
	"net/url"
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
	addr := flag.String("listen", "127.0.0.1:8700", "待ち受けるアドレス")
	flag.Parse()

	srv := &http.Server{
		Addr:    *addr,
		Handler: newHandler(defaultUpstreams),
		// 端末（WebSocket）と LLM の応答（SSE）は長く続くので、読み書き全体の時間は制限しない
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	log.Printf("listening on %s", *addr)
	log.Fatal(srv.ListenAndServe())
}
