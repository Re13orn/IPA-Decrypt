package main

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/majd/ipatool/v2/pkg/appstore"
)

func TestLoginDiagnostics(t *testing.T) {
	cases := []struct {
		input              error
		reason, diagnostic string
	}{
		{fmt.Errorf("login: %w", appstore.ErrAuthCodeRequired), "code", "login/2fa-required"},
		{errors.New("authentication request failed (HTTP 404, 204, 404) private-account@example.invalid"), "endpoint", "login/request HTTP 404, 204, 404"},
		{errors.New("get Store authentication bag: unsupported authentication endpoint private@example.invalid"), "endpoint", "login/bag-auth-endpoint"},
		{errors.New("get Store authentication bag: prepare Store framework: load Store runtime private@example.invalid"), "endpoint", "login/store-runtime"},
		{errors.New("get Store authentication bag: unsupported SAP version 199"), "endpoint", "login/bag-sap-version"},
		{errors.New("prepare Apple authentication: anisette exchange failed"), "provisioning", "login/provisioning"},
		{errors.New("apple did not complete verification; try a fresh 2FA code"), "verification", "login/verification"},
		{appstore.NewErrorWithMetadata(errors.New("bad credentials"), struct{ Data struct{ FailureType string } }{struct{ FailureType string }{"-5000"}}), "credentials", "login/request Apple -5000"},
	}
	for _, test := range cases {
		reason, detail := classify("login", test.input)
		if reason != test.reason || detail != test.diagnostic || strings.Contains(detail, "@") {
			t.Fatalf("got %q %q; expected %q %q", reason, detail, test.reason, test.diagnostic)
		}
	}
}
