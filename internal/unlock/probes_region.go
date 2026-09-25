package unlock

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"net/url"
	"regexp"
)

// steamCurrency is the currency of the store the request landed in, which is
// how Steam reports the regional wallet. Steam has no per-IP yes/no. The store
// page carries it as a meta tag, older pages inside a JSON blob.
var (
	steamCurrencyMeta = regexp.MustCompile(`"priceCurrency"[^>]*content="([^"]+)"`)
	steamCurrencyJSON = regexp.MustCompile(`"priceCurrency":"([^"]+)"`)
	steamCookie       = regexp.MustCompile(`^steamCountry=([A-Za-z]{2})`)
)

func probeSteam(ctx context.Context, d *Detector, s Service) Result {
	r, err := d.get(ctx, "https://store.steampowered.com/app/761830", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "the store answered "+r.statusText())
	}
	currency := firstGroup(steamCurrencyMeta, r.body)
	if currency == "" {
		currency = firstGroup(steamCurrencyJSON, r.body)
	}
	if currency == "" {
		// The store also stamps its regional wallet into a cookie; without a
		// price on the page that is the only remaining signal.
		for _, c := range r.header.Values("Set-Cookie") {
			if country := firstGroup(steamCookie, c); country != "" {
				return s.result(StatusUnlocked, country, "", "the store page carried no price; the wallet cookie names "+country)
			}
		}
		return s.result(StatusFailed, "", ReasonBody, "the store page carried no price currency")
	}
	return s.result(StatusUnlocked, currency, "", "")
}

// tiktokRegion is the region TikTok serves the feed in. TikTok reports it in
// the page itself rather than in a header.
var tiktokRegion = regexp.MustCompile(`"region":"([^"]+)"`)

// tiktokHeaders are the browser headers the reference script retries with. The
// retry exists because a bare request is answered without the region when the
// IP looks like a datacenter.
func tiktokHeaders() map[string]string {
	return map[string]string{
		"Accept":                    "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9",
		"Accept-Language":           "en",
		"Upgrade-Insecure-Requests": "1",
		"Sec-Fetch-Dest":            "document",
		"Sec-Fetch-Mode":            "navigate",
		"Sec-Fetch-Site":            "none",
		"Sec-Fetch-User":            "?1",
	}
}

func probeTikTok(ctx context.Context, d *Detector, s Service) Result {
	first, err := d.get(ctx, "https://www.tiktok.com/", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if region := firstGroup(tiktokRegion, first.body); region != "" {
		return s.result(StatusUnlocked, region, "", "")
	}
	if !first.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "tiktok.com answered "+first.statusText())
	}

	// The second attempt carries the full browser header set; TikTok names the
	// region for datacenter IPs only on that one.
	second, err := d.get(ctx, "https://www.tiktok.com/", tiktokHeaders())
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "retry: "+err.Error())
	}
	if region := firstGroup(tiktokRegion, second.body); region != "" {
		return s.result(StatusPartial, region, "", "the region appeared only on the browser-header retry (datacenter IP)")
	}
	return s.result(StatusFailed, "", ReasonRegion, "tiktok.com disclosed no region")
}

// spotifySignup is the account-creation probe the reference script uses. It
// never creates anything: Spotify answers with the country of the caller, and
// with status 320 when the region cannot register.
const spotifySignup = "https://spclient.wg.spotify.com/signup/public/v1/account"

// spotifyForm is the body the reference sends. The identifier is a placeholder
// because send-email=0 means nothing is mailed.
const spotifyForm = "birth_day=11&birth_month=11&birth_year=2000&collect_personal_info=undefined" +
	"&creation_flow=&creation_point=https%3A%2F%2Fwww.spotify.com%2Fhk-en%2F&displayname=EasySB" +
	"&gender=male&iagree=1&key=a1e486e2729f46d6bb368d6b2bcda326&platform=www&referrer=" +
	"&send-email=0&thirdpartyemail=0&identifier_token=AgE6YTvEzkReHNfJpO114514"

