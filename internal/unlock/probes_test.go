package unlock

import (
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

// netflixBody is a title page carrying the markers the probe reads.
func netflixBody(country, refused string) string {
	return `<html><head><title>Netflix</title></head><body>` +
		`<script>window.__data={"requestCountry":{"id":"` + country + `"}}</script>` +
		refused + `</body></html>`
}

func TestProbeNetflix(t *testing.T) {
	const (
		originals = "https://www.netflix.com/title/81280792"
		licensed  = "https://www.netflix.com/title/70143836"
	)
	cases := []struct {
		name   string
		routes []route
		status Status
		region string
	}{
		{
			name: "full catalogue",
			routes: []route{
				{url: originals, status: 200, body: netflixBody("SG", "")},
				{url: licensed, status: 200, body: netflixBody("SG", "")},
			},
			status: StatusUnlocked,
			region: "SG",
		},
		{
			name: "originals only, both pages refuse the title",
			routes: []route{
				{url: originals, status: 200, body: netflixBody("JP", "Oh no!")},
				{url: licensed, status: 200, body: netflixBody("JP", "Oh no!")},
			},
			status: StatusPartial,
		},
		{
			name: "both titles refused, one as a 404",
			routes: []route{
				{url: originals, status: 404, body: "<html>Netflix</html>"},
				{url: licensed, status: 200, body: netflixBody("US", "Oh no!")},
			},
			status: StatusPartial,
		},
		{
			name: "one title plays, the other 404s",
			routes: []route{
				{url: originals, status: 200, body: netflixBody("US", "")},
				{url: licensed, status: 404, body: "<html>Netflix</html>"},
			},
			status: StatusUnlocked,
			region: "US",
		},
		{
			name: "a 200 that did not come from Netflix is not a verdict",
			routes: []route{
				{url: originals, status: 200, body: "<html>captive portal</html>"},
				{url: licensed, status: 200, body: netflixBody("SG", "")},
			},
			status: StatusFailed,
		},
		{
			name: "transport error",
			routes: []route{
				{url: originals, err: errors.New("timeout")},
			},
			status: StatusFailed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "netflix", tc.routes...)
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}
}

func TestProbeChatGPT(t *testing.T) {
	const (
		trace = "https://chat.openai.com/cdn-cgi/trace"
		web   = "https://api.openai.com/compliance/cookie_requirements"
		app   = "https://ios.chat.openai.com/"
	)
	traceBody := "fl=1abc\nip=203.0.113.7\nloc=US\nts=1700000000\n"
	cases := []struct {
		name   string
		routes []route
		status Status
		region string
	}{
		{
			name: "available, neither surface refuses",
			routes: []route{
				{url: trace, status: 200, body: traceBody},
				{url: web, status: 200, body: `{"unsupported_country":false}`},
				{url: app, status: 200, body: "<html>ChatGPT</html>"},
			},
			status: StatusUnlocked,
			region: "US",
		},
		{
			name: "unsupported country on both surfaces",
			routes: []route{
				{url: trace, status: 200, body: traceBody},
				{url: web, status: 403, body: `{"error":{"code":"unsupported_country"}}`},
				{url: app, status: 200, body: "<html>unable to load site - VPN detected</html>"},
			},
			status: StatusBlocked,
			region: "US",
		},
		{
			name: "website refused, app usable",
			routes: []route{
				{url: trace, status: 200, body: traceBody},
				{url: web, status: 403, body: `{"error":{"code":"unsupported_country"}}`},
				{url: app, status: 200, body: "<html>ChatGPT</html>"},
			},
			status: StatusPartial,
			region: "US",
		},
		{
			name: "app refused, website usable",
			routes: []route{
				{url: trace, status: 200, body: traceBody},
				{url: web, status: 200, body: `{"unsupported_country":false}`},
				{url: app, status: 200, body: "<html>VPN detected</html>"},
			},
			status: StatusPartial,
			region: "US",
		},
		{
			name: "app refused as a datacenter IP",
			routes: []route{
				{url: trace, status: 200, body: traceBody},
				{url: web, status: 200, body: `{"cookie_consent_required":false}`},
				{url: app, status: 403, body: `{"cf_details":"Request is not allowed. Please try again later.", "type":"dc"}`},
			},
			status: StatusPartial,
			region: "US",
		},
		{
			name: "trace without a loc is inconclusive",
			routes: []route{
				{url: trace, status: 200, body: "fl=1abc\nip=203.0.113.7\n"},
				{url: "https://chatgpt.com/cdn-cgi/trace", status: 200, body: "fl=1abc\n"},
			},
			status: StatusFailed,
		},
		{
			name: "a 500 from a block surface is not a country verdict",
			routes: []route{
				{url: trace, status: 200, body: traceBody},
				{url: web, status: 500, body: "internal error"},
			},
			status: StatusFailed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "chatgpt", tc.routes...)
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}
}

func TestProbeDisney(t *testing.T) {
	const (
		devices = "https://disney.api.edge.bamgrid.com/devices"
		token   = "https://disney.api.edge.bamgrid.com/token"
		graph   = "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql"
	)
	devicesOK := route{url: devices, status: 200, body: `{"assertion":"eyJhbGciOiJIUzI1NiJ9.body.sig"}`}
	tokenOK := route{url: token, status: 200, body: `{"access_token":"at","refresh_token":"rt-1"}`}
	cases := []struct {
		name   string
		routes []route
		status Status
		region string
	}{
		{
			name: "served region",
			routes: []route{
				devicesOK, tokenOK,
				{url: graph, status: 200, body: `{"data":{"refreshToken":{"activeSession":{"sessionId":"s","inSupportedLocation":true,"location":{"countryCode":"US"}}}}}`},
			},
			status: StatusUnlocked,
			region: "US",
		},
		{
			name: "region not open yet",
			routes: []route{
				devicesOK, tokenOK,
				{url: graph, status: 200, body: `{"data":{"refreshToken":{"activeSession":{"sessionId":"s","inSupportedLocation":false,"location":{"countryCode":"VN"}}}}}`},
			},
			status: StatusBlocked,
			region: "VN",
		},
		{
			name: "IP banned at device registration",
			routes: []route{
				{url: devices, status: 200, body: "<html>403 ERROR</html>"},
			},
			status: StatusBlocked,
		},
		{
			name: "forbidden location at the token exchange",
			routes: []route{
				devicesOK,
				{url: token, status: 400, body: `{"error":"forbidden-location"}`},
			},
			status: StatusBlocked,
		},
		{
			name: "no assertion to continue with",
			routes: []route{
				{url: devices, status: 200, body: `{"errors":[]}`},
			},
			status: StatusFailed,
		},
		{
			name: "no refresh token to continue with",
			routes: []route{
				devicesOK,
				{url: token, status: 200, body: `{"access_token":"at"}`},
			},
			status: StatusFailed,
		},
		{
			name: "session without a support flag",
			routes: []route{
				devicesOK, tokenOK,
				{url: graph, status: 200, body: `{"data":{"refreshToken":{"activeSession":{"countryCode":"US"}}}}`},
			},
			status: StatusFailed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "disney", tc.routes...)
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}
}

func TestProbeYouTubePremium(t *testing.T) {
	const url = "https://www.youtube.com/premium"
	cases := []struct {
		name   string
		body   string
		status Status
		region string
	}{
		{
			name:   "sold here",
			body:   `<html>"INNERTUBE_CONTEXT_GL":"de","INNERTUBE_CONTEXT_HL":"de"</html>`,
			status: StatusUnlocked,
			region: "de",
		},
		{
			name:   "landed on google.cn",
			body:   `<html>go to www.google.cn</html>`,
			status: StatusBlocked,
			region: "CN",
		},
		{
			name:   "premium not sold in this country",
			body:   `<html>Premium is not available in your country</html>`,
			status: StatusBlocked,
		},
		{
			name:   "a 200 page that is not YouTube",
			body:   `<html>Welcome to the hotel wifi</html>`,
			status: StatusFailed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "youtube", route{url: url, status: 200, body: tc.body})
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}
}

func TestProbePrimeVideo(t *testing.T) {
	const url = "https://www.primevideo.com"
	filler := strings.Repeat("<div>storefront</div>", 1)
	cases := []struct {
		name   string
		body   string
		status Status
		region string
	}{
		{name: "offered", body: `<html>"currentTerritory":"GB"</html>`, status: StatusUnlocked, region: "GB"},
		{name: "restricted", body: `<html>"isServiceRestricted":true,"currentTerritory":"CN"</html>`, status: StatusBlocked, region: "CN"},
		{name: "no territory at all", body: `<html>hello</html>`, status: StatusFailed},
		{
			// The variant that produced the failed checks: a page whose geo block sits
			// past the default one megabyte cap.
			name:   "geo block past the default cap",
			body:   filler + strings.Repeat("x", maxBody) + `<html>"currentTerritory":"US"</html>`,
			status: StatusUnlocked,
			region: "US",
		},
		{
			name:   "empty storefront",
			body:   "   ",
			status: StatusFailed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "primevideo", route{url: url, status: 200, body: tc.body})
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}

	t.Run("the failed text names what was read", func(t *testing.T) {
		got := runProbe(t, "primevideo", route{url: url, status: 200, body: filler + strings.Repeat("x", 4096)})
		if got.Status != StatusFailed || !strings.Contains(got.Text, "KB") {
			t.Fatalf("got %q (%s), want a failure that says how much was read", got.Status, got.Text)
		}
	})

	// The storefront answers the same request with different shapes, so the probe asks
	// again before it reports a country as unreadable. These cases pin that: a lean page
	// followed by a full one is a verdict, and three lean pages is a failure that says how
	// many attempts it cost.
	t.Run("a lean page is retried", func(t *testing.T) {
		lean := strings.Repeat("x", 40<<10)
		got := runProbe(t, "primevideo", route{
			url:    url,
			status: 200,
			seq:    []string{lean, `<html>"currentTerritory":"US"</html>`},
		})
		if got.Status != StatusUnlocked || got.Region != "US" {
			t.Fatalf("got %q region %q (%s), want unlocked/US after a retry", got.Status, got.Region, got.Text)
		}
	})

	t.Run("a storefront that only errors is reported as a status failure", func(t *testing.T) {
		got := runProbe(t, "primevideo", route{url: url, status: 503, body: "", seq: nil})
		if got.Status != StatusFailed || !strings.Contains(got.Text, "503") {
			t.Fatalf("got %q (%s), want a failure naming the status", got.Status, got.Text)
		}
	})

	t.Run("three lean pages report the attempts", func(t *testing.T) {
		lean := strings.Repeat("x", 40<<10)
		got := runProbe(t, "primevideo", route{url: url, status: 200, body: lean})
		if got.Status != StatusFailed || !strings.Contains(got.Text, "3 attempts") {
			t.Fatalf("got %q (%s), want a failure naming the attempts", got.Status, got.Text)
		}
	})
}

// TestReadUntil covers the read the Prime Video probe uses: it must stop at the first
// marker, keep a marker that straddles a chunk boundary, and never read past its limit.
func TestReadUntil(t *testing.T) {
	const limit = 1 << 16
	marker := `"currentTerritory":"US"`

	t.Run("stops at the marker", func(t *testing.T) {
		body := strings.Repeat("a", 100) + marker + strings.Repeat("b", 1<<20)
		got, err := readUntil(strings.NewReader(body), limit, []string{marker})
		if err != nil {
			t.Fatalf("readUntil: %v", err)
		}
		if !strings.Contains(got, marker) {
			t.Fatalf("the marker was dropped: %d bytes, tail %q", len(got), tail(got, 40))
		}
		// The granularity is one 32 KB read, so "stopped early" means the megabyte
		// behind the marker was never read.
		if len(got) > 64<<10 {
			t.Fatalf("read %d bytes for a marker 100 bytes in", len(got))
		}
	})

	t.Run("finds a marker split across chunks", func(t *testing.T) {
		body := strings.Repeat("a", 32<<10-5) + marker + strings.Repeat("b", 4096)
		got, err := readUntil(strings.NewReader(body), limit, []string{marker})
		if err != nil {
			t.Fatalf("readUntil: %v", err)
		}
		if !strings.Contains(got, marker) {
			t.Fatalf("a marker on a chunk boundary was missed: %d bytes", len(got))
		}
	})

	t.Run("honours the limit", func(t *testing.T) {
		body := strings.Repeat("a", 4*limit)
		got, err := readUntil(strings.NewReader(body), limit, []string{marker})
		if err != nil {
			t.Fatalf("readUntil: %v", err)
		}
		if int64(len(got)) != limit {
			t.Fatalf("read %d bytes, want the limit %d", len(got), limit)
		}
	})
}

// tail is the last n bytes of s, for failure messages that would otherwise dump a
// megabyte into the test log.
func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}

