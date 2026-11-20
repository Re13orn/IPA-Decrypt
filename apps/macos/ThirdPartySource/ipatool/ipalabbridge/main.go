package main

/*
#include <stdlib.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

static int ipalab_can_execute_dynamic_code(void) {
	size_t size = (size_t)getpagesize();
	void *page = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (page == MAP_FAILED) return 0;
	int ok = mprotect(page, size, PROT_READ | PROT_EXEC) == 0;
	munmap(page, size);
	return ok;
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/cookiejar"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/majd/ipatool/v2/internal/sap/unicorn"
	"github.com/majd/ipatool/v2/internal/storeauth"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/http"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
)

type machine struct{ address string }

func (m machine) MacAddress() (string, error) { return m.address, nil }
func (machine) HomeDirectory() string         { return "" }
func (machine) ReadPassword(int) ([]byte, error) {
	return nil, errors.New("interactive input is managed by the iOS app")
}

type keychain map[string][]byte

func (k keychain) Get(key string) ([]byte, error) {
	value, ok := k[key]
	if !ok {
		return nil, errors.New("not saved")
	}
	return value, nil
}
func (k keychain) Set(key string, value []byte) error {
	if key == "account" {
		var account appstore.Account
		if err := json.Unmarshal(value, &account); err != nil {
			return err
		}
		account.Password = ""
		safe, err := json.Marshal(account)
		if err != nil {
			return err
		}
		value = safe
	}
	k[key] = value
	return nil
}
func (k keychain) Remove(key string) error { delete(k, key); return nil }

type jar struct{ *cookiejar.Jar }

func (jar) Save() error { return nil }

var (
	cookieJars   = make(map[string]*cookiejar.Jar)
	mutex        sync.Mutex
	pendingLogin *loginChallenge
)

var transferProgress struct {
	sync.Mutex
	received, total int64
}
var transferRunning atomic.Bool

func updateTransfer(received, total int64) {
	transferProgress.Lock()
	transferProgress.received, transferProgress.total = received, total
	transferProgress.Unlock()
}

//export IPAToolTransferProgress
func IPAToolTransferProgress(received, total *C.int64_t) {
	*received, *total = 0, 0
	if transferRunning.Load() {
		transferProgress.Lock()
		*received, *total = C.int64_t(transferProgress.received), C.int64_t(transferProgress.total)
		transferProgress.Unlock()
	}
}

// Exercise the same dynamically looked-up ARM64 engine used for Apple SAP.
// No credentials, Apple requests or persistent state are needed.
func checkRuntime() string {
	if C.ipalab_can_execute_dynamic_code() == 0 {
		return "login/unicorn-executable-memory"
	}
	engine, err := unicorn.New(context.Background())
	if err != nil {
		return "login/unicorn-link"
	}
	defer engine.Close()
	const start = 0x10000
	if engine.MemMap(start, 0x4000) != nil ||
		engine.MemWrite(start, []byte{0x40, 0x05, 0x80, 0xd2}) != nil ||
		engine.Start(start, start+4) != nil {
		return "login/unicorn-execution"
	}
	value, err := engine.RegRead(unicorn.RegX0)
	if err != nil || value != 42 {
		return "login/unicorn-execution"
	}
	return ""
}

type loginChallenge struct {
	email, device string
	backend       appstore.AppStore
	state         keychain
}

type request struct {
	Operation, Device, Email, Password, Code, Query, Path, Bundle, Version string
	ID                                                                     int64
	State                                                                  keychain
}
type response struct {
	State          keychain       `json:"state,omitempty"`
	Apps           []appstore.App `json:"apps,omitempty"`
	Error          bool           `json:"error,omitempty"`
	Reason         string         `json:"reason,omitempty"`
	Diagnostic     string         `json:"diagnostic,omitempty"`
	Versions       []string       `json:"versions,omitempty"`
	Latest         string         `json:"latest,omitempty"`
	DisplayVersion string         `json:"displayVersion,omitempty"`
}

func newBackend(device string, state keychain, reset bool) appstore.AppStore {
	cookies := cookieJars[device]
	if cookies == nil || reset {
		cookies, _ = cookiejar.New(nil)
		cookieJars[device] = cookies
	}
	return appstore.NewAppStore(appstore.Args{Keychain: state, CookieJar: jar{cookies},
		OperatingSystem: operatingsystem.New(), Machine: machine{device}})
}

func call(r request) response {
	state := r.State
	if state == nil {
		state = make(keychain)
	}
	out := response{State: state}
	finish := func(err error) response {
		if err != nil {
			out.Error = true
			out.Reason, out.Diagnostic = classify(r.Operation, err)
		}
		return out
	}
	var backend appstore.AppStore
	switch r.Operation {
	case "runtime-check", "provisioning-check", "login":
		if issue := checkRuntime(); issue != "" {
			return response{Error: true, Reason: "runtime", Diagnostic: issue}
		}
		if r.Operation == "runtime-check" {
			return response{}
		}
		if r.Operation == "provisioning-check" {
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			_, _, err := storeauth.AnisetteHeaders(ctx, storeauth.NewHTTPClient(nil), nil)
			return finish(err)
		}
	}
	switch r.Operation {
	case "login":
		if next := pendingLogin; r.Code != "" && next != nil && next.email == r.Email && next.device == r.Device {
			backend, state = next.backend, next.state
			out.State = state
		} else {
			backend = newBackend(r.Device, state, true)
		}
		pendingLogin = nil
		_, err := backend.Login(appstore.LoginInput{Email: r.Email, Password: r.Password, AuthCode: r.Code})
		if errors.Is(err, appstore.ErrAuthCodeRequired) {
			pendingLogin = &loginChallenge{r.Email, r.Device, backend, state}
		}
		return finish(err)
	case "cancel-login":
		pendingLogin = nil
		return response{}
	case "signout":
		if pendingLogin != nil && pendingLogin.device == r.Device {
			pendingLogin = nil
		}
		delete(cookieJars, r.Device)
		return response{}
	}
	backend = newBackend(r.Device, state, false)
	var account appstore.Account
	if data, ok := state["account"]; ok {
		_ = json.Unmarshal(data, &account)
	}
	if r.Operation == "search" {
		if id, err := strconv.ParseInt(r.Query, 10, 64); err == nil || r.Bundle != "" {
			app, err := backend.Lookup(appstore.LookupInput{Account: account, AppID: id, BundleID: r.Bundle, Platform: appstore.PlatformIPhone})
			if err == nil {
				out.Apps = []appstore.App{app.App}
			}
			if errors.Is(err, appstore.ErrAppNotFound) {
				err = nil
			}
			return finish(err)
		}
		found, err := backend.Search(appstore.SearchInput{Account: account, Term: r.Query, Limit: 25, Platform: appstore.PlatformIPhone})
		out.Apps = found.Results
		return finish(err)
	}
	if account.PasswordToken == "" {
		return finish(appstore.ErrPasswordTokenExpired)
	}
	app := appstore.App{ID: r.ID, BundleID: r.Bundle, Name: r.Query}
	if r.Operation == "versions" || r.Operation == "version-info" {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if r.Operation == "versions" {
			list, err := backend.ListVersions(appstore.ListVersionsInput{Context: ctx, Account: account, App: app,
				Platform: appstore.PlatformIPhone})
			out.Versions, out.Latest = list.ExternalVersionIdentifiers, list.LatestExternalVersionID
			return finish(err)
		}
		info, err := backend.GetVersionMetadata(appstore.GetVersionMetadataInput{Context: ctx, Account: account, App: app,
			VersionID: r.Version, Platform: appstore.PlatformIPhone})
		out.DisplayVersion = info.DisplayVersion
		return finish(err)
	}
	if r.Operation == "acquire" {
		found, err := backend.Lookup(appstore.LookupInput{Account: account, AppID: r.ID, Platform: appstore.PlatformIPhone})
		if err != nil {
			return finish(err)
		}
		return finish(backend.Purchase(appstore.PurchaseInput{Account: account, App: found.App, Platform: appstore.PlatformIPhone}))
	}
	if r.Operation != "download" {
		return finish(errors.New("unknown operation"))
	}
	updateTransfer(0, 0)
	transferRunning.Store(true)
	defer transferRunning.Store(false)
	ctx := appstore.WithTransferProgress(context.Background(), updateTransfer)
	downloaded, err := backend.Download(appstore.DownloadInput{Context: ctx, Account: account,
		App: app, OutputPath: r.Path, ExternalVersionID: r.Version, Platform: appstore.PlatformIPhone})
	if err == nil {
		err = backend.ReplicateSinf(appstore.ReplicateSinfInput{Sinfs: downloaded.Sinfs, PackagePath: downloaded.DestinationPath})
	}
	return finish(err)
}

var safeFailureCode = regexp.MustCompile(`^-?[0-9]{1,8}$`)
var safeHTTPStatus = regexp.MustCompile(`\bHTTP ([1-5][0-9]{2})(?:, ([1-5][0-9]{2}))?(?:, ([1-5][0-9]{2}))?`)

func classify(operation string, err error) (reason, diagnostic string) {
	switch {
	case errors.Is(err, appstore.ErrAuthCodeRequired):
		return "code", operation + "/2fa-required"
	case errors.Is(err, appstore.ErrLicenseRequired):
		return "license", operation + "/license"
	case errors.Is(err, appstore.ErrLicenseAlreadyExists):
		return "license-exists", operation + "/license Apple 5002"
	case errors.Is(err, appstore.ErrPasswordTokenExpired):
		return "expired", operation + "/session"
	}
	var commerce *appstore.CommerceFailure
	if errors.As(err, &commerce) {
		switch commerce.Code {
		case appstore.FailureTypeDeviceVerificationFailed:
			return "device-verification", operation + "/device-verification Apple 1008"
		case appstore.FailureTypeLicenseAlreadyExists:
			return "license-conflict", operation + "/license Apple 5002"
		}
	}
	// Include only allowlisted phase names and numeric wire codes.
	// Never pass the raw error, dialog, headers, cookies or request body to Swift.
	message := strings.ToLower(err.Error())
	stage := "request"
	switch {
	case strings.Contains(message, "anisette assets"):
		stage = "provisioning-assets"
	case strings.Contains(message, "anisette runtime"):
		stage = "provisioning-runtime"
	case strings.Contains(message, "store provisioning") || strings.Contains(message, "amd proof") || strings.Contains(message, "machine action"):
		stage = "provisioning-store"
	case strings.Contains(message, "provision") || strings.Contains(message, "anisette"):
		stage = "provisioning"
	case strings.Contains(message, "unsupported authentication endpoint") || strings.Contains(message, "invalid authentication endpoint"):
		stage = "bag-auth-endpoint"
	case strings.Contains(message, "sap version"):
		stage = "bag-sap-version"
	case strings.Contains(message, "load store runtime"):
		stage = "store-runtime"
	case strings.Contains(message, "prepare store framework"):
		stage = "store-framework"
	case strings.Contains(message, "bag") || strings.Contains(message, "endpoint"):
		stage = "endpoint"
	case strings.Contains(message, "sap") || strings.Contains(message, "signer"):
		stage = "sap"
	case strings.Contains(message, "verification") || strings.Contains(message, "2fa"):
		stage = "verification"
	}
	diagnostic = operation + "/" + stage
	var unexpected *http.UnexpectedResponseError
	if statuses := safeHTTPStatus.FindString(err.Error()); statuses != "" {
		diagnostic += " " + statuses
	} else if errors.As(err, &unexpected) && unexpected.StatusCode >= 100 && unexpected.StatusCode <= 599 {
		diagnostic += " HTTP " + strconv.Itoa(unexpected.StatusCode)
	}
	var result *appstore.Error
	failure := ""
	hasDialog := false
	if errors.As(err, &result) {
		metadata := reflect.Indirect(reflect.ValueOf(result.Metadata))
		if metadata.IsValid() && metadata.Kind() == reflect.Struct {
			data := reflect.Indirect(metadata.FieldByName("Data"))
			if data.IsValid() && data.Kind() == reflect.Struct {
				if value := data.FieldByName("FailureType"); value.IsValid() && value.Kind() == reflect.String &&
					safeFailureCode.MatchString(value.String()) {
					failure = value.String()
					diagnostic += " Apple " + failure
				}
				if dialog := data.FieldByName("Dialog"); dialog.IsValid() {
					hasDialog = !dialog.IsZero()
				}
			}
		}
	}
	if operation != "login" {
		return "request", diagnostic
	}
	switch {
	case failure == "-5000":
		return "credentials", diagnostic
	case strings.Contains(message, "account is disabled"):
		return "disabled", diagnostic
	case hasDialog:
		return "account-action", diagnostic
	case stage == "verification":
		return "verification", diagnostic
	case strings.HasPrefix(stage, "provisioning"):
		return "provisioning", diagnostic
	case stage == "sap", stage == "endpoint", strings.HasPrefix(stage, "bag-"), strings.HasPrefix(stage, "store-"), strings.Contains(diagnostic, " HTTP "):
		return "endpoint", diagnostic
	default:
		var transport *http.TransportError
		if errors.As(err, &transport) || strings.Contains(message, "no such host") || strings.Contains(message, "timeout") {
			return "transport", diagnostic
		}
		return "login", diagnostic
	}
}

//export IPAToolCall
func IPAToolCall(input *C.char) *C.char {
	mutex.Lock()
	defer mutex.Unlock()
	var args request
	if input == nil {
		return C.CString(`{"error":true,"diagnostic":"bridge-input"}`)
	}
	if err := json.Unmarshal([]byte(C.GoString(input)), &args); err != nil {
		return C.CString(`{"error":true,"diagnostic":"bridge-input"}`)
	}
	result, err := json.Marshal(call(args))
	if err != nil {
		return C.CString(`{"error":true,"diagnostic":"bridge-output"}`)
	}
	return C.CString(string(result))
}

//export IPAToolFree
func IPAToolFree(allocated *C.char) { C.free(unsafe.Pointer(allocated)) }

func main() {}
