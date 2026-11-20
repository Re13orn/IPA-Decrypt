package appstore

import (
    "context"
    "io"
    "net/http"
    "net/http/httptest"
    "path/filepath"
    "testing"
    "github.com/majd/ipatool/v2/pkg/util/operatingsystem"
)

func TestIPALabTransferReportsHTTPBytes(t *testing.T) {
    for _, chunked := range []bool{false,true} {
        server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            if chunked { w.(http.Flusher).Flush() } else { w.Header().Set("Content-Length","12") }
            _, _ = io.WriteString(w, "test payload")
        }))
        var received, total int64
        ctx := WithTransferProgress(context.Background(),func(n, max int64){received,total=n,max})
        store := &appstore{httpClient:newDownloadTestClient(),os:operatingsystem.New()}
        err := store.downloadFile(ctx,server.URL,filepath.Join(t.TempDir(),"app.tmp"),nil)
        server.Close()
        if err != nil {t.Fatal(err)}
        if received != 12 || (!chunked && total != 12) || (chunked && total != -1) {
            t.Fatalf("chunked=%v, received=%d, total=%d", chunked, received, total)
        }
    }
}