func TestProbeSteam(t *testing.T) {
	const url = "https://store.steampowered.com/app/761830"
	t.Run("currency meta tag", func(t *testing.T) {
		body := `<meta itemprop="priceCurrency" content="JPY"> <meta itemprop="price" content="1980">`
		got := runProbe(t, "steam", route{url: url, status: 200, body: body})
		if got.Status != StatusUnlocked || got.Region != "JPY" {
			t.Errorf("got %q region %q (%s), want unlocked/JPY", got.Status, got.Region, got.Text)
		}
	})
	t.Run("currency in a JSON blob", func(t *testing.T) {
		got := runProbe(t, "steam", route{url: url, status: 200, body: `<script>"priceCurrency":"USD",</script>`})
		if got.Status != StatusUnlocked || got.Region != "USD" {
			t.Errorf("got %q region %q (%s), want unlocked/USD", got.Status, got.Region, got.Text)
		}
	})
	t.Run("free title, wallet cookie", func(t *testing.T) {
		got := runProbe(t, "steam", route{
			url: url, status: 200, body: "<html>Free To Play</html>",
			header: http.Header{"Set-Cookie": {"steamCountry=DE%7Cabcd; path=/; secure"}},
		})
		if got.Status != StatusUnlocked || got.Region != "DE" {
			t.Errorf("got %q region %q (%s), want unlocked/DE", got.Status, got.Region, got.Text)
		}
	})
	t.Run("no price and no cookie", func(t *testing.T) {
		got := runProbe(t, "steam", route{url: url, status: 200, body: "<html>store</html>"})
		if got.Status != StatusFailed {
			t.Errorf("got %q, want failed", got.Status)
		}
	})
}

