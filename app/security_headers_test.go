package main

import (
	"net/http"
	"testing"
)

// Guards the Lab 9 fix for the ZAP baseline findings. Removing securityHeaders
// from Routes() makes every subtest here fail.
func TestSecurityHeaders_PresentOnEveryRoute(t *testing.T) {
	want := map[string]string{
		"Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
		"X-Content-Type-Options":  "nosniff",
		"X-Frame-Options":         "DENY",
		"Referrer-Policy":         "no-referrer",
		"Cache-Control":           "no-store",
	}

	// Every route, not just /health -- the middleware has to cover the router.
	routes := []struct {
		method string
		target string
	}{
		{http.MethodGet, "/health"},
		{http.MethodGet, "/metrics"},
		{http.MethodGet, "/notes"},
		{http.MethodGet, "/notes/1"},
		{http.MethodGet, "/does-not-exist"},
	}

	for _, route := range routes {
		t.Run(route.method+" "+route.target, func(t *testing.T) {
			srv := newTestServer(t)
			rec := do(t, srv, route.method, route.target, nil)

			for header, expected := range want {
				if got := rec.Header().Get(header); got != expected {
					t.Errorf("%s: got %q, want %q", header, got, expected)
				}
			}
		})
	}
}
