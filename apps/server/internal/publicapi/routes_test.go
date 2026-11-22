package publicapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"danny.vn/aboutme/apps/server/internal/publicroots"
)

func TestPublicLiveMissingHandlerUsesStreamErrorContract(t *testing.T) {
	t.Parallel()

	routes := &Service{}
	response := httptest.NewRecorder()
	routes.ServeHTTP(response, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/api/v1/live/ada-lovelace", nil))
	if response.Code != http.StatusServiceUnavailable || response.Header().Get("Cache-Control") != "no-store, no-transform" || response.Header().Get("Retry-After") != "5" {
		t.Fatalf("missing live handler response = %d %#v", response.Code, response.Header())
	}
}

func TestPublicRoutesRecognizesOnlyCaddyPublicPaths(t *testing.T) {
	t.Parallel()

	routes := &Service{}
	for _, test := range []struct {
		path string
		want bool
	}{
		{"/api/v1/public/resumes/ada-lovelace", true},
		{"/api/v1/live/ada-lovelace", true},
		{"/api/v1/live/%61da-lovelace", true},
		{"/api/v1/public/resumes/ada-lovelace/photo", true},
		{"/api/v1/public/resumes/ada-lovelace/pdf", true},
		{"/api/v1/public/resumes/ada-lovelace/og.png", true},
		{"/ada-lovelace", true},
		{"/ada-lovelace.md", true},
		{"/sitemap.xml", true},
		{"/robots.txt", true},
		{"/llms.txt", true},
		{"/api/v1/public/resumes/a", false},
		{"/api/v1/public/resumes/ada/extra", false},
		{"/api/v1/public/resumes/ada-lovelace/og.jpg", false},
		{"/ada/child", false},
		{"/%61da", false},
		{"/api/v1/resumes/ada", false},
		{"/app", false},
	} {
		if got := routes.Recognizes(test.path); got != test.want {
			t.Errorf("Recognizes(%q) = %t, want %t", test.path, got, test.want)
		}
	}
}

func TestPublicRoutesRejectEveryGeneratedReservedRoot(t *testing.T) {
	t.Parallel()

	routes := &Service{}
	for _, root := range publicroots.Routes {
		if !publicroots.Reserved(root.Root) {
			continue
		}
		if validPublicSlug(root.Root) {
			t.Errorf("validPublicSlug(%q) = true for generated reserved root", root.Root)
		}
		for _, path := range []string{
			"/" + root.Root + ".md",
			"/api/v1/public/resumes/" + root.Root,
			"/api/v1/public/resumes/" + root.Root + "/photo",
		} {
			if routes.Recognizes(path) {
				t.Errorf("Recognizes(%q) = true for generated reserved root %q", path, root.Root)
			}
		}
	}
}

func TestPublicRouteClassNamesNoSlug(t *testing.T) {
	t.Parallel()

	routes := &Service{}
	for path, want := range map[string]string{
		"/api/v1/public/resumes/ada-lovelace":        "public_json",
		"/api/v1/public/resumes/ada-lovelace/photo":  "public_photo",
		"/api/v1/public/resumes/ada-lovelace/pdf":    "public_pdf",
		"/api/v1/public/resumes/ada-lovelace/og.png": "public_og_png",
		"/api/v1/live/ada-lovelace":                  "public_live",
		"/ada-lovelace":                              "public_resume",
		"/ada-lovelace.md":                           "public_markdown",
		"/ada-lovelace/projects":                     "public_project_list",
		"/ada-lovelace/projects/note-g":              "public_project",
		"/sitemap.xml":                               "public_sitemap",
		"/robots.txt":                                "public_robots",
		"/llms.txt":                                  "public_llms",
		"/app":                                       "",
	} {
		got := routes.RouteClass(path)
		if got != want {
			t.Errorf("RouteClass(%q) = %q, want %q", path, got, want)
		}
		if strings.Contains(got, "ada") || strings.Contains(got, "note-g") {
			t.Errorf("RouteClass(%q) = %q carries a slug", path, got)
		}
	}
}