func TestProbeSpotify(t *testing.T) {
	const url = "https://spclient.wg.spotify.com/signup/public/v1/account"
	cases := []struct {
		name   string
		route  route
		status Status
		region string
	}{
		{
			name:   "registration open",
			route:  route{url: url, status: 200, body: `{"status":311,"country":"SG","is_country_launched":true}`},
			status: StatusUnlocked,
			region: "SG",
		},
		{
			name:   "already registered",
			route:  route{url: url, status: 200, body: `{"status":320,"country":"JP","is_country_launched":true}`},
			status: StatusBlocked,
			region: "JP",
		},
		{
			name:   "not launched",
			route:  route{url: url, status: 200, body: `{"status":311,"country":"VN","is_country_launched":false}`},
			status: StatusBlocked,
			region: "VN",
		},
		{
			name:   "refused before any country is named",
			route:  route{url: url, status: 200, body: `{"status":320,"errors":{"generic_error":"You seem to be using a proxy service."},"push-notifications":false}`},
			status: StatusBlocked,
		},
		{
			name:   "page error",
			route:  route{url: url, status: 200, body: `{"error":"bad request"}`},
			status: StatusFailed,
		},
		{
			name:   "transport error",
			route:  route{url: url, err: errors.New("no route to host")},
			status: StatusFailed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "spotify", tc.route)
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}
}