var (
	spotifyStatus   = regexp.MustCompile(`"status":(-?\d+)`)
	spotifyCountry  = regexp.MustCompile(`"country":"([^"]+)"`)
	spotifyLaunched = regexp.MustCompile(`"is_country_launched":(true|false)`)
	spotifyError    = regexp.MustCompile(`"generic_error":"([^"]+)"`)
)

// probeSpotify reads the country block out of a signup attempt. Nothing is
// created: with send-email=0 Spotify answers with the country of the caller and
// refuses the registration when the IP is a proxy or the country is not served.
func probeSpotify(ctx context.Context, d *Detector, s Service) Result {
	r, err := d.post(ctx, spotifySignup, "application/x-www-form-urlencoded", spotifyForm,
		map[string]string{"Accept-Language": "en"})
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "the signup endpoint answered "+r.statusText())
	}
	status := firstGroup(spotifyStatus, r.body)
	if status == "" {
		return s.result(StatusFailed, "", ReasonBody, "the signup response carried no status")
	}
	region := firstGroup(spotifyCountry, r.body)
	note := firstGroup(spotifyError, r.body)
	if len(note) > 120 {
		note = note[:120] + "..."
	}
	switch {
	case status == "320" || status == "120":
		// The refused-registration codes. A proxy or datacenter IP is turned
		// away here before the country is ever reported, which is itself the
		// answer.
		if region == "" {
			text := "Spotify refuses registration from this IP (status " + status + ")"
			if note != "" {
				text += ": " + note
			}
			return s.result(StatusBlocked, "", "", text)
		}
		return s.result(StatusBlocked, region, "", "Spotify does not register accounts in "+region)
	case firstGroup(spotifyLaunched, r.body) == "false":
		return s.result(StatusBlocked, region, "", "Spotify is not launched in "+region)
	case status == "311":
		if region == "" {
			return s.result(StatusFailed, "", ReasonRegion, "the signup endpoint allowed the country but named none")
		}
		return s.result(StatusUnlocked, region, "", "")
	default:
		return s.result(StatusFailed, "", ReasonUnknown, "the signup endpoint answered status "+status)
	}
}

func probeReddit(ctx context.Context, d *Detector, s Service) Result {
	r, err := d.get(ctx, "https://www.reddit.com/", nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	switch {
	case r.status == http.StatusForbidden:
		return s.result(StatusBlocked, "", "", "reddit.com answers 403 for this IP")
	case !r.ok():
		return s.result(StatusFailed, "", ReasonHTTP, "reddit.com answered "+r.statusText())
	case !r.hasFold("reddit"):
		// A 200 without any Reddit trace is not evidence that the site works.
		return s.result(StatusFailed, "", ReasonBody, "the 200 response did not come from reddit.com")
	default:
		return s.result(StatusUnlocked, "", "", "")
	}
}

// bahamutDevice is where the player registers a device. The site is
// Taiwan-only and answers anywhere else with its own error page, so a refusal
// here is a verdict rather than a broken probe. The cookie it sets is what the
// two follow-up requests must carry; the Client interface has no jar.
const (
	bahamutDevice = "https://ani.gamer.com.tw/ajax/getdeviceid.php"
	// bahamutTitle is "I Was Reincarnated as the 7th Prince", the free episode
	// the reference script plays.
	bahamutTitle = 37783
)

var (
	bahamutDeviceID = regexp.MustCompile(`"deviceid"\s*:\s*"([^"]+)"`)
	bahamutGeo      = regexp.MustCompile(`data-geo="([^"]+)"`)
)

func probeBahamut(ctx context.Context, d *Detector, s Service) Result {
	dev, err := d.get(ctx, bahamutDevice, nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "device registration: "+err.Error())
	}
	switch {
	case dev.status == http.StatusForbidden || dev.status == http.StatusUnavailableForLegalReasons:
		return s.result(StatusBlocked, "", "", "ani.gamer.com.tw refuses this IP with "+dev.statusText())
	case !dev.ok():
		return s.result(StatusFailed, "", ReasonHTTP, "device registration answered "+dev.statusText())
	}
	device := firstGroup(bahamutDeviceID, dev.body)
	if device == "" {
		return s.result(StatusFailed, "", ReasonBody, "device registration returned no deviceid")
	}
	jar := cookieHeader(dev.header)
	headers := map[string]string{}
	if jar != "" {
		headers["Cookie"] = jar
	}

	token, err := d.get(ctx, "https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn="+
		itoa(bahamutTitle)+"&device="+url.QueryEscape(device), headers)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "token request: "+err.Error())
	}
	if !token.has("animeSn") {
		return s.result(StatusBlocked, "", "", "the token endpoint refuses to play the title here")
	}

	page, err := d.get(ctx, "https://ani.gamer.com.tw/", headers)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, "landing page: "+err.Error())
	}
	region := firstGroup(bahamutGeo, page.body)
	if region == "" {
		return s.result(StatusFailed, "", ReasonRegion, "the title plays, but the page disclosed no region")
	}
	return s.result(StatusUnlocked, region, "", "")
}

