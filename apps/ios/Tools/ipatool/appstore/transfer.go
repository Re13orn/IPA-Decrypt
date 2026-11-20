package appstore

import (
	"context"
	"fmt"
	"io"
	"sync"
)

type transferKey struct{}

type transferCounter struct {
	mu              sync.Mutex
	received, total int64
	report          func(received, total int64)
}

// WithTransferProgress reports downloaded bytes without coupling a transfer to
// a terminal progress display. A negative total means the server did not supply one.
func WithTransferProgress(ctx context.Context, report func(received, total int64)) context.Context {
	return context.WithValue(ctx, transferKey{}, report)
}

func beginTransfer(ctx context.Context, received, total int64) context.Context {
	report, ok := ctx.Value(transferKey{}).(func(int64, int64))
	if !ok || report == nil {
		return ctx
	}
	report(received, total)
	return context.WithValue(ctx, transferKey{}, &transferCounter{received: received, total: total, report: report})
}

func countTransfer(ctx context.Context, writer io.Writer) io.Writer {
	if counter, ok := ctx.Value(transferKey{}).(*transferCounter); ok {
		return io.MultiWriter(writer, counter)
	}
	return writer
}

func (counter *transferCounter) Write(data []byte) (int, error) {
	counter.mu.Lock()
	defer counter.mu.Unlock()
	counter.received += int64(len(data))
	counter.report(counter.received, counter.total)
	return len(data), nil
}

// CommerceFailure preserves the Apple code instead of treating unrelated
// download failures as an expired password token.
type CommerceFailure struct{ Code string }

func (e *CommerceFailure) Error() string { return fmt.Sprintf("Store commerce failure %s", e.Code) }
func IPALabCommerceFailure(code string) error {
	switch code {
	case FailureTypeDeviceVerificationFailed, FailureTypeLicenseAlreadyExists:
		return &CommerceFailure{Code: code}
	default:
		return nil
	}
}