func TestProbeReddit(t *testing.T) {
	const url = "https://www.reddit.com/"
	cases := []struct {
		name   string
		route  route
		status Status
	}{
		{name: "reachable", route: route{url: url, status: 200, body: "<html>reddit.com</html>"}, status: StatusUnlocked},
		{name: "403", route: route{url: url, status: 403, body: "<html>blocked</html>"}, status: StatusBlocked},
		{name: "200 from something else", route: route{url: url, status: 200, body: "<html>hello</html>"}, status: StatusFailed},
		{name: "503", route: route{url: url, status: 503, body: "maintenance"}, status: StatusFailed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "reddit", tc.route)
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
		})
	}
}

func TestProbeTikTok(t *testing.T) {
	const url = "https://www.tiktok.com/"
	t.Run("region on the first attempt", func(t *testing.T) {
		got := runProbe(t, "tiktok", route{url: url, status: 200, body: `{"region":"US"}`})
		if got.Status != StatusUnlocked || got.Region != "US" {
			t.Errorf("got %q region %q (%s), want unlocked/US", got.Status, got.Region, got.Text)
		}
	})
	t.Run("region only on the browser-header retry", func(t *testing.T) {
		counting := &countingClient{t: t, answers: []route{
			{url: url, status: 200, body: "<html>feed</html>"},
			{url: url, status: 200, body: `{"region":"SG"}`},
		}}
		d := New(Options{Client: counting})
		got := d.run(t.Context(), selectProbes([]string{"tiktok"})[0])
		if got.Status != StatusPartial || got.Region != "SG" {
			t.Errorf("got %q region %q (%s), want partial/SG", got.Status, got.Region, got.Text)
		}
		if counting.last.Get("Sec-Fetch-Site") != "none" {
			t.Error("the retry did not send the browser headers")
		}
	})
	t.Run("no region at all", func(t *testing.T) {
		got := runProbe(t, "tiktok", route{url: url, status: 200, body: "<html>feed</html>"})
		if got.Status != StatusFailed {
			t.Errorf("got %q (%s), want failed", got.Status, got.Text)
		}
	})
}

