package unlock

// catalogue lists every service the panel probes, in display order. Keep the
// groups contiguous and in the order of groupOrder so the page reads top to
// bottom without a second pass.
var catalogue = []probe{
	// Multination: one global catalogue, per-IP geo rules.
	{Service: Service{ID: "netflix", Name: "Netflix", Group: GroupMultination}, run: probeNetflix},
	{Service: Service{ID: "disney", Name: "Disney+", Group: GroupMultination}, run: probeDisney},
	{Service: Service{ID: "youtube", Name: "YouTube Premium", Group: GroupMultination}, run: probeYouTubePremium},
	{Service: Service{ID: "primevideo", Name: "Amazon Prime Video", Group: GroupMultination}, run: probePrimeVideo},
	{Service: Service{ID: "dazn", Name: "DAZN", Group: GroupMultination}, run: probeDAZN},
	{Service: Service{ID: "tvbanywhere", Name: "TVBAnywhere+", Group: GroupMultination}, run: probeTVBAnywhere},
	{Service: Service{ID: "spotify", Name: "Spotify", Group: GroupMultination}, run: probeSpotify},
	{Service: Service{ID: "reddit", Name: "Reddit", Group: GroupMultination}, run: probeReddit},
	{Service: Service{ID: "tiktok", Name: "TikTok", Group: GroupMultination}, run: probeTikTok},

	// AI: the assistants that refuse whole countries.
	{Service: Service{ID: "chatgpt", Name: "ChatGPT", Group: GroupAI}, run: probeChatGPT},
	{Service: Service{ID: "gemini", Name: "Google Gemini", Group: GroupAI}, run: probeGemini},
	{Service: Service{ID: "claude", Name: "Claude", Group: GroupAI}, run: probeClaude},

	// Game: the store reports the currency of the regional wallet.
	{Service: Service{ID: "steam", Name: "Steam", Group: GroupGame}, run: probeSteam},

	// China and Taiwan: the regional catalogues a mainland-facing panel cares
	// about most.
	{Service: Service{ID: "bilibili_cn", Name: "BiliBili China Mainland", Group: GroupChina}, run: probeBilibiliMainland},
	{Service: Service{ID: "bilibili_hkmctw", Name: "BiliBili Hongkong/Macau/Taiwan", Group: GroupChina}, run: probeBilibiliHKMCTW},
	{Service: Service{ID: "bahamut", Name: "Bahamut Anime (巴哈姆特動畫瘋)", Group: GroupTaiwan}, run: probeBahamut},
	{Service: Service{ID: "bilibili_tw", Name: "BiliBili Taiwan", Group: GroupTaiwan}, run: probeBilibiliTaiwan},
}