// bilibiliTitle is one of the three regional catalogues the reference covers.
// They share a parser and differ only in the episode asked for: code 0 means
// the region is served, -10403 means it is not.
type bilibiliTitle struct {
	avid string
	cid  string
	epID string
}

var bilibiliCode = regexp.MustCompile(`"code":\s*(-?\d+)`)

func probeBilibili(ctx context.Context, d *Detector, s Service, title bilibiliTitle) Result {
	q := url.Values{}
	q.Set("avid", title.avid)
	if title.cid != "" {
		q.Set("cid", title.cid)
	}
	q.Set("qn", "0")
	q.Set("type", "")
	q.Set("otype", "json")
	q.Set("ep_id", title.epID)
	q.Set("fourk", "1")
	q.Set("fnver", "0")
	q.Set("fnval", "16")
	q.Set("session", randomSession())
	q.Set("module", "bangumi")

	r, err := d.get(ctx, "https://api.bilibili.com/pgc/player/web/playurl?"+q.Encode(), nil)
	if err != nil {
		return s.result(StatusFailed, "", ReasonNetwork, err.Error())
	}
	if !r.ok() {
		return s.result(StatusFailed, "", ReasonHTTP, "api.bilibili.com answered "+r.statusText())
	}
	code := firstGroup(bilibiliCode, r.body)
	switch code {
	case "0":
		return s.result(StatusUnlocked, "", "", "")
	case "":
		return s.result(StatusFailed, "", ReasonBody, "the playurl response carried no code")
	case "-10403":
		return s.result(StatusBlocked, "", "", "the region is outside this catalogue")
	default:
		return s.result(StatusFailed, "", ReasonUnknown, "the playurl endpoint answered code "+code)
	}
}

func probeBilibiliMainland(ctx context.Context, d *Detector, s Service) Result {
	return probeBilibili(ctx, d, s, bilibiliTitle{avid: "82846771", epID: "307247"})
}

func probeBilibiliHKMCTW(ctx context.Context, d *Detector, s Service) Result {
	return probeBilibili(ctx, d, s, bilibiliTitle{avid: "18281381", cid: "29892777", epID: "183799"})
}

func probeBilibiliTaiwan(ctx context.Context, d *Detector, s Service) Result {
	return probeBilibili(ctx, d, s, bilibiliTitle{avid: "50762638", cid: "100279344", epID: "268176"})
}

// randomSession returns the 32 hex characters the reference script passes as
// `session`, so each probe looks like a fresh player request.
func randomSession() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "0123456789abcdef0123456789abcdef"
	}
	return hex.EncodeToString(b[:])
}

// itoa renders the small integers the URLs embed.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [12]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