func TestProbeDAZN(t *testing.T) {
	const url = "https://startup.core.indazn.com/misl/v5/Startup"
	cases := []struct {
		name   string
		body   string
		status Status
		region string
	}{
		{name: "allowed", body: `{"isAllowed":true,"GeolocatedCountry":"de"}`, status: StatusUnlocked, region: "DE"},
		{name: "not allowed", body: `{"isAllowed":false,"GeolocatedCountry":"cn"}`, status: StatusBlocked, region: "CN"},
		{name: "IP banned", body: `{"message":"Security policy has been breached"}`, status: StatusBlocked},
		{name: "no flag", body: `{}`, status: StatusFailed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "dazn", route{method: http.MethodPost, url: url, status: 200, body: tc.body})
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}
}

func TestProbeTVBAnywhere(t *testing.T) {
	const url = "https://uapisfm.tvbanywhere.com.sg/geoip/check/platform/android"
	cases := []struct {
		name   string
		body   string
		status Status
	}{
		{name: "allowed", body: `{"allow_in_this_country":true}`, status: StatusUnlocked},
		{name: "refused", body: `{"allow_in_this_country":false}`, status: StatusBlocked},
		{name: "no flag", body: `{}`, status: StatusFailed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "tvbanywhere", route{url: url, status: 200, body: tc.body})
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
		})
	}
}

func TestProbeGemini(t *testing.T) {
	const url = "https://gemini.google.com"
	t.Run("offered", func(t *testing.T) {
		body := `<html><script>["gemini",["45631641,null,true"],[,2,1,200,"JPN"]]</script></html>`
		got := runProbe(t, "gemini", route{url: url, status: 200, body: body})
		if got.Status != StatusUnlocked || got.Region != "JPN" {
			t.Errorf("got %q region %q (%s), want unlocked/JPN", got.Status, got.Region, got.Text)
		}
	})
	t.Run("withheld", func(t *testing.T) {
		got := runProbe(t, "gemini", route{url: url, status: 200, body: `<html>gemini</html>`})
		if got.Status != StatusBlocked {
			t.Errorf("got %q (%s), want blocked", got.Status, got.Text)
		}
	})
	t.Run("not gemini", func(t *testing.T) {
		got := runProbe(t, "gemini", route{url: url, status: 200, body: `<html>hotel wifi</html>`})
		if got.Status != StatusFailed {
			t.Errorf("got %q (%s), want failed", got.Status, got.Text)
		}
	})
}

