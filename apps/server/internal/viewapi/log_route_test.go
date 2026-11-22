package viewapi

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"danny.vn/aboutme/apps/server/internal/api"
)

func TestViewStartLogsItsRouteNotTheSlug(t *testing.T) {
	t.Parallel()

	var logs bytes.Buffer
	service := &Service{now: func() time.Time { return time.Unix(0, 0) }}
	handler := api.New(slog.New(slog.NewTextHandler(&logs, nil)), nil, api.Options{}, nil, service.RegisterRoutes)

	request := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/api/v1/public/resumes/guessed-slug/views/start", nil)
	handler.ServeHTTP(httptest.NewRecorder(), request)

	got := logs.String()
	if !strings.Contains(got, "route=public_view_start") || strings.Contains(got, "guessed-slug") {
		t.Fatalf("log = %q, want route=public_view_start and no slug", got)
	}
}
