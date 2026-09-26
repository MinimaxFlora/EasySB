package unlock

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// netflixTitles are the two films the reference script plays off each other:
// one Netflix original, which stays available almost everywhere, and one
// licensed title, which only plays where Netflix holds the rights. Netflix
// answers an unplayable title with a page that says "Oh no!".
const (
	netflixOriginals = "https://www.netflix.com/title/81280792" // LEGO Ninjago, a Netflix original
	netflixLicensed  = "https://www.netflix.com/title/70143836" // Breaking Bad, licensed per region
)

var (
	// netflixRequestCountry matches the geo block Netflix embeds, which also
	// carries other keys before the id.
	netflixRequestCountry = regexp.MustCompile(`"requestCountry":\{[^}]*"id":"([A-Za-z]{2})"`)
	netflixID             = regexp.MustCompile(`"id":"([A-Za-z]{2,3})"`)
)

// netflixRefused reports whether a title page says the film cannot be played
// here. Netflix either answers 404 for a title it does not offer in the region,
// or serves a 200 page that says "Oh no!"; the reference script keys on the
// same two signals.
func netflixRefused(r reply) bool {
	return r.status == http.StatusNotFound || r.has("Oh no!")
}

func probeNetflix(ctx context.Context, d *Detector, s Service) Result {
	originals, err := d.get(ctx, netflixOriginals, nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "originals title: "+err.Error())
	}
	licensed, err := d.get(ctx, netflixLicensed, nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "licensed title: "+err.Error())
	}
	for _, r := range []reply{originals, licensed} {
		if r.ok() {
			// A 200 page without any Netflix trace is a captive portal or an
			// interstitial, and a missing "Oh no!" in it would otherwise read as
			// a working catalogue.
			if !r.hasFold("netflix") {
				return s.result(StatusFailed, "", ReasonBody, "a title page did not come from Netflix")
			}
			continue
		}
		if r.status == http.StatusNotFound {
			continue
		}
		return s.result(StatusFailed, "", ReasonHTTP, "netflix.com answered "+r.statusText())
	}

	region := netflixRegion(licensed.body)
	if region == "" {
		region = netflixRegion(originals.body)
	}
	if netflixRefused(originals) && netflixRefused(licensed) {
		return s.result(StatusPartial, "", "", "originals only: neither the original nor the licensed title plays here")
	}
	return s.result(StatusUnlocked, region, "", "")
}

// netflixRegion reads the region Netflix serves a title page in. The page
// embeds its geo block as
// "requestCountry":{"supportedLocales":["en"],"id":"US","countryName":"United States"},
// escaped inside a JavaScript string, so the quotes are unescaped first.
// Older pages instead carry "id":"SG" next to "countryName":"Singapore", where
// the id immediately before the country name is the region.
func netflixRegion(body string) string {
	body = strings.ReplaceAll(body, `\"`, `"`)
	if region := firstGroup(netflixRequestCountry, body); region != "" {
		return strings.ToUpper(region)
	}
	i := strings.LastIndex(body, `"countryName"`)
	if i < 0 {
		return ""
	}
	ids := allGroups(netflixID, body[:i])
	if len(ids) == 0 {
		return ""
	}
	return strings.ToUpper(ids[len(ids)-1])
}

// Disney+ answers neither a plain yes nor no: the app registers a device, trades
// the device assertion for a session, and only then reports whether the region
// is served. Every step has to succeed before the probe may say anything good.
const (
	disneyHost = "https://disney.api.edge.bamgrid.com"
	// disneyKey is the public web client key the Disney+ site ships in its
	// JavaScript; it is not a user credential.
	disneyKey = "ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84"
)

var (
	disneyAssertion    = regexp.MustCompile(`"assertion":"([^"]+)"`)
	disneyRefreshToken = regexp.MustCompile(`"refresh_token":"([^"]+)"`)
	disneyCountry      = regexp.MustCompile(`"countryCode":"([^"]+)"`)
	disneySupported    = regexp.MustCompile(`"inSupportedLocation":(true|false)`)
)

// disneyGraphQuery asks for the fields the verdict needs. The reference script
// sends a query that only returns sessionId, so its region read always comes
// back empty; asking for the location explicitly is the difference.
const disneyGraphQuery = `{"query":"mutation refreshToken($input: RefreshTokenInput!) ` +
	`{ refreshToken(refreshToken: $input) { activeSession { ... on Session ` +
	`{ sessionId inSupportedLocation location { countryCode } } } } }",` +
	`"variables":{"input":{"refreshToken":"%s"}}}`

func probeDisney(ctx context.Context, d *Detector, s Service) Result {
	auth := map[string]string{"Authorization": "Bearer " + disneyKey}
	devices, err := d.post(ctx, disneyHost+"/devices", "application/json; charset=UTF-8",
		`{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}`, auth)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "device registration: "+err.Error())
	}
	if devices.has("403 ERROR") {
		return s.result(StatusBlocked, "", "", "Disney+ refuses this IP at device registration")
	}
	assertion := firstGroup(disneyAssertion, devices.body)
	if assertion == "" {
		return s.result(StatusFailed, "", ReasonBody, "device registration returned no assertion")
	}

	form := url.Values{
		"grant_type":         {"urn:ietf:params:oauth:grant-type:token-exchange"},
		"latitude":           {"0"},
		"longitude":          {"0"},
		"platform":           {"browser"},
		"subject_token":      {assertion},
		"subject_token_type": {"urn:bamtech:params:oauth:token-type:device"},
	}
	token, err := d.post(ctx, disneyHost+"/token", "application/x-www-form-urlencoded", form.Encode(), auth)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "token exchange: "+err.Error())
	}
	if token.hasFold("forbidden-location") || token.has("403 ERROR") {
		return s.result(StatusBlocked, "", "", "Disney+ refuses this IP at the token exchange")
	}
	refresh := firstGroup(disneyRefreshToken, token.body)
	if refresh == "" {
		return s.result(StatusFailed, "", ReasonBody, "the token exchange returned no refresh token")
	}

	graph, err := d.post(ctx, disneyHost+"/graph/v1/device/graphql", "application/json",
		strings.Replace(disneyGraphQuery, "%s", refresh, 1), auth)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "session lookup: "+err.Error())
	}
	region := firstGroup(disneyCountry, graph.body)
	switch firstGroup(disneySupported, graph.body) {
	case "true":
		if region == "" {
			return s.result(StatusFailed, "", ReasonRegion, "the session is active but disclosed no region")
		}
		return s.result(StatusUnlocked, region, "", "")
	case "false":
		if region == "" {
			return s.result(StatusFailed, "", ReasonRegion, "the session is inactive but disclosed no region")
		}
		return s.result(StatusBlocked, region, "", "Disney+ is not open in "+region+" yet")
	default:
		return s.result(StatusFailed, "", ReasonBody, "the session lookup returned no support flag")
	}
}