// TestProbeClaude drives the app page and the trace endpoint: every verdict carries the
// region the trace reports, including the inconclusive one a Cloudflare challenge
// produces, because a challenge says nothing about the country.
//
// The trace route comes first in every case: the fake client answers on the first prefix
// match, and "https://claude.ai/" is a prefix of the trace path.
func TestProbeClaude(t *testing.T) {
	const (
		home          = "https://claude.ai/"
		trace         = "https://claude.ai/cdn-cgi/trace"
		anthropicPath = "https://www.anthropic.com/cdn-cgi/trace"
	)
	withTrace := func(homeRoute route, traceRoute route) []route {
		return []route{traceRoute, homeRoute}
	}
	traceUS := route{url: trace, status: 200, body: "fl=1\nip=203.0.113.7\nloc=US\n"}
	cases := []struct {
		name   string
		routes []route
		status Status
		region string
	}{
		{
			name:   "available",
			routes: withTrace(route{url: home, status: 200, body: "<html><title>Claude</title></html>"}, traceUS),
			status: StatusUnlocked,
			region: "US",
		},
		{
			name:   "region unavailable",
			routes: withTrace(route{url: home, status: 200, body: "<html>Anthropic</html>", final: "https://www.anthropic.com/app-unavailable-in-region"}, traceUS),
			status: StatusBlocked,
			region: "US",
		},
		{
			name:   "no app page",
			routes: withTrace(route{url: home, status: 200, body: "<html>hello</html>"}, traceUS),
			status: StatusFailed,
			region: "US",
		},
		{
			name:   "503",
			routes: withTrace(route{url: home, status: 503, body: "unavailable"}, traceUS),
			status: StatusFailed,
			region: "US",
		},
		{
			// What a datacenter address gets, and why the reference script's "yes" is a
			// guess: the country is readable, the app is not.
			name: "cloudflare challenge",
			routes: withTrace(
				route{url: home, status: 403, body: "<html><title>Just a moment...</title><div id=\"challenge-platform\"></div></html>"},
				route{url: trace, status: 200, body: "fl=1\nip=203.0.113.7\nloc=SC\n"}),
			status: StatusFailed,
			region: "SC",
		},
		{
			name: "challenge without a readable trace",
			routes: []route{
				{url: anthropicPath, status: 403, body: ""},
				{url: trace, status: 403, body: ""},
				{url: home, status: 403, body: "<title>Just a moment...</title>"},
			},
			status: StatusFailed,
			region: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "claude", tc.routes...)
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}

	t.Run("a challenge never reads as unlocked", func(t *testing.T) {
		got := runProbe(t, "claude", withTrace(
			route{url: home, status: 403, body: "<title>Just a moment...</title>"},
			route{url: trace, status: 200, body: "loc=US\n"})...)
		if got.OK() {
			t.Fatalf("a Cloudflare challenge reported %q", got.Status)
		}
	})
}

