package main

import (
	"embed"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

// domain は一覧のページのホスト名。各画面は <名前>.agent-box.localhost で開く。
// *.localhost はブラウザが 127.0.0.1 に解決するので、Mac の DNS の設定は要らない
const domain = "agent-box.localhost"

//go:embed web
var web embed.FS

type upstreams struct {
	term, llm, metrics, logs *url.URL
}

// newHandler は、ホスト名ごとに振り分けるハンドラーを返す。
// ホスト名ごとに別のオリジンになるので、ある画面の不具合（XSS など）が、ほかの画面（端末など）に及ばない
func newHandler(up upstreams) http.Handler {
	metrics := newProxy(up.metrics)

	index := http.NewServeMux()
	index.Handle("GET /{$}", page("web/index.html"))

	// 監視の概要ページ。VictoriaMetrics の問い合わせ（読み取り）だけを同じオリジンで中継する
	dash := http.NewServeMux()
	dash.Handle("GET /{$}", page("web/dashboard.html"))
	dash.Handle("GET /api/v1/query", metrics)
	dash.Handle("GET /api/v1/query_range", metrics)

	return guard(map[string]http.Handler{
		domain:              index,
		"dash." + domain:    dash,
		"term." + domain:    newProxy(up.term),
		"llm." + domain:     newProxy(up.llm),
		"metrics." + domain: metrics,
		"logs." + domain:    newProxy(up.logs),
	})
}

// guard は、次のリクエストを拒否してから、ホスト名に対応するハンドラーに渡す。
//   - 知らないホスト名（DNS リバインディングで、外部のサイトから PC 内の画面を読まれないように）
//   - 別のオリジンのページからのリクエスト（画面の移動は除く）
func guard(hosts map[string]http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h, ok := hosts[hostname(r.Host)]
		if !ok {
			http.Error(w, "unknown host", http.StatusMisdirectedRequest)
			return
		}
		if !allowed(r) {
			http.Error(w, "cross-origin request", http.StatusForbidden)
			return
		}
		// 別のサイトのページに埋め込ませない（クリックジャッキング対策）
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Add("Content-Security-Policy", "frame-ancestors 'none'")
		h.ServeHTTP(w, r)
	})
}

// hostname は Host ヘッダーからポートを除き、小文字にする
func hostname(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return strings.TrimSuffix(strings.ToLower(host), ".")
}

// allowed は、リクエストが同じオリジンのページから来たか、画面の移動なら true を返す。
// ブラウザ以外（curl など）は Sec-Fetch-* も Origin も送らないので通す
func allowed(r *http.Request) bool {
	if isNavigation(r) {
		// 一覧のページから各画面へのリンクなど。表示するだけで何も変えない
		return true
	}
	switch r.Header.Get("Sec-Fetch-Site") {
	case "", "same-origin", "none":
	default: // same-site（ほかの画面）、cross-site
		return false
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	return err == nil && u.Scheme == "http" && strings.EqualFold(u.Host, r.Host)
}

// isNavigation は、ブラウザのタブでページを開くリクエスト（iframe などへの埋め込みは除く）なら true を返す
func isNavigation(r *http.Request) bool {
	return (r.Method == http.MethodGet || r.Method == http.MethodHead) &&
		r.Header.Get("Sec-Fetch-Mode") == "navigate" &&
		r.Header.Get("Sec-Fetch-Dest") == "document"
}

// newProxy は target にそのまま中継するハンドラーを返す。WebSocket と SSE も扱える
func newProxy(target *url.URL) http.Handler {
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			// ttyd は Origin と Host が一致するかで、別のサイトからの接続を拒否するので、Host は変えない
			pr.Out.Host = pr.In.Host
		},
		// LLM の応答（SSE）を逐次届ける
		FlushInterval: -1,
		// VictoriaMetrics などは、どのサイトからでも読めるように CORS を許可している。
		// ゲートウェイ経由では、別のサイトのページから読ませない
		ModifyResponse: func(res *http.Response) error {
			for k := range res.Header {
				if strings.HasPrefix(k, "Access-Control-") {
					res.Header.Del(k)
				}
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("proxy %s%s: %v", r.Host, r.URL.Path, err)
			http.Error(w, "サービスに接続できません（止まっているか、この PC に無いサービスです）", http.StatusBadGateway)
		},
	}
}

// page は埋め込んだページを返すハンドラーを返す
func page(name string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 更新が反映されるよう、毎回確認させる
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFileFS(w, r, web, name)
	})
}
