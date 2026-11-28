package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// startUpstream は handler で応答するサーバーを立て、その URL を返す
func startUpstream(t *testing.T, handler http.HandlerFunc) *url.URL {
	t.Helper()
	s := httptest.NewServer(handler)
	t.Cleanup(s.Close)
	u, err := url.Parse(s.URL)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// echo は、受けたリクエストの内容を返し、CORS を許可する上流
func echo(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprintf(w, "%s host=%s path=%s query=%s auth=%s xff=%s",
			name, r.Host, r.URL.Path, r.URL.RawQuery, r.Header.Get("Authorization"), r.Header.Get("X-Forwarded-For"))
	}
}

// startGateway は、すべての振り分け先を up にしたゲートウェイを立てる。up が nil なら、名前を返す echo にする
func startGateway(t *testing.T, up *url.URL) *httptest.Server {
	t.Helper()
	ups := upstreams{term: up, llm: up, metrics: up, logs: up}
	if up == nil {
		ups = upstreams{
			term:    startUpstream(t, echo("term")),
			llm:     startUpstream(t, echo("llm")),
			metrics: startUpstream(t, echo("metrics")),
			logs:    startUpstream(t, echo("logs")),
		}
	}
	gw := httptest.NewServer(newHandler(ups))
	t.Cleanup(gw.Close)
	return gw
}