var (
	youTubeRegion = regexp.MustCompile(`"INNERTUBE_CONTEXT_GL":"([^"]+)"`)
)

// probeYouTubePremium reads the Premium landing page. The page identity and the
// region come from the player context near the top of the document; the
// reference script additionally requires the phrase "ad-free", which on the
// real page sits 700 KB in, past the body cap, so the negative markers below
// carry that decision instead.
func probeYouTubePremium(ctx context.Context, d *Detector, s Service) Result {
	r, err := d.get(ctx, "https://www.youtube.com/premium", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "youtube.com answered "+r.statusText())
	}
	if r.has("www.google.cn") {
		return s.result(StatusBlocked, "CN", "", "the request landed on google.cn, so YouTube is not served here")
	}
	if r.hasFold("Premium is not available in your country") {
		return s.result(StatusBlocked, firstGroup(youTubeRegion, r.body), "", "Premium is not sold in this region")
	}
	region := firstGroup(youTubeRegion, r.body)
	if region == "" {
		return s.result(StatusFailed, "", ReasonBody, "the page carried no YouTube player context")
	}
	return s.result(StatusUnlocked, region, "", "")
}

var amazonTerritory = regexp.MustCompile(`"currentTerritory":"([^"]+)"`)

// primeVideoHome is the storefront the reference script reads. It redirects to the
// non-prime homepage, and the geo block travels with the page either way.
const primeVideoHome = "https://www.primevideo.com"

// probePrimeVideo reads the storefront page the reference script reads, following it to
// its geo block instead of stopping at the default cap: the page is served in two shapes,
// a ~500 KB one whose block sits about 170 KB in and a multi-megabyte one whose block sits
// further, and cutting the read at a megabyte turned a served country into "failed".
func probePrimeVideo(ctx context.Context, d *Detector, s Service) Result {
	r, err := d.getDeep(ctx, primeVideoHome, nil, deepBody, "currentTerritory", "isServiceRestricted")
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "primevideo.com answered "+r.statusText())
	}
	blocked := r.has("isServiceRestricted")
	region := firstGroup(amazonTerritory, r.body)
	if !blocked && region == "" {
		if strings.TrimSpace(r.body) == "" {
			return s.result(StatusFailed, "", ReasonBody, "the storefront returned an empty page")
		}
		return s.result(StatusFailed, "", ReasonBody,
			fmt.Sprintf("no geo block in the first %d KB the storefront served", len(r.body)/1024))
	}
	if blocked {
		return s.result(StatusBlocked, region, "", "Amazon Prime Video is not offered here")
	}
	return s.result(StatusUnlocked, region, "", "")
}

var daznCountry = regexp.MustCompile(`"GeolocatedCountry":"([^"]+)"`)

func probeDAZN(ctx context.Context, d *Detector, s Service) Result {
	body := `{"Version":"2","LandingPageKey":"generic","Languages":"en-US","Platform":"web",` +
		`"Manufacturer":"","PromoCode":"","PlatformAttributes":{}}`
	headers := map[string]string{
		"Origin":  "https://www.dazn.com",
		"Referer": "https://www.dazn.com/",
	}
	r, err := d.post(ctx, "https://startup.core.indazn.com/misl/v5/Startup", "application/json", body, headers)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if r.hasFold("Security policy has been breached") {
		return s.result(StatusBlocked, "", "", "DAZN refuses this IP outright")
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "the startup endpoint answered "+r.statusText())
	}
	region := strings.ToUpper(firstGroup(daznCountry, r.body))
	switch firstGroup(regexp.MustCompile(`"isAllowed":(true|false)`), r.body) {
	case "true":
		return s.result(StatusUnlocked, region, "", "")
	case "false":
		return s.result(StatusBlocked, region, "", "DAZN is not allowed in this territory")
	default:
		return s.result(StatusFailed, "", ReasonBody, "the startup response carried no isAllowed flag")
	}
}

var tvbAllowed = regexp.MustCompile(`"allow_in_this_country":(true|false)`)

func probeTVBAnywhere(ctx context.Context, d *Detector, s Service) Result {
	r, err := d.get(ctx, "https://uapisfm.tvbanywhere.com.sg/geoip/check/platform/android", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "the geoip endpoint answered "+r.statusText())
	}
	switch firstGroup(tvbAllowed, r.body) {
	case "true":
		return s.result(StatusUnlocked, "", "", "")
	case "false":
		return s.result(StatusBlocked, "", "", "TVBAnywhere+ is not sold in this country")
	default:
		return s.result(StatusFailed, "", ReasonBody, "the geoip response carried no country flag")
	}
}
