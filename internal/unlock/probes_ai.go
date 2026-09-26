package unlock

import (
	"context"
	"regexp"
	"strings"
)

// ChatGPT is judged through the Cloudflare trace endpoint, which names the
// country Cloudflare classifies the connection as. Two block surfaces decide
// the rest: the compliance endpoint refuses unsupported countries, and the iOS
// endpoint refuses the VPN traffic the app will not run on. Either surface
// alone still leaves the other one usable, which is why those verdicts are
// partial.
var traceLoc = regexp.MustCompile(`(?m)^loc=(\S+)\s*$`)

// chatGPTTrace lists the trace endpoints in order. chat.openai.com redirects to
// chatgpt.com for the site, but the edge still answers the trace path.
var chatGPTTrace = []string{
	"https://chat.openai.com/cdn-cgi/trace",
	"https://chatgpt.com/cdn-cgi/trace",
}

// chatGPTRefusal matches the marker the compliance endpoint sets when the
// country is not served. The reference script greps the bare key, which also
// matches a supported country's `"unsupported_country":false`; reading the value
// keeps a working country from being reported as blocked.
var chatGPTRefusal = regexp.MustCompile(`(?i)"code"\s*:\s*"unsupported_country"|"unsupported_country"\s*:\s*true`)

// chatGPTAppRefusal matches the two ways the iOS endpoint turns a request away:
// the VPN notice, and Cloudflare's `"type":"dc"`, which names a datacenter IP.
// Both refuse the app rather than the country.
var chatGPTAppRefusal = regexp.MustCompile(`(?i)VPN|unable to load site|"type"\s*:\s*"dc"`)

func probeChatGPT(ctx context.Context, d *Detector, s Service) Result {
	region, problem := chatGPTRegion(ctx, d)
	if problem != "" {
		return s.result(StatusFailed, "", ReasonNetwork, problem)
	}
	if region == "" {
		return s.result(StatusFailed, "", ReasonRegion, "the Cloudflare trace carried no loc=")
	}

	web, err := d.get(ctx, "https://api.openai.com/compliance/cookie_requirements", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "compliance endpoint: "+err.Error())
	}
	// The refusal is a 403 that names the reason, so read the marker before the
	// status code: anything else that is not a 2xx is a probe failure, not a
	// country verdict.
	webBlocked := chatGPTRefusal.MatchString(web.body)
	if !web.ok() && !webBlocked {
		return s.result(StatusFailed, "", ReasonHTTP, "compliance endpoint answered "+web.statusText())
	}

	app, err := d.get(ctx, "https://ios.chat.openai.com/", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "iOS endpoint: "+err.Error())
	}
	appBlocked := chatGPTAppRefusal.MatchString(app.body)
	if !app.ok() && !appBlocked {
		return s.result(StatusFailed, "", ReasonHTTP, "iOS endpoint answered "+app.statusText())
	}

	switch {
	case webBlocked && appBlocked:
		return s.result(StatusBlocked, region, "", "unsupported_country on the API and a refusal in the app")
	case webBlocked:
		return s.result(StatusPartial, region, "", "the website is refused (unsupported_country); the app is not")
	case appBlocked:
		return s.result(StatusPartial, region, "", "the app is refused (VPN or datacenter IP); the website is not")
	default:
		return s.result(StatusUnlocked, region, "", "")
	}
}

// chatGPTRegion reads the country out of the Cloudflare trace. It returns an
// error message instead of the region when no endpoint could be read, and an
// empty region when an endpoint answered without a loc= line.
func chatGPTRegion(ctx context.Context, d *Detector) (string, string) {
	return traceRegion(ctx, d, chatGPTTrace)
}

// traceRegion asks each trace endpoint in turn and returns the country
// Cloudflare classifies the connection as, plus the last problem when none of
// them answered with a loc=.
func traceRegion(ctx context.Context, d *Detector, endpoints []string) (string, string) {
	var lastErr string
	for _, url := range endpoints {
		r, err := d.get(ctx, url, nil)
		if err != nil {
			lastErr = url + ": " + err.Error()
			continue
		}
		if !r.ok() {
			lastErr = url + " answered " + r.statusText()
			continue
		}
		if region := firstGroup(traceLoc, r.body); region != "" {
			return region, ""
		}
	}
	return "", lastErr
}

// Gemini is read out of the landing page: the country-availability payload it
// carries contains the marker Google sets when the product is offered here.
var geminiRegion = regexp.MustCompile(`,2,1,200,"([A-Z]{3})"`)

func probeGemini(ctx context.Context, d *Detector, s Service) Result {
	r, err := d.get(ctx, "https://gemini.google.com", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "the landing page answered "+r.statusText())
	}
	// Without this the page may be a captive portal or a consent interstitial,
	// and a missing availability marker would then be read as a block.
	if !r.hasFold("gemini") {
		return s.result(StatusFailed, "", ReasonBody, "the landing page does not look like Gemini")
	}
	if !r.has("45631641,null,true") {
		return s.result(StatusBlocked, "", "", "the availability payload does not offer Gemini here")
	}
	return s.result(StatusUnlocked, firstGroup(geminiRegion, r.body), "", "")
}

// claudeChallenge marks the Cloudflare interstitial claude.ai answers a
// datacenter IP with. It is not a region verdict, so the probe reports it as
// unreadable rather than guessing.
var claudeChallenge = regexp.MustCompile(`(?i)Just a moment|challenge-platform|cf_chl`)

// Claude is judged by where claude.ai sends the visitor: an available region stays on
// the domain, an unavailable one is redirected to a marketing page. claudeTraces are the
// trace endpoints the same edge serves — the app page answers a datacenter address with a
// Cloudflare challenge, but the trace path still names the country Cloudflare classifies
// the connection as, so even an inconclusive verdict can carry a region.
var claudeTraces = []string{
	"https://claude.ai/cdn-cgi/trace",
	"https://www.anthropic.com/cdn-cgi/trace",
}

func probeClaude(ctx context.Context, d *Detector, s Service) Result {
	const home = "https://claude.ai/"
	r, err := d.get(ctx, home, nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	// One extra small request, for the region every verdict can then carry.
	region, _ := traceRegion(ctx, d, claudeTraces)
	switch {
	case strings.Contains(r.finalURL, "app-unavailable-in-region"):
		return s.result(StatusBlocked, region, "", "redirected to "+r.finalURL)
	case r.status == 200 && r.hasFold("claude"):
		return s.result(StatusUnlocked, region, "", "")
	case claudeChallenge.MatchString(r.body):
		// A challenge is Cloudflare turning away an address it does not trust, which says
		// nothing about the country: the reference script reads the unchanged URL as
		// "yes", which is exactly the guess this package refuses to make.
		return s.result(StatusFailed, region, ReasonUnknown,
			"claude.ai answered a Cloudflare challenge ("+r.statusText()+"); the app cannot be judged from this IP")
	case !r.ok():
		return s.result(StatusFailed, region, ReasonHTTP, "claude.ai answered "+r.statusText())
	default:
		return s.result(StatusFailed, region, ReasonBody, "claude.ai did not return the app page")
	}
}