func TestProbeBahamut(t *testing.T) {
	const (
		device = "https://ani.gamer.com.tw/ajax/getdeviceid.php"
		token  = "https://ani.gamer.com.tw/ajax/token.php"
		home   = "https://ani.gamer.com.tw/"
	)
	deviceRoute := func() route {
		return route{
			url: device, status: 200, body: `{"deviceid":"d1"}`,
			header: http.Header{"Set-Cookie": {"BAHAID=xyz; Path=/; HttpOnly"}},
		}
	}
	cases := []struct {
		name   string
		routes []route
		status Status
		region string
	}{
		{
			name: "plays and reports the region",
			routes: []route{
				deviceRoute(),
				{url: token, status: 200, body: `{"animeSn":37783,"token":"t"}`},
				{url: home, status: 200, body: `<html data-geo="TW">`},
			},
			status: StatusUnlocked,
			region: "TW",
		},
		{
			name: "the title is refused",
			routes: []route{
				deviceRoute(),
				{url: token, status: 200, body: `{"error":{"code":103}}`},
			},
			status: StatusBlocked,
		},
		{
			name: "the title plays but no region is disclosed",
			routes: []route{
				deviceRoute(),
				{url: token, status: 200, body: `{"animeSn":37783}`},
				{url: home, status: 200, body: `<html>`},
			},
			status: StatusFailed,
		},
		{
			name: "no device id",
			routes: []route{
				{url: device, status: 200, body: `{}`},
			},
			status: StatusFailed,
		},
		{
			name: "the site refuses this IP",
			routes: []route{
				{url: device, status: 403, body: `<html><title>巴哈姆特電玩資訊站 - 系統異常回報</title></html>`},
			},
			status: StatusBlocked,
		},
		{
			name: "device registration broke",
			routes: []route{
				{url: device, status: 502, body: "bad gateway"},
			},
			status: StatusFailed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := runProbe(t, "bahamut", tc.routes...)
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			if got.Region != tc.region {
				t.Errorf("region = %q, want %q", got.Region, tc.region)
			}
		})
	}

	t.Run("the cookie from registration is carried on", func(t *testing.T) {
		c := &fakeClient{t: t, routes: []route{
			deviceRoute(),
			{url: token, status: 200, body: `{"animeSn":37783}`},
			{url: home, status: 200, body: `<html data-geo="TW">`},
		}}
		d := New(Options{Client: c})
		if got := d.run(t.Context(), selectProbes([]string{"bahamut"})[0]); got.Status != StatusUnlocked {
			t.Fatalf("status = %q (%s), want unlocked", got.Status, got.Text)
		}
		if n := len(c.requests()); n != 3 {
			t.Fatalf("got %d requests, want 3", n)
		}
	})
}

func TestProbeBilibili(t *testing.T) {
	cases := []struct {
		name   string
		id     string
		avid   string
		cid    string
		body   string
		status Status
	}{
		{name: "mainland served", id: "bilibili_cn", avid: "82846771", body: `{"code":0,"result":{}}`, status: StatusUnlocked},
		{name: "mainland outside the region", id: "bilibili_cn", avid: "82846771", body: `{"code":-10403}`, status: StatusBlocked},
		{name: "hkmctw served", id: "bilibili_hkmctw", avid: "18281381", cid: "29892777", body: `{"code":0}`, status: StatusUnlocked},
		{name: "hkmctw outside the region", id: "bilibili_hkmctw", avid: "18281381", cid: "29892777", body: `{"code":-10403}`, status: StatusBlocked},
		{name: "taiwan outside the region", id: "bilibili_tw", avid: "50762638", cid: "100279344", body: `{"code":-10403}`, status: StatusBlocked},
		{name: "unreadable answer", id: "bilibili_tw", avid: "50762638", cid: "100279344", body: `{"code":-400}`, status: StatusFailed},
		{name: "no code at all", id: "bilibili_tw", avid: "50762638", cid: "100279344", body: `{}`, status: StatusFailed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &fakeClient{t: t, routes: []route{{
				url: "https://api.bilibili.com/pgc/player/web/playurl", status: 200, body: tc.body,
			}}}
			d := New(Options{Client: c})
			got := d.run(t.Context(), selectProbes([]string{tc.id})[0])
			if got.Status != tc.status {
				t.Fatalf("status = %q (%s), want %q", got.Status, got.Text, tc.status)
			}
			requested := c.requests()[0]
			if !strings.Contains(requested, "avid="+tc.avid) {
				t.Errorf("the request asked for %q, want avid %s", requested, tc.avid)
			}
			if tc.cid != "" && !strings.Contains(requested, "cid="+tc.cid) {
				t.Errorf("the request asked for %q, want cid %s", requested, tc.cid)
			}
		})
	}
}

// countingClient answers one canned route per request, in order.
type countingClient struct {
	t       *testing.T
	answers []route
	n       int
	last    http.Header
}

func (c *countingClient) Do(req *http.Request) (*http.Response, error) {
	c.last = req.Header
	if c.n >= len(c.answers) {
		c.t.Errorf("unexpected extra request: %s %s", req.Method, req.URL)
		return nil, errors.New("no answer left")
	}
	r := c.answers[c.n]
	c.n++
	return &http.Response{
		StatusCode: r.status,
		Header:     r.header,
		Body:       io.NopCloser(strings.NewReader(r.body)),
		Request:    &http.Request{Method: req.Method, URL: req.URL, Header: req.Header},
	}, nil
}
