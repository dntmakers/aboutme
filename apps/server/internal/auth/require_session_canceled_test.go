package auth_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"danny.vn/aboutme/apps/server/internal/auth"
	"danny.vn/aboutme/apps/server/internal/store"
)

type failingRow struct{ err error }

func (r failingRow) Scan(...any) error { return r.err }

type canceledDB struct{ err error }

func (canceledDB) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}

func (db canceledDB) Query(context.Context, string, ...any) (pgx.Rows, error) { return nil, db.err }

func (db canceledDB) QueryRow(context.Context, string, ...any) pgx.Row { return failingRow(db) }

func TestRequireSession_CanceledRequestAnswers499(t *testing.T) {
	t.Parallel()
	manager := auth.NewSessionManagerForTest(store.New(canceledDB{err: context.Canceled}), time.Now)
	reached := false
	handler := auth.RequireSession(manager)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { reached = true }))

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	request := httptest.NewRequestWithContext(ctx, http.MethodGet, auth.MePath, nil)
	request.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: "token"})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != 499 {
		t.Fatalf("status = %d, want 499", recorder.Code)
	}
	if reached {
		t.Fatal("handler ran after a canceled session read")
	}
}

func TestRequireSession_StoreFailureStillAnswers500(t *testing.T) {
	t.Parallel()
	manager := auth.NewSessionManagerForTest(store.New(canceledDB{err: context.DeadlineExceeded}), time.Now)
	handler := auth.RequireSession(manager)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))

	request := httptest.NewRequestWithContext(context.Background(), http.MethodGet, auth.MePath, nil)
	request.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: "token"})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", recorder.Code)
	}
}

func TestOptionalSession_CanceledRequestAnswers499(t *testing.T) {
	t.Parallel()
	manager := auth.NewSessionManagerForTest(store.New(canceledDB{err: context.Canceled}), time.Now)
	reached := false
	handler := auth.OptionalSession(manager)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { reached = true }))

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	request := httptest.NewRequestWithContext(ctx, http.MethodPost, "/", nil)
	request.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: "token"})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != 499 {
		t.Fatalf("status = %d, want 499", recorder.Code)
	}
	if reached {
		t.Fatal("handler ran after a canceled session read")
	}
}