func get(t *testing.T, gw *httptest.Server, method, host, path string, header map[string]string) (*http.Response, string) {
	t.Helper()
	req, err := http.NewRequest(method, gw.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = host
	for k, v := range header {
		req.Header.Set(k, v)
	}
	res, err := gw.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return res, string(body)
}

func TestRouting(t *testing.T) {
	gw := startGateway(t, nil)
	tests := []struct {
		method, host, path string
		wantCode           int
		wantBody           string
	}{
		{"GET", "agent-box.localhost:8700", "/", 200, "<title>agent-box</title>"},
		{"GET", "AGENT-BOX.LOCALHOST:8700", "/", 200, "<title>agent-box</title>"},
		{"GET", "agent-box.localhost", "/", 200, "<title>agent-box</title>"},
		{"GET", "agent-box.localhost:8700", "/other", 404, ""},
		{"GET", "term.agent-box.localhost:8700", "/ws?x=1", 200, "term host=term.agent-box.localhost:8700 path=/ws query=x=1"},
		{"GET", "llm.agent-box.localhost:8700", "/v1/models", 200, "llm host=llm.agent-box.localhost:8700 path=/v1/models"},
		{"GET", "metrics.agent-box.localhost:8700", "/vmui/", 200, "metrics host=metrics.agent-box.localhost:8700 path=/vmui/"},
		{"GET", "logs.agent-box.localhost:8700", "/select/vmui/", 200, "logs host=logs.agent-box.localhost:8700 path=/select/vmui/"},
		{"GET", "dash.agent-box.localhost:8700", "/", 200, "<title>監視の概要</title>"},
		{"GET", "dash.agent-box.localhost:8700", "/api/v1/query?query=up", 200, "metrics host=dash.agent-box.localhost:8700 path=/api/v1/query query=query=up"},
		{"GET", "dash.agent-box.localhost:8700", "/api/v1/query_range?query=up", 200, "metrics host=dash.agent-box.localhost:8700 path=/api/v1/query_range"},
		// 概要ページからは、問い合わせ（読み取り）以外の API は使えない
		{"POST", "dash.agent-box.localhost:8700", "/api/v1/query", 405, ""},
		{"GET", "dash.agent-box.localhost:8700", "/api/v1/admin/tsdb/delete_series", 404, ""},
		{"GET", "dash.agent-box.localhost:8700", "/api/v1/import", 404, ""},
		// 知らないホスト名（DNS リバインディング）と IP アドレス
		{"GET", "evil.example:8700", "/", 421, ""},
		{"GET", "term.agent-box.localhost.evil.example:8700", "/", 421, ""},
		{"GET", "127.0.0.1:8700", "/", 421, ""},
		{"GET", "", "/", 421, ""},
	}
	for _, tt := range tests {
		t.Run(tt.method+" "+tt.host+tt.path, func(t *testing.T) {
			res, body := get(t, gw, tt.method, tt.host, tt.path, nil)
			if res.StatusCode != tt.wantCode || !strings.Contains(body, tt.wantBody) {
				t.Errorf("got %d %q, want %d containing %q", res.StatusCode, body, tt.wantCode, tt.wantBody)
			}
		})
	}
}

func TestHeaders(t *testing.T) {
	gw := startGateway(t, nil)
	res, body := get(t, gw, "GET", "term.agent-box.localhost:8700", "/", map[string]string{
		"Authorization":   "Basic YWdlbnQ6eA==",
		"X-Forwarded-For": "192.0.2.1",
	})

	// 端末の Basic 認証はそのまま届き、外から来た X-Forwarded-For は届かない
	if !strings.Contains(body, "auth=Basic YWdlbnQ6eA== xff=") || !strings.HasSuffix(body, "xff=") {
		t.Errorf("upstream got %q", body)
	}
	// CORS の許可は消し、埋め込みは禁止する
	want := map[string]string{
		"Access-Control-Allow-Origin": "",
		"X-Frame-Options":             "DENY",
		"Content-Security-Policy":     "frame-ancestors 'none'",
	}
	for k, v := range want {
		if got := res.Header.Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
}

func TestCrossOrigin(t *testing.T) {
	gw := startGateway(t, nil)
	tests := []struct {
		name         string
		method, host string
		header       map[string]string
		wantCode     int
	}{
		{"ブラウザ以外（curl など）", "GET", "metrics.agent-box.localhost:8700", nil, 200},
		{"同じオリジンの fetch", "GET", "metrics.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Origin": "http://metrics.agent-box.localhost:8700"}, 200},
		{"同じオリジンからの送信", "POST", "llm.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Origin": "http://llm.agent-box.localhost:8700"}, 200},
		{"同じオリジンからの送信（ポート番号なし）", "POST", "llm.agent-box.localhost",
			map[string]string{"Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Origin": "http://llm.agent-box.localhost"}, 200},
		{"Origin にだけポート番号がある", "POST", "llm.agent-box.localhost", map[string]string{"Origin": "http://llm.agent-box.localhost:8700"}, 403},
		{"アドレスバーから開く", "GET", "term.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}, 200},
		{"一覧のページからのリンク", "GET", "term.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "same-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}, 200},
		{"別のサイトからのリンク", "GET", "llm.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}, 200},
		{"別のサイトからの fetch", "GET", "metrics.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "cors", "Origin": "https://evil.example"}, 403},
		{"別のサイトからの script 要素", "GET", "metrics.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "script"}, 403},
		{"別のサイトの iframe", "GET", "term.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "iframe"}, 403},
		{"ほかの画面（同じサイト）からの fetch", "GET", "term.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "same-site", "Sec-Fetch-Mode": "cors", "Origin": "http://llm.agent-box.localhost:8700"}, 403},
		{"別のサイトからのフォームの送信", "POST", "llm.agent-box.localhost:8700",
			map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document", "Origin": "https://evil.example"}, 403},
		{"Sec-Fetch-* を送らないブラウザの、別のオリジンからの送信", "POST", "llm.agent-box.localhost:8700",
			map[string]string{"Origin": "https://evil.example"}, 403},
		{"Origin が null", "POST", "llm.agent-box.localhost:8700", map[string]string{"Origin": "null"}, 403},
		{"Origin のポートが違う", "POST", "llm.agent-box.localhost:8700", map[string]string{"Origin": "http://llm.agent-box.localhost:9999"}, 403},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if res, body := get(t, gw, tt.method, tt.host, "/x", tt.header); res.StatusCode != tt.wantCode {
				t.Errorf("got %d %q, want %d", res.StatusCode, body, tt.wantCode)
			}
		})
	}
}

func TestUpstreamDown(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	down := &url.URL{Scheme: "http", Host: l.Addr().String()}
	l.Close()

	gw := startGateway(t, down)
	if res, _ := get(t, gw, "GET", "llm.agent-box.localhost", "/", nil); res.StatusCode != http.StatusBadGateway {
		t.Errorf("got %d, want 502", res.StatusCode)
	}
}

// LLM の応答（SSE）は、上流が書いたそばから届く
func TestStreaming(t *testing.T) {
	release := make(chan struct{})
	up := startUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: first\n\n")
		w.(http.Flusher).Flush()
		<-release
	})
	t.Cleanup(func() { close(release) }) // 上流のサーバーを閉じる前に、ハンドラーを終わらせる
	gw := startGateway(t, up)

	req, err := http.NewRequest("POST", gw.URL+"/v1/chat/completions", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = "llm.agent-box.localhost:8700"
	res, err := gw.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()

	line := make(chan string, 1)
	go func() {
		l, _ := bufio.NewReader(res.Body).ReadString('\n')
		line <- l
	}()
	select {
	case l := <-line:
		if l != "data: first\n" {
			t.Errorf("got %q", l)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the first event was not flushed")
	}
}

// 端末（WebSocket）の接続を中継できる。上流には元の Host と Origin が届く
func TestWebSocket(t *testing.T) {
	up := startUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Upgrade") != "websocket" || r.Host != "term.agent-box.localhost:8700" || r.Header.Get("Origin") != "http://term.agent-box.localhost:8700" {
			http.Error(w, "bad upgrade", http.StatusBadRequest)
			return
		}
		conn, rw, err := http.NewResponseController(w).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
		rw.Flush()
		// 受けた 1 行をそのまま返す
		l, _ := rw.ReadString('\n')
		rw.WriteString("echo:" + l)
		rw.Flush()
	})
	gw := startGateway(t, up)

	// upgrade は、Origin を付けて WebSocket の接続を始め、応答とその後の読み書きに使う接続を返す
	upgrade := func(origin, site string) (*http.Response, *bufio.ReadWriter) {
		t.Helper()
		conn, err := net.Dial("tcp", gw.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		fmt.Fprintf(conn, "GET /ws HTTP/1.1\r\nHost: term.agent-box.localhost:8700\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"+
			"Origin: %s\r\nSec-Fetch-Site: %s\r\nSec-Fetch-Mode: websocket\r\n\r\n", origin, site)
		rw := bufio.NewReadWriter(bufio.NewReader(conn), bufio.NewWriter(conn))
		res, err := http.ReadResponse(rw.Reader, nil)
		if err != nil {
			t.Fatal(err)
		}
		return res, rw
	}

	t.Run("同じオリジン", func(t *testing.T) {
		res, rw := upgrade("http://term.agent-box.localhost:8700", "same-origin")
		if res.StatusCode != http.StatusSwitchingProtocols {
			t.Fatalf("got %d", res.StatusCode)
		}
		rw.WriteString("hello\n")
		rw.Flush()
		if l, _ := rw.ReadString('\n'); l != "echo:hello\n" {
			t.Errorf("got %q", l)
		}
	})
	t.Run("別のサイト", func(t *testing.T) {
		if res, _ := upgrade("https://evil.example", "cross-site"); res.StatusCode != http.StatusForbidden {
			t.Errorf("got %d, want 403", res.StatusCode)
		}
	})
}
