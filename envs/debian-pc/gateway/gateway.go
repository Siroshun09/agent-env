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

// tailnetPorts は、tailnet（Tailscale）から開くときの画面ごとのポート（キーは画面の名前、"" は一覧のページ）。
// tailscale serve で使えるホスト名は 1 台に 1 つなので、ポートで別のオリジンにする。
// system/agent-env-tailnet-serve.sh と web/index.html の data-port も合わせる
var tailnetPorts = map[string]string{
	"":        "443",
	"term":    "8443",
	"dash":    "8444",
	"llm":     "8445",
	"metrics": "8446",
	"logs":    "8447",
}

//go:embed web
var web embed.FS

type upstreams struct {
	term, llm, metrics, logs *url.URL
}

// site は、1 つのオリジンで開く画面
type site struct {
	handler http.Handler
	scheme  string // オリジンのスキーム（ブラウザが送る Origin と比べる）
}

// newHandler は、ホスト名ごとに振り分けるハンドラーを返す。
// ホスト名ごとに別のオリジンになるので、ある画面の不具合（XSS など）が、ほかの画面（端末など）に及ばない。
// tailnetHost が空でなければ、tailscale serve から届く https://<tailnetHost>:<ポート> でも開けるようにする
func newHandler(up upstreams, tailnetHost string) http.Handler {
	metrics := newProxy(up.metrics)

	index := http.NewServeMux()
	index.Handle("GET /{$}", page("web/index.html"))

	// 監視の概要ページ。VictoriaMetrics の問い合わせ（読み取り）だけを同じオリジンで中継する
	dash := http.NewServeMux()
	dash.Handle("GET /{$}", page("web/dashboard.html"))
	dash.Handle("GET /api/v1/query", metrics)
	dash.Handle("GET /api/v1/query_range", metrics)

	screens := map[string]http.Handler{
		"":        index,
		"dash":    dash,
		"term":    newProxy(up.term),
		"llm":     newProxy(up.llm),
		"metrics": metrics,
		"logs":    newProxy(up.logs),
	}
	sites := map[string]site{}
	for name, h := range screens {
		host := domain
		if name != "" {
			host = name + "." + domain
		}
		sites[host] = site{h, "http"}
		if tailnetHost != "" {
			sites[net.JoinHostPort(hostname(tailnetHost), tailnetPorts[name])] = site{h, "https"}
		}
	}
	return guard(sites)
}

// guard は、次のリクエストを拒否してから、ホスト名に対応するハンドラーに渡す。
//   - 知らないホスト名（DNS リバインディングで、外部のサイトから PC 内の画面を読まれないように）
//   - 別のオリジンのページからのリクエスト（画面の移動は除く）
func guard(sites map[string]site) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s, ok := lookup(sites, r.Host)
		if !ok {
			http.Error(w, "unknown host", http.StatusMisdirectedRequest)
			return
		}
		if !allowed(r, s.scheme) {
			http.Error(w, "cross-origin request", http.StatusForbidden)
			return
		}
		// 別のサイトのページに埋め込ませない（クリックジャッキング対策）
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Add("Content-Security-Policy", "frame-ancestors 'none'")
		s.handler.ServeHTTP(w, r)
	})
}

// lookup は Host ヘッダーに対応する画面を返す。*.localhost はポートを問わず（Mac で転送するポートは環境による）、
// tailnet のホスト名はポートで画面を選ぶ（ポートが無ければ HTTPS の 443）
func lookup(sites map[string]site, host string) (site, bool) {
	name := hostname(host)
	if s, ok := sites[name]; ok {
		return s, true
	}
	port := "443"
	if _, p, err := net.SplitHostPort(host); err == nil {
		port = p
	}
	s, ok := sites[net.JoinHostPort(name, port)]
	return s, ok
}

// hostname は Host ヘッダーからポートを除き、小文字にする
func hostname(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return strings.TrimSuffix(strings.ToLower(host), ".")
}

// allowed は、リクエストが同じオリジン（スキームが scheme）のページから来たか、画面の移動なら true を返す。
// ブラウザ以外（curl など）は Sec-Fetch-* も Origin も送らないので通す
func allowed(r *http.Request, scheme string) bool {
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
	return err == nil && u.Scheme == scheme && strings.EqualFold(u.Host, r.Host)
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
