package client;

import Client.ClientData;
import Types.Config;
import Types.Emote;
import Types.GetTimeEvent;
import Types.Permission;
import Types.PlayerType;
import Types.VideoData;
import Types.VideoDataRequest;
import Types.WsEvent;
import client.Drawing;
import haxe.Json;
import haxe.Timer;
import haxe.crypto.Sha256;
import js.Browser.document;
import js.Browser.window;
import js.Browser;
import js.html.ButtonElement;
import js.html.Element;
import js.html.Event;
import js.html.ImageElement;
import js.html.InputElement;
import js.html.KeyboardEvent;
import js.html.MouseEvent;
import js.html.TransitionEvent;
import js.html.URL;
import js.html.VideoElement;
import js.html.WebSocket;

class Main {
	public static var instance(default, null):Main;
	static inline var SETTINGS_VERSION = 7;
	static inline var MAX_CHAT_MESSAGES = 200;

	public final settings:ClientSettings;
	public var isSyncActive = true;
	public var forceSyncNextTick = false;
	public var isVideoEnabled(default, null) = true;
	public final host:String;
	public var globalIp(default, null) = "";
	public var isPlaylistOpen(default, null) = true;
	public var playersCacheSupport(default, null):Array<PlayerType> = [];
	public var showingServerPause(default, null) = false;
	/** How much time passed since lastState.time update **/
	public var timeFromLastState(default, null) = 0.0;
	public final lastState:GetTimeEvent = {
		time: 0,
		rate: 1.0,
		paused: false,
		pausedByServer: false
	};

	var lastStateTimeStamp = 0.0;

	final clients:Array<Client> = [];
	var pageTitle = document.title;
	var config:Null<Config>;
	final filters:Array<{regex:EReg, replace:String}> = [];
	var personal = new Client("Unknown", 0);
	var isConnected = false;
	var gotInitialConnection = false;
	var disabledReconnection = false;
	var disconnectNotification:Null<Timer>;
	var ws:WebSocket;
	final player:Player;
	var onTimeGet:Timer;
	var onBlinkTab:Null<Timer>;
	var gotFirstPageInteraction = false;
	var msgBuf = getEl("#messagebuffer");
	var isPageUnloading = false;
	var isPageVisible = true;

	var currentFfzPage = 1;
	var currentFfzQuery = "";
	var isFfzLoading = false;
	var hasMoreFfzEmotes = true;

	var currentSeventvPage = 1;
	var currentSeventvQuery = "";
	var isSeventvLoading = false;
	var hasMoreSeventvEmotes = true;

	// App emotes search variables
	var currentAppEmotesQuery = "";
	var allAppEmotes:Array<Emote> = [];

	// TTS variables
	var isTtsEnabled = true;
	var ttsVolume = 1.0;
	var speechSynthesis:Dynamic;
	var finnishVoice:Dynamic;

	// Search context for error recovery
	var currentRandomVideoSearch:Array<String> = [];
	var currentRandomVideoIndex = 0;
	var currentRandomVideoQuery = "";
	var currentRandomVideoAttemptCount = 0;
	public var isRandomVideoOperation = false;

	static function main():Void {
		new Main();
	}

	function new() {
		instance = this;
		haxe.Log.trace = Utils.nativeTrace;
		player = new Player(this);
		host = Browser.location.hostname;
		if (host == "") host = "localhost";

		final defaults:ClientSettings = {
			version: SETTINGS_VERSION,
			uuid: null,
			name: "",
			hash: "",
			chatSize: 300,
			synchThreshold: 2,
			isSwapped: false,
			isUserListHidden: true,
			latestLinks: [],
			latestSubs: [],
			hotkeysEnabled: true,
			showHintList: true,
			checkboxes: [],
			checkedCache: [],
			keywordMode: true,
			obscureMode: false,
		}
		Settings.init(defaults, settingsPatcher);
		settings = Settings.read();

		initListeners();
		onTimeGet = new Timer(settings.synchThreshold * 1000);
		onTimeGet.run = requestTime;
		document.onvisibilitychange = () -> {
			if (!document.hidden && onBlinkTab != null) {
				document.title = getPageTitle();
				onBlinkTab.stop();
				onBlinkTab = null;
			}
		}
		Lang.init("langs", () -> {
			Buttons.initTextButtons(this);
			Buttons.initHotkeys(this, player);
			initTts();
			openWebSocket();});
		JsApi.init(this, player);
		Drawing.init(this);

		document.addEventListener("click", onFirstInteraction);
		window.addEventListener("beforeunload", () -> isPageUnloading = true);
		window.addEventListener("blur", () -> isPageVisible = false);
		window.addEventListener("focus", () -> isPageVisible = true);
		document.addEventListener("visibilitychange", () -> {
			isPageVisible = document.visibilityState == VISIBLE;
		});
	}

	function onFirstInteraction():Void {
		if (gotFirstPageInteraction) return;
		if (!player.isVideoLoaded()) return;
		gotFirstPageInteraction = true;
		player.unmute();
		if (!hasLeader() && !showingServerPause && !player.inUserInteraction) player.play();
		document.removeEventListener("click", onFirstInteraction);
	}

	function settingsPatcher(data:Any, version:Int):Any {
		switch (version) {
			case 1:
				final data:ClientSettings = data;
				data.hotkeysEnabled = true;
			case 2:
				final data:ClientSettings = data;
				data.latestSubs = [];
			case 3:
				final data:ClientSettings = data;
				data.showHintList = true;
			case 4:
				final data:ClientSettings = data;
				data.checkboxes = [];
			case 5:
				final data:ClientSettings = data;
				data.checkedCache = [];
				Reflect.deleteField(data, "playerSize");
				Reflect.deleteField(data, "isExtendedPlayer");
				final oldCheck = data.checkboxes.find(item -> item.id == "cache-on-server");
				if (oldCheck != null) {
					data.checkboxes.remove(oldCheck);
					data.checkedCache.push(YoutubeType);
				}
			case SETTINGS_VERSION, _:
				throw 'skipped version $version';
		}
		return data;
	}

	function requestTime():Void {
		if (!isSyncActive) return;
		if (player.isListEmpty()) return;
		send({type: GetTime});
	}

	function openWebSocket():Void {
		var protocol = "ws:";
		if (Browser.location.protocol == "https:") protocol = "wss:";
		final port = Browser.location.port;
		final colonPort = port.length > 0 ? ':$port' : port;
		final path = Browser.location.pathname;
		final query = settings.uuid == null ? "" : '?uuid=${settings.uuid}';
		ws = new WebSocket('$protocol//$host$colonPort$path$query');
		ws.onmessage = onMessage;
		ws.onopen = () -> {
			disconnectNotification?.stop();
			disconnectNotification = null;
			chatMessageConnected();
			gotInitialConnection = true;
			isConnected = true;
		}
		// if initial connection refused, or server/client is offline
		ws.onclose = () -> {
			isConnected = false;
			var notificationDelay = gotInitialConnection ? 5000 : 0;
			if (disabledReconnection) notificationDelay = 0;

			if (disconnectNotification == null) {
				disconnectNotification = Timer.delay(() -> {
					if (isConnected) return;
					chatMessageDisconnected();
					player.pause();
				}, notificationDelay);
			}

			if (disabledReconnection) return;
			final reconnectionDelay = gotInitialConnection ? 1000 : 2000;
			Timer.delay(openWebSocket, reconnectionDelay);
		}
	}

	function initListeners():Void {
		Buttons.init(this);

		final leaderBtn = getEl("#leader_btn");
		leaderBtn.onclick = toggleLeader;
		leaderBtn.oncontextmenu = (e:MouseEvent) -> {
			toggleLeaderAndPause();
			e.preventDefault();
		}

		final voteSkip = getEl("#voteskip");
		voteSkip.onclick = e -> {
			if (Utils.isTouch() && !window.confirm(Lang.get("skipItemConfirm"))) return;
			if (player.isListEmpty()) return;
			final items = player.getItems();
			final pos = player.getItemPos();
			send({
				type: SkipVideo,
				skipVideo: {
					url: items[pos].url
				}
			});
		}

		final toggleDanmakuBtn = getEl("#toggledanmaku");
		toggleDanmakuBtn.onclick = e -> {
			toggleDanmaku();
		}
		// Initialize danmaku container
		danmakuContainer = getEl("#danmaku-container");
		if (isDanmakuEnabled) {
			danmakuContainer.style.display = "block";
			danmakuLanes = [for (i in 0...DANMAKU_LANES) 0];
			toggleDanmakuBtn.classList.toggle("active", true);
		}

		getEl("#queue_next").onclick = e -> addVideoUrl(false);
		getEl("#queue_end").onclick = e -> addVideoUrl(true);
		new InputWithHistory(getEl("#mediaurl"), settings.latestLinks, 10, value -> {
			addVideoUrl(true);
			return false;
		});
		getEl("#mediatitle").onkeydown = (e:KeyboardEvent) -> {
			if (e.keyCode == KeyCode.Return) addVideoUrl(true);
		}
		new InputWithHistory(getEl("#subsurl"), settings.latestSubs, 10, value -> {
			addVideoUrl(true);
			return false;
		});

		getEl("#ce_queue_next").onclick = e -> addIframe(false);
		getEl("#ce_queue_end").onclick = e -> addIframe(true);
		getEl("#customembed-title").onkeydown = (e:KeyboardEvent) -> {
			if (e.keyCode == KeyCode.Return) {
				addIframe(true);
				e.preventDefault();
			}
		}
		getEl("#customembed-content").onkeydown = getEl("#customembed-title").onkeydown;

		// FrankerFaceZ panel initialization
		initFfzPanel();
		init7tvPanel();
		initSmilesPanel();
	}

	function initFfzPanel():Void {
		final ffzBtn = getEl("#ffzbtn");
		final ffzWrap = getEl("#ffz-wrap");
		final smilesBtnWrap = getEl("#smilesbtn");
		final smilesWrap = getEl("#smiles-wrap");
		final seventvBtn = getEl("#seventvbtn");
		final seventvWrap = getEl("#seventv-wrap");

		ffzBtn.onclick = e -> {
			if (!ffzBtn.classList.contains("active")) {
				// Hide smiles panel if it's visible
				if (smilesWrap.style.display != "none") {
					smilesWrap.style.display = "none";
					smilesBtnWrap.classList.remove("active");
				}

				// Hide 7TV panel if it's visible
				if (seventvWrap.style.display != "none") {
					seventvWrap.style.display = "none";
					seventvBtn.classList.remove("active");
				}

				// Show FFZ panel
				ffzWrap.style.display = "";
				ffzBtn.classList.add("active");
				ffzWrap.style.height = "16rem";

				// Focus on the search input
				final searchInput:InputElement = getEl("#ffz-search");
				searchInput.focus();

				// Initial search with empty query to show recent emotes
				searchFFZEmotes("");
			} else {
				ffzWrap.style.height = "0";
				ffzBtn.classList.remove("active");
				ffzWrap.addEventListener("transitionend", e -> {
					if (e.propertyName == "height") ffzWrap.style.display = "none";
				}, {once: true});
			}
		};

		// Search button functionality
		final searchBtn = getEl("#ffz-search-btn");
		searchBtn.onclick = e -> {
			final searchInput:InputElement = getEl("#ffz-search");
			searchFFZEmotes(searchInput.value);
		};

		// Search input on enter key
		final searchInput:InputElement = getEl("#ffz-search");
		searchInput.onkeydown = (e:KeyboardEvent) -> {
			if (e.keyCode == KeyCode.Return) {
				searchFFZEmotes(searchInput.value);
				e.preventDefault();
			}
		};

		// Add scroll event listener for infinite scroll
		final listEl = getEl("#ffz-list");
		var scrollTimeout:Int = 0;
		var isResizing = false;

		// Helper function to check if all emotes are visible and auto-load if needed
		function checkVisibilityAndAutoLoad():Void {
			if (isFfzLoading || !hasMoreFfzEmotes || isResizing) return;

			final scrollHeight = listEl.scrollHeight;
			final clientHeight = listEl.clientHeight;

			// If all content is visible (no scrollbar), load more emotes
			if (scrollHeight <= clientHeight && scrollHeight > 0 && clientHeight > 0) {
				loadMoreFfzEmotes();
			}
		}

		// Add ResizeObserver to detect layout changes
		final resizeObserver = js.Syntax.code("new ResizeObserver({0})", (entries, observer) ->
		{
			isResizing = true;
			if (scrollTimeout != 0) {
				js.Browser.window.clearTimeout(scrollTimeout);
			}
			scrollTimeout = js.Browser.window.setTimeout(() -> {
				isResizing = false;
				scrollTimeout = 0;
				// Check if we need to auto-load after resize
				checkVisibilityAndAutoLoad();
			}, 100);
		});
		js.Syntax.code("{0}.observe({1})", resizeObserver, listEl);

		listEl.onscroll = (e:Event) -> {
			if (isFfzLoading || !hasMoreFfzEmotes || isResizing) return;

			// Add safety checks for layout stability
			final scrollHeight = listEl.scrollHeight;
			final clientHeight = listEl.clientHeight;
			final scrollTop = listEl.scrollTop;

			// Ensure we have valid dimensions
			if (scrollHeight <= 0 || clientHeight <= 0) return;

			// If all content is visible (no scrollbar), auto-load more
			if (scrollHeight <= clientHeight) {
				loadMoreFfzEmotes();
				return;
			}

			// Calculate scroll position with improved logic for normal scrolling
			final scrollPosition = scrollTop + clientHeight;
			final scrollThreshold = scrollHeight * 0.8; // Load more when 80% scrolled
			final minScrollDistance = 50; // Minimum scroll distance to prevent false triggers

			if (scrollPosition >= scrollThreshold && scrollTop >= minScrollDistance) {
				loadMoreFfzEmotes();
			}
		};
	}

	function searchFFZEmotes(query:String):Void {
		// Reset pagination variables on new search
		currentFfzPage = 1;
		currentFfzQuery = query;
		hasMoreFfzEmotes = true;

		// Show loading indicator
		final loadingEl = getEl("#ffz-loading");
		final listEl = getEl("#ffz-list");
		loadingEl.style.display = "block";
		listEl.innerHTML = "";

		// Fetch first page of emotes
		fetchFfzEmotes(query, 1, true);
	}

	function loadMoreFfzEmotes():Void {
		if (isFfzLoading || !hasMoreFfzEmotes) return;

		currentFfzPage++;
		final loadingEl = getEl("#ffz-loading");
		loadingEl.style.display = "block";

		fetchFfzEmotes(currentFfzQuery, currentFfzPage, false);
	}

	function fetchFfzEmotes(query:String, page:Int, clearList:Bool):Void {
		isFfzLoading = true;

		// Build the API URL
		final apiUrl = "https://api.frankerfacez.com/v1/emotes"
			+ (query.length > 0 ? '?q=${StringTools.urlEncode(query)}' : "")
			+ (query.length > 0 ? "&" : "?")
			+ "sensitive=false&sort=created-desc"
			+ '&page=${page}&per_page=20';

		// Fetch data from the API
		final xhr = new js.html.XMLHttpRequest();
		xhr.open("GET", apiUrl, true);
		xhr.onload = () -> {
			final loadingEl = getEl("#ffz-loading");
			final listEl = getEl("#ffz-list");
			loadingEl.style.display = "none";
			isFfzLoading = false;

			if (xhr.status == 200) {
				try {
					final data = haxe.Json.parse(xhr.responseText);

					// Check if there are more pages
					if (data._pages != null) {
						hasMoreFfzEmotes = page < data._pages;
					} else {
						hasMoreFfzEmotes = false;
					}

					// Clear list if this is a new search
					if (clearList) {
						listEl.innerHTML = "";
					}

					if (data.emoticons != null && data.emoticons.length > 0) {
						for (emote in cast(data.emoticons, Array<Dynamic>)) {
							if (emote != null) {
								// Try to get the best emote URL, prioritizing animated versions
								final emoteUrl = getBestEmoteUrl(emote);

								if (emoteUrl != null) {
									// Create emote element
									final imgEl:js.html.ImageElement = cast document.createElement("img");
									imgEl.className = "ffz-emote";
									imgEl.src = emoteUrl;
									imgEl.alt = emote.name;
									imgEl.title = emote.name;

									// Add flag to indicate if emote is animated
									final isAnimated = emote.animated != null
										&& emoteUrl.contains("/animated/");

									// Add click handler to post emote directly to chat
									imgEl.onclick = e -> {
										// Create emote HTML to display in chat
										final emoteHtml = '<img src="${emoteUrl}" alt="${emote.name}" title="${emote.name}" style="height: 128px; width: auto;" />';

										// Send emote to all users in chat
										emoteMessage(emoteHtml);
									};

									listEl.appendChild(imgEl);
								}
							}
						}

						if (listEl.children.length == 0 && clearList) {
							listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">No emotes found</div>';
						}
					} else if (clearList) {
						listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">No emotes found</div>';
					}

					// Add "no more emotes" message when we reach the end
					if (!hasMoreFfzEmotes && listEl.children.length > 0) {
						final endMessage = document.createDivElement();
						endMessage.style.gridColumn = "1/-1";
						endMessage.style.textAlign = "center";
						endMessage.style.color = "var(--midground)";
						endMessage.style.padding = "1rem";
						endMessage.textContent = "No more emotes to load";
						listEl.appendChild(endMessage);
					}

					// Check if we need to auto-load more emotes after this batch
					js.Browser.window.setTimeout(() -> {
						if (listEl.scrollHeight <= listEl.clientHeight && hasMoreFfzEmotes
							&& !isFfzLoading) {
							loadMoreFfzEmotes();
						}
					}, 50);
				} catch (e) {
					if (clearList) {
						listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">Error loading emotes: ${e}</div>';
					}
				}
			} else {
				if (clearList) {
					listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">Error: ${xhr.status}</div>';
				}
			}
		};
		xhr.onerror = () -> {
			final loadingEl = getEl("#ffz-loading");
			final listEl = getEl("#ffz-list");
			loadingEl.style.display = "none";
			isFfzLoading = false;

			if (clearList) {
				listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">Network error</div>';
			}
		};
		xhr.send();
	}

	/**
	 * Gets the best quality URL for an emote, preferring animated versions if available
	 */
	function getBestEmoteUrl(emote:Dynamic):Null<String> {
		// First try to get animated version
		if (emote.animated != null) {
			// Try to get the highest resolution
			final animatedUrl = emote.animated[4] ?? emote.animated[2] ?? emote.animated[1];
			if (animatedUrl != null) {
				return animatedUrl;
			}
		}

		// Fall back to static version if no animated version exists
		if (emote.urls != null) {
			return emote.urls[4] ?? emote.urls[2] ?? emote.urls[1];
		}

		return null;
	}

	function init7tvPanel():Void {
		final seventvBtn = getEl("#seventvbtn");
		final seventvWrap = getEl("#seventv-wrap");
		final smilesBtnWrap = getEl("#smilesbtn");
		final smilesWrap = getEl("#smiles-wrap");
		final ffzBtn = getEl("#ffzbtn");
		final ffzWrap = getEl("#ffz-wrap");

		seventvBtn.onclick = e -> {
			if (!seventvBtn.classList.contains("active")) {
				// Hide smiles panel if it's visible
				if (smilesWrap.style.display != "none") {
					smilesWrap.style.display = "none";
					smilesBtnWrap.classList.remove("active");
				}

				// Hide FFZ panel if it's visible
				if (ffzWrap.style.display != "none") {
					ffzWrap.style.display = "none";
					ffzBtn.classList.remove("active");
				}

				// Show 7TV panel
				seventvWrap.style.display = "";
				seventvBtn.classList.add("active");
				seventvWrap.style.height = "16rem";

				// Focus on the search input
				final searchInput:InputElement = getEl("#seventv-search");
				searchInput.focus();

				// Initial search with empty query to show recent emotes
				search7TVEmotes("");
			} else {
				seventvWrap.style.height = "0";
				seventvBtn.classList.remove("active");
				seventvWrap.addEventListener("transitionend", e -> {
					if (e.propertyName == "height") seventvWrap.style.display = "none";
				}, {once: true});
			}
		};

		// Search button functionality
		final searchBtn = getEl("#seventv-search-btn");
		searchBtn.onclick = e -> {
			final searchInput:InputElement = getEl("#seventv-search");
			search7TVEmotes(searchInput.value);
		};

		// Search input on enter key
		final searchInput:InputElement = getEl("#seventv-search");
		searchInput.onkeydown = (e:KeyboardEvent) -> {
			if (e.keyCode == KeyCode.Return) {
				search7TVEmotes(searchInput.value);
				e.preventDefault();
			}
		};

		// Add scroll event listener for infinite scroll
		final listEl = getEl("#seventv-list");
		var scrollTimeout:Int = 0;
		var isResizing = false;

		// Helper function to check if all emotes are visible and auto-load if needed
		function checkVisibilityAndAutoLoad():Void {
			if (isSeventvLoading || !hasMoreSeventvEmotes || isResizing) return;

			final scrollHeight = listEl.scrollHeight;
			final clientHeight = listEl.clientHeight;

			// If all content is visible (no scrollbar), load more emotes
			if (scrollHeight <= clientHeight && scrollHeight > 0 && clientHeight > 0) {
				loadMore7tvEmotes();
			}
		}

		// Add ResizeObserver to detect layout changes
		final resizeObserver = js.Syntax.code("new ResizeObserver({0})", (entries, observer) ->
		{
			isResizing = true;
			if (scrollTimeout != 0) {
				js.Browser.window.clearTimeout(scrollTimeout);
			}
			scrollTimeout = js.Browser.window.setTimeout(() -> {
				isResizing = false;
				scrollTimeout = 0;
				// Check if we need to auto-load after resize
				checkVisibilityAndAutoLoad();
			}, 100);
		});
		js.Syntax.code("{0}.observe({1})", resizeObserver, listEl);

		listEl.onscroll = (e:Event) -> {
			if (isSeventvLoading || !hasMoreSeventvEmotes || isResizing) return;

			// Add safety checks for layout stability
			final scrollHeight = listEl.scrollHeight;
			final clientHeight = listEl.clientHeight;
			final scrollTop = listEl.scrollTop;

			// Ensure we have valid dimensions
			if (scrollHeight <= 0 || clientHeight <= 0) return;

			// If all content is visible (no scrollbar), auto-load more
			if (scrollHeight <= clientHeight) {
				loadMore7tvEmotes();
				return;
			}

			// Calculate scroll position with improved logic for normal scrolling
			final scrollPosition = scrollTop + clientHeight;
			final scrollThreshold = scrollHeight * 0.8; // Load more when 80% scrolled
			final minScrollDistance = 50; // Minimum scroll distance to prevent false triggers

			if (scrollPosition >= scrollThreshold && scrollTop >= minScrollDistance) {
				loadMore7tvEmotes();
			}
		};
	}

	function initSmilesPanel():Void {
		final smilesBtn = getEl("#smilesbtn");
		final smilesWrap = getEl("#smiles-wrap");
		final ffzBtn = getEl("#ffzbtn");
		final ffzWrap = getEl("#ffz-wrap");
		final seventvBtn = getEl("#seventvbtn");
		final seventvWrap = getEl("#seventv-wrap");

		smilesBtn.onclick = e -> {
			if (!smilesBtn.classList.contains("active")) {
				// Hide FFZ panel if it's visible
				if (ffzWrap.style.display != "none") {
					ffzWrap.style.display = "none";
					ffzBtn.classList.remove("active");
				}

				// Hide 7TV panel if it's visible
				if (seventvWrap.style.display != "none") {
					seventvWrap.style.display = "none";
					seventvBtn.classList.remove("active");
				}

				// Show smiles panel
				smilesWrap.style.display = "";
				smilesBtn.classList.add("active");
				smilesWrap.style.height = "16rem";

				// Focus on the search input
				final searchInput:InputElement = getEl("#smiles-search");
				searchInput.focus();

				// Initialize search on first open
				searchAppEmotes("");
			} else {
				// Hide smiles panel
				smilesWrap.style.display = "none";
				smilesBtn.classList.remove("active");
			}
		};

		// Search input event listeners
		final searchInput:InputElement = getEl("#smiles-search");
		searchInput.onkeyup = (e:KeyboardEvent) -> {
			searchAppEmotes(searchInput.value);
		};

		// Search button event listener
		final searchBtn = getEl("#smiles-search-btn");
		searchBtn.onclick = e -> {
			searchAppEmotes(searchInput.value);
		};
	}

	function search7TVEmotes(query:String):Void {
		// Reset pagination variables on new search
		currentSeventvPage = 1;
		currentSeventvQuery = query;
		hasMoreSeventvEmotes = true;

		// Show loading indicator
		final loadingEl = getEl("#seventv-loading");
		final listEl = getEl("#seventv-list");
		loadingEl.style.display = "block";
		listEl.innerHTML = "";

		// Fetch first page of emotes
		fetch7tvEmotes(query, 1, true);
	}

	function loadMore7tvEmotes():Void {
		if (isSeventvLoading || !hasMoreSeventvEmotes) return;

		currentSeventvPage++;
		final loadingEl = getEl("#seventv-loading");
		loadingEl.style.display = "block";

		fetch7tvEmotes(currentSeventvQuery, currentSeventvPage, false);
	}

	function fetch7tvEmotes(query:String, page:Int, clearList:Bool):Void {
		isSeventvLoading = true;
		// Always use GraphQL API with sorting
		fetch7tvSearchEmotes(query, page, clearList);
	}

	function fetch7tvSearchEmotes(query:String, page:Int, clearList:Bool):Void {
		final apiUrl = "https://7tv.io/v3/gql";

		// GraphQL query for searching emotes
		final graphqlQuery = '{"query":"query SearchEmotes($$query: String!, $$page: Int, $$limit: Int, $$sort: Sort) { emotes(query: $$query, page: $$page, limit: $$limit, sort: $$sort) { count items { id name host { url files { name format } } } } }","variables":{"query":"${query}","page":${page - 1},"limit":20,"sort":{"value":"age","order":"DESCENDING"}}}';

		final xhr = new js.html.XMLHttpRequest();
		xhr.open("POST", apiUrl, true);
		xhr.setRequestHeader("Content-Type", "application/json");
		xhr.onload = () -> {
			final loadingEl = getEl("#seventv-loading");
			final listEl = getEl("#seventv-list");
			loadingEl.style.display = "none";
			isSeventvLoading = false;

			if (xhr.status == 200) {
				try {
					final data = haxe.Json.parse(xhr.responseText);

					// Clear list if this is a new search
					if (clearList) {
						listEl.innerHTML = "";
					}

					// GraphQL response structure
					if (data.data != null && data.data.emotes != null
						&& data.data.emotes.items != null) {
						final emotes = cast(data.data.emotes.items, Array<Dynamic>);

						// Enable pagination if we got exactly 20 emotes
						hasMoreSeventvEmotes = emotes.length == 20;

						for (emote in emotes) {
							if (emote != null) {
								final emoteUrl = getBest7tvEmoteUrl(emote);

								if (emoteUrl != null) {
									final imgEl:js.html.ImageElement = cast document.createElement("img");
									imgEl.className = "seventv-emote";
									imgEl.src = emoteUrl;
									imgEl.alt = emote.name;
									imgEl.title = emote.name;

									imgEl.onclick = e -> {
										final emoteHtml = '<img src="${emoteUrl}" alt="${emote.name}" title="${emote.name}" style="height: 128px; width: auto;" />';
										emoteMessage(emoteHtml);
									};

									listEl.appendChild(imgEl);
								}
							}
						}

						if (emotes.length == 0 && clearList) {
							listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">No emotes found</div>';
						}

						// Add "no more emotes" message when we reach the end
						if (!hasMoreSeventvEmotes && listEl.children.length > 0 && !clearList) {
							final endMessage = document.createDivElement();
							endMessage.style.gridColumn = "1/-1";
							endMessage.style.textAlign = "center";
							endMessage.style.color = "var(--midground)";
							endMessage.style.padding = "1rem";
							endMessage.textContent = "No more emotes to load";
							listEl.appendChild(endMessage);
						}

						// Check if we need to auto-load more emotes after this batch
						js.Browser.window.setTimeout(() -> {
							if (listEl.scrollHeight <= listEl.clientHeight && hasMoreSeventvEmotes
								&& !isSeventvLoading) {
								loadMore7tvEmotes();
							}
						}, 50);
					} else if (clearList) {
						listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">No emotes found</div>';
					}
				} catch (e) {
					if (clearList) {
						listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">Error loading emotes: ${e}</div>';
					}
				}
			} else {
				if (clearList) {
					listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">Error: ${xhr.status}</div>';
				}
			}
		};
		xhr.onerror = () -> {
			final loadingEl = getEl("#seventv-loading");
			final listEl = getEl("#seventv-list");
			loadingEl.style.display = "none";
			isSeventvLoading = false;

			if (clearList) {
				listEl.innerHTML = '<div style="grid-column: 1/-1; text-align: center; color: var(--midground);">Network error</div>';
			}
		};
		xhr.send(graphqlQuery);
	}

	function getBest7tvEmoteUrl(emote:Dynamic):Null<String> {
		// 7TV emotes from GraphQL have host.url and host.files structure
		if (emote.host != null && emote.host.url != null && emote.host.files != null) {
			final baseUrl = emote.host.url;
			final files = emote.host.files;

			// Try to get the highest quality size (4x for crisp downscaling)
			if (files.length > 0) {
				// Look for 4x size first for best quality, then fallback to lower resolutions
				for (file in cast(files, Array<Dynamic>)) {
					if (file.name != null && Std.string(file.name).indexOf("4x") != -1) {
						return "https:" + baseUrl + "/" + file.name;
					}
				}
				// Fallback to 3x if 4x not available
				for (file in cast(files, Array<Dynamic>)) {
					if (file.name != null && Std.string(file.name).indexOf("3x") != -1) {
						return "https:" + baseUrl + "/" + file.name;
					}
				}
				// Fallback to 2x if 3x not available
				for (file in cast(files, Array<Dynamic>)) {
					if (file.name != null && Std.string(file.name).indexOf("2x") != -1) {
						return "https:" + baseUrl + "/" + file.name;
					}
				}
				// Final fallback to first available (1x)
				final firstFile = files[0];
				if (firstFile.name != null) {
					return "https:" + baseUrl + "/" + firstFile.name;
				}
			}
		}
		return null;
	}

	function searchAppEmotes(query:String):Void {
		currentAppEmotesQuery = query;

		// Show loading indicator
		final loadingEl = getEl("#smiles-loading");
		final listEl = getEl("#smiles-list");
		loadingEl.style.display = "block";
		listEl.innerHTML = "";

		// Filter emotes based on search query
		var filteredEmotes = allAppEmotes;
		if (query.length > 0) {
			filteredEmotes = allAppEmotes.filter(emote -> {
				return emote.name.toLowerCase().indexOf(query.toLowerCase()) >= 0;
			});
		}

		// Hide loading indicator
		loadingEl.style.display = "none";

		// Display filtered emotes
		for (emote in filteredEmotes) {
			final isVideoExt = emote.image.endsWith("mp4") || emote.image.endsWith("webm");
			final tag = isVideoExt ? "video" : "img";
			final el = document.createElement(tag);
			el.className = "smile-preview";
			el.dataset.src = emote.image;
			el.title = emote.name;

			// Set the actual src attribute for display
			if (isVideoExt) {
				final videoEl:js.html.VideoElement = cast el;
				videoEl.src = emote.image;
				videoEl.autoplay = true;
				videoEl.loop = true;
				videoEl.muted = true;
			} else {
				final imgEl:js.html.ImageElement = cast el;
				imgEl.src = emote.image;
			}

			listEl.appendChild(el);
		}
	}

	public inline function isUser():Bool {
		return personal.isUser;
	}

	public inline function isLeader():Bool {
		return personal.isLeader;
	}

	public inline function isAdmin():Bool {
		return personal.isAdmin;
	}

	public inline function getName():String {
		return personal.name;
	}

	public inline function getPersonalName():String {
		return personal.name;
	}

	// Animation types for danmaku emotes with their respective class names
	private final danmakuEmoteAnimations:Array<String> = [
		"danmaku-emote-glow",
		"danmaku-emote-shake",
		"danmaku-emote-spin",
		"danmaku-emote-pulse",
		"danmaku-emote-bounce",
		"danmaku-emote-rainbow",
		"danmaku-emote-flip",
		"danmaku-emote-hover",
		"danmaku-emote-heartbeat",
		"danmaku-emote-wobble",
		"danmaku-emote-blur",
		"danmaku-emote-glitch",
		"danmaku-emote-swing",
		"danmaku-emote-trampoline",
		"danmaku-emote-neon",
		"danmaku-emote-fade"
	];

	/**
	 * Gets a random animation class for danmaku emotes
	 */
	private function getRandomEmoteAnimation():String {
		// 20% chance of no animation
		if (Math.random() < 0.2) return "";

		// Select a random animation from the list
		final index = Math.floor(Math.random() * danmakuEmoteAnimations.length);
		return danmakuEmoteAnimations[index];
	}

	// Danmaku (scrolling comments) functionality
	public var isDanmakuEnabled = true; // Changed from false to true to enable by default

	private var danmakuContainer:Element;
	private var danmakuLanes:Array<Int> = [];
	private final DANMAKU_LANES = 12; // Number of lanes for comments
	private final DANMAKU_SPEED = -5; // Base speed in seconds to cross the screen

	public function toggleDanmaku():Bool {
		isDanmakuEnabled = !isDanmakuEnabled;
		danmakuContainer = getEl("#danmaku-container");

		if (isDanmakuEnabled) {
			danmakuContainer.style.display = "block";

			if (danmakuLanes.length == 0) {
				// Initialize lanes
				danmakuLanes = [for (i in 0...DANMAKU_LANES) 0];
			}
		} else {
			danmakuContainer.style.display = "none";
			// Clear existing danmaku messages when disabled
			danmakuContainer.innerHTML = "";
		}

		getEl("#toggledanmaku").classList.toggle("active", isDanmakuEnabled);
		return isDanmakuEnabled;
	}

	public function sendDanmakuComment(text:String, color:String = "#FFFFFF", isHtml:Bool = false):Void {
		if (!isDanmakuEnabled) return;

		// Send danmaku message to all clients via server
		// The server will broadcast it back to all clients including the sender
		send({
			type: DanmakuMessage,
			danmakuMessage: {
				clientName: "", // Server will fill this in
				text: text,
				color: color,
				isHtml: isHtml
			}
		});
	}

	public function hasPermission(permission:Permission):Bool {
		return personal.hasPermission(permission, config.permissions);
	}

	public final urlMask = ~/\${([0-9]+)-([0-9]+)}/g;

	function handleUrlMasks(links:Array<String>):Void {
		for (link in links) {
			if (!urlMask.match(link)) continue;
			final start = Std.parseInt(urlMask.matched(1));
			var end = Std.parseInt(urlMask.matched(2));
			if (Math.abs(start - end) > 100) continue;
			final step = end > start ? -1 : 1;
			final i = links.indexOf(link);
			links.remove(link);
			while (end != start + step) {
				links.insert(i, urlMask.replace(link, '$end'));
				end += step;
			}
		}
	}

	function addVideoUrl(atEnd:Bool):Void {
		final mediaUrl:InputElement = getEl("#mediaurl");
		final subsUrl:InputElement = getEl("#subsurl");
		final checkboxTemp:InputElement = getEl("#addfromurl .add-temp");
		final isTemp = checkboxTemp.checked;
		final checkboxCache:InputElement = getEl("#cache-on-server");
		final doCache = checkboxCache.checked
			&& checkboxCache.parentElement.style.display != "none";
		final url = mediaUrl.value;
		final subs = subsUrl.value;
		if (url.length == 0) return;
		mediaUrl.value = "";
		InputWithHistory.pushIfNotLast(settings.latestLinks, url);
		if (subs.length != 0) {
			InputWithHistory.pushIfNotLast(settings.latestSubs, subs);
		}
		Settings.write(settings);
		final url = ~/, ?(https?)/g.replace(url, "|$1");
		final links = url.split("|");
		handleUrlMasks(links);
		// if videos added as next, we need to load them in reverse order
		if (!atEnd) sortItemsForQueueNext(links);
		addVideoArray(links, atEnd, isTemp, doCache);
	}

	public function getLinkPlayerType(url:String):PlayerType {
		return player.getLinkPlayerType(url);
	}

	public function isSingleVideoUrl(url:String):Bool {
		return player.isSingleVideoUrl(url);
	}

	public function isExternalVideoUrl(url:String):Bool {
		url = url.ltrim();
		if (url.startsWith("/")) return false;
		final host = Browser.location.hostname;
		if (url.contains(host)) return false;
		return true;
	}

	public function sortItemsForQueueNext<T>(items:Array<T>):Void {
		if (items.length == 0) return;
		// except first item when list empty
		var first:Null<T> = null;
		if (player.isListEmpty()) first = items.shift();
		items.reverse();
		if (first != null) items.unshift(first);
	}

	function addVideoArray(links:Array<String>, atEnd:Bool, isTemp:Bool, doCache:Bool):Void {
		if (links.length == 0) return;
		final link = links.shift();
		addVideo(link, atEnd, isTemp, doCache, () ->
			addVideoArray(links, atEnd, isTemp, doCache));
	}

	public function addVideo(url:String, atEnd:Bool, isTemp:Bool, doCache:Bool, ?callback:() -> Void):Void {
		final protocol = Browser.location.protocol;
		if (url.startsWith("/")) {
			final host = Browser.location.hostname;
			final port = Browser.location.port;
			final colonPort = port.length > 0 ? ':$port' : port;
			url = '$protocol//$host$colonPort$url';
		}
		if (!url.startsWith("pt:")) {
			if (!url.startsWith("http")) url = '$protocol//$url';
		}

		final obj:VideoDataRequest = {
			url: url,
			atEnd: atEnd
		};
		player.getVideoData(obj, (data:VideoData) -> {
			if (data.duration == 0) {
				serverMessage(Lang.get("addVideoError"));
				return;
			}
			data.title ??= Lang.get("rawVideo");
			data.url ??= url;
			send({
				type: AddVideo,
				addVideo: {
					item: {
						url: data.url,
						title: data.title,
						author: personal.name,
						duration: data.duration,
						isTemp: isTemp,
						doCache: doCache,
						subs: data.subs,
						voiceOverTrack: data.voiceOverTrack,
						playerType: data.playerType
					},
					atEnd: atEnd,
					isRandomVideo: isRandomVideoOperation
				}
			});
			if (callback != null) callback();
		});
	}

	function addIframe(atEnd:Bool):Void {
		final iframeCode:InputElement = getEl("#customembed-content");
		final iframe = iframeCode.value;
		if (iframe.length == 0) return;
		iframeCode.value = "";
		final mediaTitle:InputElement = getEl("#customembed-title");
		final title = mediaTitle.value;
		mediaTitle.value = "";
		final checkbox:InputElement = getEl("#customembed .add-temp");
		final isTemp = checkbox.checked;
		final obj:VideoDataRequest = {
			url: iframe,
			atEnd: atEnd
		};
		player.getIframeData(obj, (data:VideoData) -> {
			if (data.duration == 0) {
				serverMessage(Lang.get("addVideoError"));
				return;
			}
			if (title.length > 0) data.title = title;
			data.title ??= "Custom Media";
			data.url ??= iframe;
			send({
				type: AddVideo,
				addVideo: {
					item: {
						url: data.url,
						title: data.title,
						author: personal.name,
						duration: data.duration,
						isTemp: isTemp,
						doCache: false,
						playerType: IframeType
					},
					atEnd: atEnd
				}
			});
		});
	}

	static var cachedWordlist:Array<String>;

	function getWordlist():Array<String> {
		if (cachedWordlist == null) {
			final wordlistContent = haxe.Resource.getString("wordlist");
			if (wordlistContent != null) {
				cachedWordlist = wordlistContent.split("\n").map(line ->
					line.trim()).filter(word -> word.length > 0);
			} else {
				// Fallback to a small array if resource loading fails
				cachedWordlist = ["music", "funny", "cute", "amazing", "cool", "awesome"];
			}
		}
		return cachedWordlist;
	}

	function generateRandomSearchQuery():String {
		var query:String;

		if (settings.obscureMode) {
			// Obscure mode: use device/file tags + random numbers
			final deviceTags = ["IMG", "MVI", "MOV", "100", "SAM", "DSC", "SDV"];
			final randomTag = deviceTags[Math.floor(Math.random() * deviceTags.length)];
			final randomNumber = Math.floor(Math.random() * 9999) + 1;
			final paddedNumber = StringTools.lpad(Std.string(randomNumber), "0", 4);
			query = '$randomTag $paddedNumber';
			trace('Generated obscure search query: "$query"');
		} else {
			// Keyword mode: original functionality
			final words = getWordlist();

			// Pick 1-3 random words
			final numWords = Math.floor(Math.random() * 3) + 1;
			final selectedWords = [];
			for (i in 0...numWords) {
				final word = words[Math.floor(Math.random() * words.length)];
				if (selectedWords.indexOf(word) == -1) {
					selectedWords.push(word);
				}
			}
			query = selectedWords.join(" ");
			trace('Generated keyword search query: "$query"');
		}

		// Always add a random "before:" date filter to discover content from different eras
		final currentYear = Date.now().getFullYear();
		// Random date anywhere from 1 to 15 years ago
		final year = currentYear - (Math.floor(Math.random() * 15) + 1);
		final month = Math.floor(Math.random() * 12) + 1;
		final day = Math.floor(Math.random() * 28)
			+ 1; // Use 1-28 to avoid month length issues
		final monthStr = month < 10 ? "0" + month : "" + month;
		final dayStr = day < 10 ? "0" + day : "" + day;
		query += ' before:$year-$monthStr-$dayStr';

		trace('Final search query with date: "$query"');
		return query;
	}

	public function addRandomYoutubeVideo():Void {
		// Enhanced logging for random video button press
		trace('[RANDOM VIDEO] User: "${personal.name}" pressed random video button | Starting search...');
		
		// Mark that we're starting a random video operation
		isRandomVideoOperation = true;

		// Safety timeout to prevent flag getting stuck (10 seconds)
		Browser.window.setTimeout(() -> {
			if (isRandomVideoOperation) {
				trace('Random video operation timeout, clearing flag');
				isRandomVideoOperation = false;
			}
		}, 10000);

		addRandomYoutubeVideoWithRetry(0);
	}

	function addRandomYoutubeVideoWithRetry(attemptCount:Int):Void {
		if (attemptCount >= 3) {
			// After 3 attempts, use fallback popular videos
			addRandomYoutubeVideoFallback();
			return;
		}

		final query = generateRandomSearchQuery();
		final searchTime = Date.fromTime(Date.now().getTime());
		trace('[RANDOM VIDEO] User: "${personal.name}" | Generated query: "$query" | Initiating search...');

		// Use the public method to search for YouTube videos with dedicated API key
		final randomApiKey = getRandomVideoApiKey();
		player.searchYoutubeVideos(query, 20, (videoIds:Array<String>) -> {
			if (videoIds.length == 0) {
				trace('No results found for query: "$query"');
				// Retry with different search terms
				if (attemptCount < 2) {
					addRandomYoutubeVideoWithRetry(attemptCount + 1);
				} else {
					addRandomYoutubeVideoFallback();
				}
				return;
			}

			// Try to find an embeddable video from the search results
			tryEmbeddableVideoFromResults(videoIds, query, attemptCount);
		}, randomApiKey, personal.name, true);
	}

	function tryEmbeddableVideoFromResults(videoIds:Array<String>, query:String, attemptCount:Int):Void {
		// Shuffle the video IDs to get random selection
		final shuffledIds = videoIds.copy();
		for (i in 0...shuffledIds.length) {
			final j = Math.floor(Math.random() * shuffledIds.length);
			final temp = shuffledIds[i];
			shuffledIds[i] = shuffledIds[j];
			shuffledIds[j] = temp;
		}

		// Try videos one by one until we find an embeddable one
		tryNextVideoFromList(shuffledIds, 0, query, attemptCount);
	}

	function tryNextVideoFromList(videoIds:Array<String>, index:Int, query:String, attemptCount:Int):Void {
		if (index >= videoIds.length) {
			// No embeddable videos found in this search, retry with different search terms
			trace('No embeddable videos found in search results for: "$query"');
			if (attemptCount < 2) {
				addRandomYoutubeVideoWithRetry(attemptCount + 1);
			} else {
				addRandomYoutubeVideoFallback();
			}
			return;
		}

		final videoId = videoIds[index];
		final youtubeUrl = "https://www.youtube.com/watch?v=" + videoId;

		trace('Testing embeddability for video #${index + 1}: $videoId');

		// Check embeddability directly via YouTube API before adding to playlist
		checkVideoEmbeddability(videoId, (isEmbeddable:Bool, title:String) -> {
			if (isEmbeddable) {
				// Store search context for potential error recovery
				currentRandomVideoSearch = videoIds;
				currentRandomVideoIndex = index + 1; // Next video to try if this one fails
				currentRandomVideoQuery = query;
				currentRandomVideoAttemptCount = attemptCount;

				// Video is embeddable, add it to the playlist
				trace('Found embeddable video: $videoId ($title)');
				addVideo(youtubeUrl, true, true, false, () -> {
					serverMessage('Added random video from search: "$query"');
					// Note: Flag will be cleared when video successfully plays or fails
				});
			} else {
				// Video is not embeddable, try the next one
				trace('Video $videoId ($title) is not embeddable, trying next...');
				tryNextVideoFromList(videoIds, index + 1, query, attemptCount);
			}
		});
	}

	function checkVideoEmbeddability(videoId:String, callback:(isEmbeddable:Bool, title:String) -> Void):Void {
		final apiKey = getRandomVideoApiKey();
		if (apiKey == null || apiKey == "") {
			trace('No YouTube API key available for random video embeddability check');
			callback(true, "Unknown"); // Default to embeddable if no API key
			return;
		}

		final videosUrl = "https://www.googleapis.com/youtube/v3/videos";
		final params = '?part=snippet,status,contentDetails&fields=items(snippet/title,status/embeddable,status/privacyStatus,contentDetails/regionRestriction,contentDetails/contentRating)&id=$videoId&key=$apiKey';
		final dataUrl = videosUrl + params;

		final http = new haxe.Http(dataUrl);
		http.onData = response -> {
			try {
				final json = haxe.Json.parse(response);

				// Check for YouTube API errors
				if (json.error != null) {
					final errorCode:Int = json.error.code ?? 0;
					final errorMessage:String = json.error.message ?? "Unknown error";

					if (errorCode == 403) {
						trace('Random video API quota exhausted: $errorMessage');
						serverMessage('Random video API quota exhausted. Try again later.', false);
						callback(false, "API Quota Exhausted");
						return;
					} else {
						trace('Random video API error $errorCode: $errorMessage');
						serverMessage('Random video API error. Using fallback.', false);
						callback(true, "API Error"); // Default to embeddable on other API errors
						return;
					}
				}

				final items:Array<Dynamic> = json.items ?? [];

				if (items.length == 0) {
					trace('Video $videoId not found');
					callback(false, "Not Found");
					return;
				}

				final item = items[0];
				final title:String = item.snippet?.title ?? "Unknown";
				final embeddable:Bool = item.status?.embeddable ?? true;
				final privacyStatus:String = item.status?.privacyStatus ?? "public";
				final regionRestriction = item.contentDetails?.regionRestriction;
				final contentRating = item.contentDetails?.contentRating;

				// Comprehensive embeddability check
				final isActuallyEmbeddable = checkComprehensiveEmbeddability(
					videoId, title, embeddable, privacyStatus, regionRestriction, contentRating
				);

				trace('Video $videoId comprehensive embeddability: $isActuallyEmbeddable (title: $title)');
				callback(isActuallyEmbeddable, title);
			} catch (e:Dynamic) {
				trace('Error parsing embeddability response for $videoId: $e');
				callback(true, "Parse Error"); // Default to embeddable on parse error
			}
		};

		http.onError = error -> {
			trace('Error checking embeddability for $videoId: $error');
			callback(true, "API Error"); // Default to embeddable on API error
		};

		http.request();
	}

	function checkComprehensiveEmbeddability(
		videoId:String,
		title:String,
		embeddable:Bool,
		privacyStatus:String,
		regionRestriction:Dynamic,
		contentRating:Dynamic
	):Bool {
		// If strict checks are disabled, only check basic embeddability
		if (!config.strictEmbeddingChecks) {
			if (!embeddable) {
				trace('Video $videoId rejected: not embeddable (basic check only) (title: $title)');
				return false;
			}
			trace('Video $videoId passed basic embeddability check (title: $title)');
			return true;
		}

		// Check basic embeddability
		if (!embeddable) {
			trace('Video $videoId rejected: not embeddable (title: $title)');
			return false;
		}

		// Check privacy status - only allow public videos
		if (privacyStatus != "public") {
			trace('Video $videoId rejected: privacy status is $privacyStatus (title: $title)');
			return false;
		}

		// Check age restrictions - only reject if server config doesn't allow age-restricted content
		if (!config.allowAgeRestrictedVideos && contentRating != null) {
			final ratingKeys = Reflect.fields(contentRating);
			if (ratingKeys.length > 0) {
				trace('Video $videoId rejected: has content rating restrictions (title: $title)');
				return false;
			}
		}

		// Check regional restrictions - use server's configured region
		if (regionRestriction != null) {
			final userRegion = config.youtubeRegion;

			// Check if video is blocked in user's region
			final blockedDynamic:Array<Dynamic> = regionRestriction.blocked ?? [];
			final blocked:Array<String> = [for (item in blockedDynamic) Std.string(item)];
			if (blocked.indexOf(userRegion) != -1) {
				trace('Video $videoId rejected: blocked in region $userRegion (title: $title)');
				return false;
			}

			// Check if video is only allowed in specific regions
			final allowedDynamic:Array<Dynamic> = regionRestriction.allowed ?? [];
			final allowed:Array<String> = [for (item in allowedDynamic) Std.string(item)];
			if (allowed.length > 0 && allowed.indexOf(userRegion) == -1) {
				trace('Video $videoId rejected: not allowed in region $userRegion (title: $title)');
				return false;
			}
		}

		trace('Video $videoId passed all embeddability checks (title: $title)');
		return true;
	}

	public function handleRandomVideoPlaybackError(errorCode:Int):Void {
		final errorType = switch(errorCode) {
			case 101: "Cannot embed (restricted by uploader)";
			case 150: "Embedding disabled";
			case 5: "Format not supported";
			case 2: "Video not found";
			default: "Unknown error ($errorCode)";
		};
		
		sendRandomVideoNotification('[RANDOM VIDEO] User: "${personal.name}" | Error: $errorType | Action: Initiating reroll process...');

		// Remove the failed video from the playlist
		final currentItem = player.getCurrentItem();
		if (currentItem != null) {
			final videoTitle = currentItem.title ?? "Unknown";
			sendRandomVideoNotification('[RANDOM VIDEO] User: "${personal.name}" | Removed: "$videoTitle" | Reason: $errorType');
			removeVideoItem(currentItem.url);
		}

		// Try to find a replacement from the current search results
		if (currentRandomVideoSearch.length > 0
			&& currentRandomVideoIndex < currentRandomVideoSearch.length) {
			final remainingVideos = currentRandomVideoSearch.length - currentRandomVideoIndex;
			sendRandomVideoNotification('[RANDOM VIDEO] User: "${personal.name}" | Action: Trying next video from current search | Remaining: $remainingVideos videos');
			tryNextVideoFromList(
				currentRandomVideoSearch,
				currentRandomVideoIndex,
				currentRandomVideoQuery,
				currentRandomVideoAttemptCount
			);
		} else {
			// No more videos in current search, try a new search
			sendRandomVideoNotification('[RANDOM VIDEO] User: "${personal.name}" | Action: No more videos in current search, starting new search | Attempt: ${currentRandomVideoAttemptCount + 1}/3');
			if (currentRandomVideoAttemptCount < 2) {
				addRandomYoutubeVideoWithRetry(currentRandomVideoAttemptCount + 1);
			} else {
				sendRandomVideoNotification('[RANDOM VIDEO] User: "${personal.name}" | Action: Max attempts reached, falling back to popular queries');
				addRandomYoutubeVideoFallback();
			}
		}
	}

	function addRandomYoutubeVideoFallback():Void {
		// Fallback to popular/trending searches when API search fails
		final popularQueries = [
			"music", "funny animals", "video games", "travel vlog",
			"cooking tutorial", "science explained", "beautiful nature", "guitar cover",
			"dance performance", "documentary short", "art tutorial", "tech review"
		];

		final query = popularQueries[Math.floor(Math.random() * popularQueries.length)];
		final fallbackTime = Date.fromTime(Date.now().getTime());
		trace('Fallback search at ${fallbackTime.toString()} for popular query: "$query"');

		final randomApiKey = getRandomVideoApiKey();
		player.searchYoutubeVideos(query, 10, (videoIds:Array<String>) -> {
			if (videoIds.length == 0) {
				// Absolute final fallback
				final knownVideoIds = ["dQw4w9WgXcQ", "kJQP7kiw5Fk", "fJ9rUzIMcZQ", "9bZkp7q19f0"];
				final randomVideoId = knownVideoIds[Math.floor(Math.random() * knownVideoIds.length)];
				final youtubeUrl = "https://www.youtube.com/watch?v=" + randomVideoId;

				addVideo(youtubeUrl, true, true, false, () -> {
					serverMessage("Added popular video (emergency fallback)");
					// Note: Flag will be cleared when video successfully plays or fails
				});
				return;
			}

			final randomIndex = Math.floor(Math.random() * Math.min(videoIds.length, 5));
			final selectedVideoId = videoIds[randomIndex];
			final youtubeUrl = "https://www.youtube.com/watch?v=" + selectedVideoId;

			addVideo(youtubeUrl, true, true, false, () -> {
				serverMessage('Added trending video: "$query"');
				// Note: Flag will be cleared when video successfully plays or fails
			});
		}, randomApiKey, personal.name, true);
	}

	public function removeVideoItem(url:String) {
		// Make sure we're using the actual URL stored in the videoList for this item
		// This is crucial for iframe embedded YouTube livestreams
		final items = player.getItems();
		// First try to find the exact matching URL
		var matchingItem = items.find(item -> item.url == url);

		// If not found and it's a YouTube URL, try to find by video ID
		if (matchingItem == null
			&& (url.indexOf("youtube.com") > -1 || url.indexOf("youtu.be") > -1)) {
			final videoId = player.extractYoutubeVideoId(url);
			if (videoId != "") {
				matchingItem = items.find(item -> {
					if (item.url.indexOf("youtube.com") > -1 || item.url.indexOf("youtu.be") > -1) {
						return player.extractYoutubeVideoId(item.url) == videoId;
					}
					if (item.playerType == IframeType && item.url.indexOf("<iframe") > -1
						&& item.url.indexOf("youtube.com/embed/") > -1) {
						return item.url.indexOf(videoId) > -1;
					}
					return false;
				});
			}
		}
		// If not found and it's an iframe embed, try to match by iframe content
		else if (matchingItem == null && url.indexOf("<iframe") > -1
			&& url.indexOf("youtube.com/embed/") > -1) {
			final embedMatch = ~/youtube\.com\/embed\/([A-z0-9_-]+)/g;
			if (embedMatch.match(url)) {
				final videoId = embedMatch.matched(1);
				matchingItem = items.find(item -> {
					if (item.url.indexOf("youtube.com") > -1 || item.url.indexOf("youtu.be") > -1) {
						return player.extractYoutubeVideoId(item.url) == videoId;
					}
					if (item.playerType == IframeType && item.url.indexOf("<iframe") > -1
						&& item.url.indexOf("youtube.com/embed/") > -1) {
						return item.url.indexOf(videoId) > -1;
					}
					return false;
				});
			}
		}

		// Use the actual stored URL if we found a match, otherwise use the original URL
		final actualUrl = matchingItem != null ? matchingItem.url : url;

		send({
			type: RemoveVideo,
			removeVideo: {
				url: actualUrl
			}
		});
	}

	public function toggleVideoElement():Bool {
		isVideoEnabled = !isVideoEnabled;
		if (!isVideoEnabled && player.hasVideo()) {
			player.removeVideo();
		} else if (isVideoEnabled && !player.isListEmpty()) {
			player.setVideo(player.getItemPos());
		}
		return isVideoEnabled;
	}

	public function isListEmpty():Bool {
		return player.isListEmpty();
	}

	public function refreshPlayer():Void {
		player.refresh();
	}

	public function getPlaylistLinks():Array<String> {
		final items = player.getItems();
		return [
			for (item in items) item.url
		];
	}

	public function tryLocalIp(url:String):String {
		if (host == globalIp) return url;
		try {
			final url = new URL(url);
			url.hostname = url.hostname.replace(globalIp, host);
			return '$url';
		} catch (e) {
			return url;
		}
	}

	function onMessage(e):Void {
		final data:WsEvent = Json.parse(e.data);
		if (config != null && config.isVerbose) {
			final t:String = cast data.type;
			final t = t.charAt(0).toLowerCase() + t.substr(1);
			trace('Event: ${data.type}', Reflect.field(data, t));
		}
		JsApi.fireEvents(data);
		switch (data.type) {
			case Connected:
				onConnected(data);
				onTimeGet.run();

			case Disconnected: // server-only
			case Login:
				onLogin(data.login.clients, data.login.clientName);

			case PasswordRequest:
				showGuestPasswordPanel();

			case LoginError:
				settings.name = "";
				settings.hash = "";
				Settings.write(settings);
				showGuestLoginPanel();

			case Logout:
				updateClients(data.logout.clients);
				personal = new Client(data.logout.clientName, 0);
				onUserGroupChanged();
				showGuestLoginPanel();
				settings.name = "";
				settings.hash = "";
				Settings.write(settings);

			case UpdateClients:
				updateClients(data.updateClients.clients);
				final oldGroup = personal.group.toInt();
				personal = clients.getByName(personal.name, personal);
				if (personal.group.toInt() != oldGroup) onUserGroupChanged();

			case BanClient: // server-only
			case KickClient:
				document.title = '*${Lang.get("kicked")}*';
				disabledReconnection = true;
				ws.close();
			case Message:
				addMessage(data.message.clientName, data.message.text);

			case EmoteMessage:
				addMessage(data.emoteMessage.clientName, data.emoteMessage.html, null, true);

			case DanmakuMessage:
				if (!isDanmakuEnabled) return;

				// Create a danmaku comment with the received text and color
				final playerEl = getEl("#ytapiplayer");
				final playerRect = playerEl.getBoundingClientRect();
				final laneHeight = Math.floor(playerRect.height / DANMAKU_LANES);

				// Use the lane provided by the sender, or find the best lane if not provided
				var bestLane = 0;
				if (data.danmakuMessage.lane != null) {
					// Use the pre-selected lane from the server for consistent positioning
					bestLane = data.danmakuMessage.lane;
				} else {
					// For backwards compatibility, find the least recently used lane
					var lowestTime = Date.now().getTime();
					for (i in 0...danmakuLanes.length) {
						if (danmakuLanes[i] < lowestTime) {
							lowestTime = danmakuLanes[i];
							bestLane = i;
						}
					}
				}

				// Create the comment element
				final comment = document.createElement("div");
				comment.className = "danmaku-comment";

				// Check if the message should be rendered as HTML (for emotes)
				if (data.danmakuMessage.isHtml == true) {
					// Handle as HTML content (emote)
					comment.innerHTML = data.danmakuMessage.text;
					comment.classList.add("danmaku-emote-container");
				} else if (data.danmakuMessage.text.indexOf("<img") >= 0
					|| data.danmakuMessage.text.indexOf("<video") >= 0) {
					// For backwards compatibility with older clients
					comment.innerHTML = data.danmakuMessage.text;
					comment.classList.add("danmaku-emote-container");
				} else {
					// Handle as plain text
					comment.textContent = data.danmakuMessage.text;
				}

				comment.style.color = data.danmakuMessage.color;
				comment.style.top = (bestLane * laneHeight + laneHeight / 2) + "px";

				// Mark this lane as used now
				danmakuLanes[bestLane] = Std.int(Date.now().getTime());

				// Add animation if available from the server
				if (data.danmakuMessage.animationClass != null
					&& data.danmakuMessage.animationClass.length > 0) {
					// Use the animation class provided by the server
					comment.classList.add(data.danmakuMessage.animationClass);
				}

				// Add to container
				danmakuContainer = getEl("#danmaku-container");
				danmakuContainer.appendChild(comment);

				// Speak the danmaku message if TTS is enabled
				speakText(data.danmakuMessage.text);

				// Calculate animation duration based on comment length and/or content type
				final playerWidth = playerRect.width;
				final viewportWidth = js.Browser.window.innerWidth;
				final totalDistance = playerWidth
					+ viewportWidth; // Distance to travel across screen
				final duration = Math.max(5, (totalDistance / 350) * DANMAKU_SPEED); // Base the speed on pixel travel distance

				// Set animation
				comment.style.animationDuration = duration + "s";

				// Remove after animation completes
				comment.addEventListener("animationend", () -> {
					if (danmakuContainer.contains(comment)) {
						danmakuContainer.removeChild(comment);
					}
				});

			case ServerMessage:
				final id = data.serverMessage.textId;
				var text:String;
				if (id == "usernameError") {
					text = Lang.get(id).replace("$MAX", '${config.maxLoginLength}');
				} else if (id.startsWith("accessError")) {
					final args = id.split("|");
					final err = Lang.get(args[0]);
					if (args.length < 2 || args[1] == null) {
						text = '$err.';
					} else {
						final permText = Lang.get("noPermission").replace("$PERMISSION", args[1]);
						text = '$err: $permText';
					}
				} else {
					text = Lang.get(id);
				}
				serverMessage(text);

			case Progress:
				onProgressEvent(data);

			case AddVideo:
				player.addVideoItem(data.addVideo.item, data.addVideo.atEnd);
				if (player.itemsLength() == 1) player.setVideo(0);

			case VideoLoaded:
				lastState.paused = false;
				lastState.pausedByServer = false;
				lastState.time = 0;
				updateLastStateTime();
				player.setTime(0);
				player.play();
				// try to sync leader after with GetTime events
				if (isLeader() && !player.isVideoLoaded()) forceSyncNextTick = true;

			case RemoveVideo:
				player.removeItem(data.removeVideo.url);
				if (player.isListEmpty()) player.pause();

			case SkipVideo:
				player.skipItem(data.skipVideo.url);
				if (player.isListEmpty()) player.pause();

			case Pause:
				lastState.time = data.pause.time;
				lastState.paused = true;
				updateLastStateTime();
				player.setPauseIndicator(lastState.paused);
				updateUserList();
				if (isLeader()) return;
				player.pause();
				player.setTime(data.pause.time);

			case Play:
				lastState.time = data.play.time;
				lastState.paused = false;
				updateLastStateTime();
				player.setPauseIndicator(lastState.paused);
				updateUserList();
				if (isLeader()) return;
				final synchThreshold = settings.synchThreshold;
				final newTime = data.play.time;
				final time = player.getTime();
				if (Math.abs(time - newTime) >= synchThreshold) {
					player.setTime(newTime);
				}
				player.play();

			case GetTime:
				data.getTime.paused ??= false;
				data.getTime.pausedByServer ??= false;
				data.getTime.rate ??= 1;

				final isPauseChanged = lastState.paused != data.getTime.paused;
				lastState.time = data.getTime.time;
				lastState.paused = data.getTime.paused;
				lastState.pausedByServer = data.getTime.pausedByServer;
				lastState.rate = data.getTime.rate;
				updateLastStateTime();

				if (isPauseChanged) updateUserList();

				final pausedByServer = data.getTime.pausedByServer;
				if (pausedByServer) {
					showServerUnpause();
				} else if (showingServerPause) {
					hideDynamicChin();
				}

				if (player.getPlaybackRate() != data.getTime.rate) {
					player.setPlaybackRate(data.getTime.rate);
				}

				final synchThreshold = settings.synchThreshold;
				final newTime = data.getTime.time;
				final time = player.getTime();
				if (isLeader() && !forceSyncNextTick) {
					// if video is loading on leader
					// move other clients back in time
					if (Math.abs(time - newTime) < synchThreshold) return;
					player.setTime(time, false);
					return;
				}
				if (player.isVideoLoaded()) forceSyncNextTick = false;
				if (player.getDuration() <= player.getTime() + synchThreshold) return;
				if (player.isPaused()) {
					if (!data.getTime.paused) player.play();
				} else {
					if (data.getTime.paused) player.pause();
				}
				player.setPauseIndicator(data.getTime.paused);
				if (Math.abs(time - newTime) < synchThreshold) return;
				// +0.5s for buffering
				if (!data.getTime.paused) player.setTime(newTime + 0.5);
				else player.setTime(newTime);

			case SetTime:
				lastState.time = data.setTime.time;
				updateLastStateTime();
				final synchThreshold = settings.synchThreshold;
				final newTime = data.setTime.time;
				final time = player.getTime();
				if (Math.abs(time - newTime) < synchThreshold) return;
				player.setTime(newTime);

			case SetRate:
				if (isLeader()) return;
				player.setPlaybackRate(data.setRate.rate);

			case Rewind:
				lastState.time = data.rewind.time;
				updateLastStateTime();
				player.setTime(data.rewind.time + 0.5);

			case Flashback: // server-only
			case SetLeader:
				clients.setLeader(data.setLeader.clientName);
				updateUserList();
				setLeaderButton(isLeader());
				if (isLeader()) player.onSetTime();

			case PlayItem:
				player.setVideo(data.playItem.pos);

			case SetNextItem:
				player.setNextItem(data.setNextItem.pos);

			case ToggleItemType:
				player.toggleItemType(data.toggleItemType.pos);

			case ClearChat:
				clearChat();

			case ClearPlaylist:
				player.clearItems();
				if (player.isListEmpty()) player.pause();

			case ShufflePlaylist: // server-only
			case UpdatePlaylist:
				player.setItems(data.updatePlaylist.videoList);
			case TogglePlaylistLock:
				setPlaylistLock(data.togglePlaylistLock.isOpen);

			case Dump:
				Utils.saveFile("dump.json", ApplicationJson, data.dump.data);
			case DrawStart:
				Drawing.onDrawStart(data.drawStart.x, data.drawStart.y, data.drawStart.color, data.drawStart.size, data.drawStart.tool, data.drawStart.clientName);

			case DrawMove:
				Drawing.onDrawMove(data.drawMove.x, data.drawMove.y, data.drawMove.clientName);

			case DrawEnd:
				Drawing.onDrawEnd();
			case ToggleDrawing:
				Drawing.setDrawingEnabled(data.toggleDrawing.enabled);
			case ClearDrawing:
				Drawing.clearCanvas();

			case SaveDrawing:
				// Server acknowledges save - could show confirmation
				trace("Drawing saved successfully");

			case LoadDrawing:
				Drawing.onLoadDrawing(data.loadDrawing.data);
			case DrawCursor:
				// Process incoming cursor data from other clients
				Drawing.onDrawCursor(data.drawCursor.clientName, data.drawCursor.x, data.drawCursor.y);

			case RandomVideoNotification:
				// RandomVideoNotification events are sent from client to server only
				// This case is here for completeness but should not receive events
				
			case SetBackground:
				// Process incoming background changes from other clients
				Drawing.onSetBackground(data.setBackground.isTransparent, data.setBackground.color);
		}
	}

	public function onProgressEvent(data:WsEvent):Void {
		final data = data.progress;
		final text = switch data.type {
			case Caching:
				final caching = Lang.get("caching");
				final name = data.data;
				'$caching $name';
			case Downloading: Lang.get("downloading");
			case Uploading: Lang.get("uploading");
			case Canceled:
				hideDynamicChin();
				return;
		}
		final percent = (data.ratio * 100).toFixed(1);
		var text = '$text...';
		if (percent > 0) text += ' $percent%';
		showProgressInfo(text);
		if (data.ratio == 1) {
			Timer.delay(() -> {
				hideDynamicChin();
			}, 500);
		}
	}

	function updateLastStateTime():Void {
		if (lastStateTimeStamp == 0) {
			lastStateTimeStamp = Timer.stamp();
		}
		timeFromLastState = Timer.stamp() - lastStateTimeStamp;
		lastStateTimeStamp = Timer.stamp();
	}

	function onConnected(data:WsEvent):Void {
		final connected = data.connected;

		settings.uuid = connected.uuid;
		Settings.write(settings);

		globalIp = connected.globalIp;
		playersCacheSupport = connected.playersCacheSupport;
		setConfig(connected.config);
		if (connected.isUnknownClient) {
			updateClients(connected.clients);
			personal = clients.getByName(connected.clientName, personal);
			showGuestLoginPanel();
		} else {
			onLogin(connected.clients, connected.clientName);
		}
		final guestName:InputElement = getEl("#guestname");
		var name = settings.name;
		if (name.length == 0) name = guestName.value;
		final hash = settings.hash;
		if (hash.length > 0) loginRequest(name, hash);
		else guestLogin(name);

		setLeaderButton(isLeader());
		setPlaylistLock(connected.isPlaylistOpen);
		clearChat();
		chatMessageConnected();
		for (message in connected.history) {
			addMessage(message.name, message.text, message.time);
		}
		player.setItems(connected.videoList, connected.itemPos);
		onUserGroupChanged();
		if (settings.showHintList) showChatHintList();
	}

	function showChatHintList():Void {
		var text = Lang.get("hintListStart");

		final addVideos = '<button id="addVideosHintButton">${Lang.get("addVideos")}</button>';
		text += "</br>" + Lang.get("hintListAddVideo").replace("$addVideos", addVideos);

		final requestLeader = '<button id="requestLeaderHintButton">${Lang.get("requestLeader")}</button>';
		text += "</br>"
			+ Lang.get("hintListRequestLeader").replace("$requestLeader", requestLeader);

		if (Utils.isTouch()) text += " " + Lang.get("hintListRequestLeaderTouch");
		else text += " " + Lang.get("hintListRequestLeaderMouse");

		if (Utils.isAndroid()) {
			final openInAppLink = '<button id="openInApp">${Lang.get("openInApp")}</button>';
			text += "</br>"
				+ Lang.get("hintListOpenInApp").replace("$openInApp", openInAppLink);
		}

		final hideThisMessage = '<button id="hideHintList">${Lang.get("hideThisMessage")}</button>';
		text += "</br>"
			+ Lang.get("hintListHide").replace("$hideThisMessage", hideThisMessage);

		serverMessage(text, false, false);

		getEl("#addVideosHintButton").onclick = e -> {
			final addBtn = getEl("#showmediaurl");
			addBtn.scrollIntoView();
			Timer.delay(() -> {
				if (!getEl("#addfromurl").classList.contains("collapse")) {
					getEl("#mediaurl").focus();
					return;
				}
				addBtn.onclick();
			}, 300);
		}
		getEl("#requestLeaderHintButton").onclick = (e:MouseEvent) -> {
			window.scrollTo(0, 0);
			if (Utils.isTouch()) blinkLeaderButton();
		}
		getEl("#requestLeaderHintButton").onpointerenter = e -> {
			if (Utils.isTouch()) return;
			getEl("#leader_btn").classList.add("hint");
		}
		getEl("#requestLeaderHintButton").onpointerleave = e -> {
			getEl("#leader_btn").classList.remove("hint");
		}
		if (Utils.isAndroid()) {
			getEl("#openInApp").onclick = e -> {
				var isRedirected = false;
				window.addEventListener("blur", e -> isRedirected = true, {once: true});
				window.setTimeout(function() {
					if (isRedirected || document.hidden) return;
					window.location.href = "https://github.com/RblSb/SyncTubeApp#readme";
				}, 500);
				window.location.href = 'synctube://${Browser.location.href}';
				return false;
			}
		}
		getEl("#hideHintList").onclick = e -> {
			getEl("#hideHintList").parentElement.remove();
			settings.showHintList = false;
			Settings.write(settings);
		}
	}

	public function blinkLeaderButton():Void {
		getEl("#leader_btn").classList.add("hint");
		Timer.delay(() -> getEl("#leader_btn").classList.remove("hint"), 500);
	}

	function onUserGroupChanged():Void {
		final button:ButtonElement = getEl("#queue_next");
		if (personal.hasPermission(ChangeOrderPerm, config.permissions)) {
			button.disabled = false;
		} else {
			button.disabled = true;
		}
		final adminMenu = getEl("#adminMenu");
		if (isAdmin()) adminMenu.style.display = "";
		else adminMenu.style.display = "none";
	}

	public function guestLogin(name:String):Void {
		if (name.length == 0) return;
		send({
			type: Login,
			login: {
				clientName: name
			}
		});
		settings.name = name;
		Settings.write(settings);
	}

	public function userLogin(name:String, password:String):Void {
		if (config.salt == null) return;
		if (password.length == 0) return;
		if (name.length == 0) name = settings.name;
		final hash = Sha256.encode(password + config.salt);
		loginRequest(name, hash);
		settings.hash = hash;
		Settings.write(settings);
	}

	public function loginRequest(name:String, hash:String):Void {
		send({
			type: Login,
			login: {
				clientName: name,
				passHash: hash
			}
		});
	}

	function setConfig(config:Config):Void {
		this.config = config;
		if (Utils.isTouch()) {
			config.requestLeaderOnPause = false;
			config.unpauseWithoutLeader = false;
		}
		pageTitle = config.channelName;
		final login:InputElement = getEl("#guestname");
		login.maxLength = config.maxLoginLength;
		final form:InputElement = getEl("#chatline");
		form.maxLength = config.maxMessageLength;

		filters.resize(0);
		for (filter in config.filters) {
			filters.push({
				regex: new EReg(filter.regex, filter.flags),
				replace: filter.replace
			});
		}

		// Store all emotes for search functionality
		allAppEmotes = config.emotes.copy();

		for (emote in config.emotes) {
			final isVideoExt = emote.image.endsWith("mp4") || emote.image.endsWith("webm");
			final tag = isVideoExt ? 'video autoplay="" loop="" muted=""' : "img";
			filters.push({
				regex: new EReg("(^| )" + escapeRegExp(emote.name) + "(?!\\S)", "g"),
				replace: '$1<$tag class="channel-emote" src="${emote.image}" title="${emote.name}"/>'
			});
		}
		getEl("#smilesbtn").classList.remove("active");
		final smilesWrap = getEl("#smiles-wrap");
		smilesWrap.style.display = "none";
		final smilesList = getEl("#smiles-list");
		smilesList.onclick = (e:MouseEvent) -> {
			final el:Element = cast e.target;
			if (el == smilesList) return;

			// Get emote data
			final emoteName = el.title;
			final emoteUrl = el.dataset.src ?? (cast el : js.html.ImageElement).src;

			if (emoteUrl != null) {
				// Create emote HTML with consistent sizing
				final emoteHtml = '<img src="${emoteUrl}" alt="${emoteName}" title="${emoteName}" style="height: 128px; width: auto;" />';
				// Use emoteMessage function for danmaku support and consistent behavior
				emoteMessage(emoteHtml);
			}
		}
		// Clear the smiles list - it will be populated by the search function when opened
		smilesList.textContent = "";
	}

	function onLogin(data:Array<ClientData>, clientName:String):Void {
		updateClients(data);
		final newPersonal = clients.getByName(clientName) ?? return;
		personal = newPersonal;
		onUserGroupChanged();
		hideGuestLoginPanel();
	}

	function showGuestLoginPanel():Void {
		getEl("#guestlogin").style.display = "";
		getEl("#guestpassword").style.display = "none";
		getEl("#chatbox").style.display = "none";
		getEl("#exitBtn").textContent = Lang.get("login");
	}

	function hideGuestLoginPanel():Void {
		getEl("#guestlogin").style.display = "none";
		getEl("#guestpassword").style.display = "none";
		getEl("#chatbox").style.display = "";
		getEl("#exitBtn").textContent = Lang.get("exit");
	}

	function showGuestPasswordPanel():Void {
		getEl("#guestlogin").style.display = "none";
		getEl("#chatbox").style.display = "none";
		getEl("#guestpassword").style.display = "";
		(getEl("#guestpass") : InputElement).type = "password";
		getEl("#guestpass_icon").setAttribute("name", "eye");
	}

	function updateClients(newClients:Array<ClientData>):Void {
		clients.resize(0);
		for (client in newClients) {
			clients.push(Client.fromData(client));
		}
		updateUserList();
	}

	public function send(data:WsEvent):Void {
		if (!isConnected) return;
		ws.send(Json.stringify(data));
	}

	public function sendRandomVideoNotification(message:String):Void {
		send({
			type: RandomVideoNotification,
			randomVideoNotification: {
				message: message
			}
		});
	}

	function chatMessageConnected():Void {
		if (isLastMessageConnectionStatus()) {
			msgBuf.removeChild(getLastMessageDiv());
		}
		final div = document.createDivElement();
		div.className = "server-msg-reconnect";
		div.textContent = Lang.get("msgConnected");
		addMessageDiv(div);
		scrollChatToEnd();
	}

	function chatMessageDisconnected():Void {
		if (isLastMessageConnectionStatus()) {
			msgBuf.removeChild(getLastMessageDiv());
		}
		final div = document.createDivElement();
		div.className = "server-msg-disconnect";
		div.textContent = Lang.get("msgDisconnected");
		addMessageDiv(div);
		scrollChatToEnd();
	}

	function isLastMessageConnectionStatus():Bool {
		return getLastMessageDiv()?.className.startsWith("server-msg");
	}

	public function serverMessage(text:String, isText = true, withTimestamp = true):Element {
		final div = document.createDivElement();
		final time = Date.now().toString().split(" ")[1];
		div.className = "server-whisper";
		div.innerHTML = '<div class="head">
			<div class="server-whisper"></div>
			<span class="timestamp">${withTimestamp ? time : ""}</span>
		</div>';
		final textDiv = div.querySelector(".server-whisper");
		if (isText) textDiv.textContent = text;
		else textDiv.innerHTML = text;
		addMessageDiv(div);
		scrollChatToEnd();
		return div;
	}

	// Sends an emote message to all users in the chat
	public function emoteMessage(html:String):Void {
		// Check if the danmaku checkbox is checked
		var sendAsDanmaku = false;
		final danmakuCheckbox:InputElement = getEl("#send-as-danmaku");
		if (danmakuCheckbox != null) {
			sendAsDanmaku = danmakuCheckbox.checked;
		}

		// If sending as danmaku and danmaku is enabled, send as danmaku instead of regular emote
		if (sendAsDanmaku && isDanmakuEnabled) {
			// Pre-select an animation class using the same logic as the server
			// This ensures all clients will use the same animation
			final random = Math.random();
			final animationClass = random < 0.2 ? "" : danmakuEmoteAnimations[Math.floor(Math.random() * danmakuEmoteAnimations.length)];

			// Pre-select a lane to ensure consistent positioning across clients
			final playerEl = getEl("#ytapiplayer");
			final playerRect = playerEl.getBoundingClientRect();
			final laneHeight = Math.floor(playerRect.height / DANMAKU_LANES);

			// Calculate the lane at random to ensure consistent placement
			final bestLane = Math.floor(Math.random() * DANMAKU_LANES);

			// Send the HTML directly as danmaku with isHtml flag, pre-selected animation class, and lane
			send({
				type: DanmakuMessage,
				danmakuMessage: {
					clientName: "", // Server will fill this in
					text: html,
					color: "#FFFFFF",
					isHtml: true,
					animationClass: animationClass,
					lane: bestLane
				}
			});
		} else {
			// Send as regular emote message
			send({
				type: EmoteMessage,
				emoteMessage: {
					clientName: "", // Server will fill this in
					html: html
				}
			});
		}
	}

	public function serverHtmlMessage(el:Element):Void {
		final div = document.createDivElement();
		final time = Date.now().toString().split(" ")[1];
		div.className = "server-whisper";
		div.innerHTML = '<div class="head">
			<div class="server-whisper"></div>
			<span class="timestamp">$time</span>
		</div>';
		div.querySelector(".server-whisper").appendChild(el);
		addMessageDiv(div);
		scrollChatToEnd();
	}

	function updateUserList():Void {
		final userCount = getEl("#usercount");
		userCount.textContent = clients.length + " " + Lang.get("online");
		document.title = getPageTitle();

		final list = new StringBuf();
		for (client in clients) {
			list.add('<div class="userlist_item">');
			final iconName = lastState.paused ? "pause" : "play";
			if (client.isLeader) list.add('<ion-icon name="$iconName"></ion-icon>');
			var klass = client.isBanned ? "userlist_banned" : "";
			if (client.isAdmin) klass += " userlist_owner";
			list.add('<span class="$klass">${client.name}</span></div>');
		}
		final userlist = getEl("#userlist");
		userlist.innerHTML = list.toString();
	}

	function getPageTitle():String {
		return '$pageTitle (${clients.length})';
	}

	function clearChat():Void {
		msgBuf.textContent = "";
	}

	function getLocalDateFromUtc(utcDate:String):String {
		final date = Date.fromString(utcDate);
		final localTime = date.getTime() - date.getTimezoneOffset() * 60 * 1000;
		return Date.fromTime(localTime).toString();
	}

	function addMessage(name:String, text:String, ?date:String, isEmoteMessage:Bool = false):Void {
		final userDiv = document.createDivElement();
		userDiv.className = 'chat-msg-$name';

		final headDiv = document.createDivElement();
		headDiv.className = "head";

		final tstamp = document.createSpanElement();
		tstamp.className = "timestamp";
		if (date == null) date = Date.now().toString();
		else date = getLocalDateFromUtc(date);
		final time = date.split(" ")[1];
		tstamp.textContent = time ?? date;
		tstamp.title = date;

		final nameDiv = document.createElement("strong");
		nameDiv.className = "username";
		nameDiv.textContent = name;

		final textDiv = document.createDivElement();
		textDiv.className = "text";

		// Don't escape HTML for emote messages
		if (!isEmoteMessage) {
			text = text.htmlEscape();

			for (filter in filters) {
				text = filter.regex.replace(text, filter.replace);
			}
		}

		textDiv.innerHTML = text;
		final inChatEnd = isInChatEnd();

		if (inChatEnd) { // scroll chat to end after images loaded
			for (img in textDiv.getElementsByTagName("img")) {
				img.onload = onChatImageLoaded;
			}
			for (video in textDiv.getElementsByTagName("video")) {
				video.onloadedmetadata = onChatVideoLoaded;
			}
		}

		userDiv.appendChild(headDiv);
		headDiv.appendChild(nameDiv);
		headDiv.appendChild(tstamp);
		userDiv.appendChild(textDiv);
		addMessageDiv(userDiv);

		if (inChatEnd) {
			while (msgBuf.children.length > MAX_CHAT_MESSAGES) {
				msgBuf.removeChild(getFirstMessageDiv());
			}
		}
		if (inChatEnd || name == personal.name) {
			scrollChatToEnd();
		} else {
			showScrollToChatEndBtn();
		}

		// Speak the message if TTS is enabled
		speakText(text);

		if (onBlinkTab == null) blinkTabWithTitle('*${Lang.get("chat")}*');
	}

	function getFirstMessageDiv():Null<Element> {
		return isMessageBufferReversed() ? msgBuf.lastElementChild : msgBuf.firstElementChild;
	}

	function getLastMessageDiv():Null<Element> {
		return isMessageBufferReversed() ? msgBuf.firstElementChild : msgBuf.lastElementChild;
	}

	function addMessageDiv(userDiv:Element):Void {
		if (isMessageBufferReversed()) msgBuf.prepend(userDiv);
		else msgBuf.appendChild(userDiv);
	}

	public function showScrollToChatEndBtn():Void {
		final btn = getEl("#scroll-to-chat-end");
		btn.style.display = "";
		Timer.delay(() -> btn.style.opacity = "1", 0);
	}

	public function hideScrollToChatEndBtn():Void {
		final btn = getEl("#scroll-to-chat-end");
		if (btn.style.opacity == "0") return;
		btn.style.opacity = "0";
		btn.addEventListener("transitionend", e -> {
			btn.style.display = "none";
		}, {once: true});
	}

	public function showProgressInfo(text:String):Void {
		final chin = getEl("#dynamic-chin");
		var div = chin.querySelector("#progress-info");
		if (div == null) {
			div = document.createDivElement();
			div.id = "progress-info";
			chin.prepend(div);
		}
		div.textContent = text;
		showDynamicChin();
	}

	public function showServerUnpause():Void {
		if (showingServerPause) return;
		showingServerPause = true;
		final chin = getEl("#dynamic-chin");
		chin.innerHTML = "";

		final div = document.createDivElement();
		div.className = "server-whisper";
		div.textContent = Lang.get("leaderDisconnectedServerOnPause");
		chin.appendChild(div);
		final btn = document.createButtonElement();
		btn.id = "unpause-server";
		btn.textContent = Lang.get("unpause");
		chin.appendChild(btn);
		btn.onclick = () -> {
			hideDynamicChin();
			send({
				type: SetLeader,
				setLeader: {
					clientName: personal.name
				}
			});
			JsApi.once(SetLeader, event -> removeLeader());
		}

		showDynamicChin();
	}

	function showDynamicChin():Void {
		final chin = getEl("#dynamic-chin");
		if (chin.style.display == "") return;
		chin.style.display = "";
		chin.style.transition = "none";
		chin.classList.remove("collapsed");
		final h = chin.clientHeight;
		chin.classList.add("collapsed");
		Timer.delay(() -> {
			chin.style.transition = "";
			chin.classList.remove("collapsed");
			chin.style.height = '${h}px';
		}, 0);
		function onTransitionEnd(e:TransitionEvent):Void {
			if (e.propertyName != "height") return;
			chin.style.height = "";
			chin.removeEventListener("transitionend", onTransitionEnd);
		}
		chin.addEventListener("transitionend", onTransitionEnd);
	}

	public function hideDynamicChin():Void {
		showingServerPause = false;
		final chin = getEl("#dynamic-chin");
		final h = chin.clientHeight;
		chin.style.height = '${h}px';
		Timer.delay(() -> {
			chin.style.height = "";
			chin.classList.add("collapsed");
		}, 0);
		function onTransitionEnd(e:TransitionEvent):Void {
			if (e.propertyName != "height") return;
			chin.style.display = "none";
			chin.removeEventListener("transitionend", onTransitionEnd);
		}
		chin.addEventListener("transitionend", onTransitionEnd);
	}

	function onChatImageLoaded(e:Event):Void {
		scrollChatToEnd();
		(cast e.target : Element).onload = null;
		final btn = getEl("#scroll-to-chat-end");
		btn.style.opacity = "0";
		btn.style.display = "none";
	}

	var emoteMaxSize:Null<Int>;

	function onChatVideoLoaded(e:Event):Void {
		final el:VideoElement = cast e.target;
		emoteMaxSize ??= Std.parseInt(window.getComputedStyle(el)
			.getPropertyValue("max-width"));
		// fixes default video tag size in chat when tab unloads videos in background
		// (some browsers optimization i guess)
		final max = emoteMaxSize;
		final ratio = Math.min(max / el.videoWidth, max / el.videoHeight);
		el.style.width = '${el.videoWidth * ratio}px';
		el.style.height = '${el.videoHeight * ratio}px';
		scrollChatToEnd();
		el.onloadedmetadata = null;
	}

	public function isMessageBufferReversed():Bool {
		return msgBuf.style.flexDirection == "column-reverse";
	}

	public function isInChatEnd(ignoreOffset = 50):Bool {
		final isReverse = isMessageBufferReversed();
		var scrollTop = msgBuf.scrollTop;
		// zero to negative in column-reverse
		if (isReverse) scrollTop = -scrollTop;
		if (isReverse) return scrollTop <= ignoreOffset;
		return scrollTop + msgBuf.clientHeight >= msgBuf.scrollHeight - ignoreOffset;
	}

	public function scrollChatToEnd():Void {
		final isReverse = isMessageBufferReversed();
		if (isReverse) {
			if (Utils.isMacSafari) msgBuf.scrollTop = -1;
			msgBuf.scrollTop = 0;
		} else {
			msgBuf.scrollTop = msgBuf.scrollHeight;
		}
	}

	/* Returns `true` if text should not be sent to chat */
	public function handleCommands(command:String):Bool {
		if (!command.startsWith("/")) return false;
		final args = command.trim().split(" ");
		command = args.shift().substr(1);
		if (command.length == 0) return false;

		switch (command) {
			case "help":
				showChatHintList();
				return true;
			case "ban":
				mergeRedundantArgs(args, 0, 2);
				final name = args[0];
				final time = parseSimpleDate(args[1]);
				if (time < 0) return true;
				send({
					type: BanClient,
					banClient: {
						name: name,
						time: time
					}
				});
				return true;
			case "unban", "removeBan":
				mergeRedundantArgs(args, 0, 1);
				final name = args[0];
				send({
					type: BanClient,
					banClient: {
						name: name,
						time: 0
					}
				});
				return true;
			case "kick":
				mergeRedundantArgs(args, 0, 1);
				final name = args[0];
				send({
					type: KickClient,
					kickClient: {
						name: name
					}
				});
				return true;
			case "clear":
				send({type: ClearChat});
				return true;
			case "flashback", "fb":
				send({type: Flashback});
				return false;
			case "ad":
				player.skipAd();
				return false;
			case "random":
				fetchRandomEmote();
				return true;
			case "random7tv":
				fetchRandom7tvEmote();
				return true;
			case "volume":
				var v = Std.parseFloat(args[0]);
				if (Math.isNaN(v)) v = 1;
				v = v.clamp(0, 3);
				final wasNotFull = player.getVolume() < 1;
				player.setVolume(v.clamp(0, 1));

				if (player.getPlayerType() != RawType) return true;
				if (wasNotFull && v > 1) {
					serverMessage("Volume was not maxed yet to be boosted, you can send command again.");
					return true;
				}
				final rawPlayer = @:privateAccess player.rawPlayer;
				rawPlayer.boostVolume(v);
				return true;
			case "dump":
				send({type: Dump});
				return true;
		}
		if (matchSimpleDate.match(command)) {
			send({
				type: Rewind,
				rewind: {
					time: parseSimpleDate(command)
				}
			});
			return false;
		}
		return false;
	}

	function fetchRandomEmote():Void {
		final xhr = new js.html.XMLHttpRequest();
		xhr.open("GET", "https://api.frankerfacez.com/v1/emotes?sensitive=false&sort=created-desc&page=1&per_page=20", true);
		xhr.onload = () -> {
			if (xhr.status == 200) {
				try {
					final data = haxe.Json.parse(xhr.responseText);
					if (data.emoticons != null && data.emoticons.length > 0) {
						// Pick a random emote from the response
						final randomIndex = Math.floor(Math.random() * data.emoticons.length);
						final emote = data.emoticons[randomIndex];

						if (emote != null) {
							final emoteUrl = getBestEmoteUrl(emote);

							if (emoteUrl != null) {
								final emoteHtml = '<img src="${emoteUrl}" alt="${emote.name}" title="${emote.name}" style="height: 128px; width: auto;" />';
								// Use the new emoteMessage function to broadcast to all users
								emoteMessage(emoteHtml);
							} else {
								serverMessage('Error loading emote: No URL available');
							}
						} else {
							serverMessage('Error loading emote data');
						}
					} else {
						serverMessage('No emotes found');
					}
				} catch (e) {
					serverMessage('Error parsing emote data: ${e}');
				}
			} else {
				serverMessage('Error fetching emotes: ${xhr.status}');
			}
		};
		xhr.onerror = () -> {
			serverMessage('Network error while fetching emotes');
		};
		xhr.send();
	}

	function fetchRandom7tvEmote():Void {
		final xhr = new js.html.XMLHttpRequest();
		xhr.open("GET", "https://7tv.io/v3/emote-sets/global", true);
		xhr.onload = () -> {
			if (xhr.status == 200) {
				try {
					final data = haxe.Json.parse(xhr.responseText);
					if (data.emotes != null && data.emotes.length > 0) {
						// Pick a random emote from the response
						final randomIndex = Math.floor(Math.random() * data.emotes.length);
						final emote = data.emotes[randomIndex];

						if (emote != null) {
							final emoteUrl = getBest7tvEmoteUrl(emote);

							if (emoteUrl != null) {
								final emoteHtml = '<img src="${emoteUrl}" alt="${emote.name}" title="${emote.name}" style="height: 128px; width: auto;" />';
								// Use the emoteMessage function to broadcast to all users
								emoteMessage(emoteHtml);
							} else {
								serverMessage('Error loading 7TV emote: No URL available');
							}
						} else {
							serverMessage('Error loading 7TV emote data');
						}
					} else {
						serverMessage('No 7TV emotes found');
					}
				} catch (e) {
					serverMessage('Error parsing 7TV emote data: ${e}');
				}
			} else {
				serverMessage('Error fetching 7TV emotes: ${xhr.status}');
			}
		};
		xhr.onerror = () -> {
			serverMessage('Network error while fetching 7TV emotes');
		};
		xhr.send();
	}

	final matchSimpleDate = ~/^-?([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+s?)?$/;

	function parseSimpleDate(text:Null<String>):Int {
		if (text == null) return 0;
		if (!matchSimpleDate.match(text)) return 0;
		final matches:Array<String> = [];
		final length = Utils.matchedNum(matchSimpleDate);
		for (i in 1...length) {
			final group = matchSimpleDate.matched(i);
			if (group == null) continue;
			matches.push(group);
		}
		var seconds = 0;
		for (block in matches) {
			seconds += parseSimpleDateBlock(block);
		}
		if (text.startsWith("-")) seconds = -seconds;
		return seconds;
	}

	function parseSimpleDateBlock(block:String):Int {
		inline function time():Int {
			return Std.parseInt(block.substr(0, block.length - 1));
		}
		if (block.endsWith("s")) return time();
		else if (block.endsWith("m")) return time() * 60;
		else if (block.endsWith("h")) return time() * 60 * 60;
		else if (block.endsWith("d")) return time() * 60 * 60 * 24;
		return Std.parseInt(block);
	}

	function mergeRedundantArgs(args:Array<String>, pos:Int, newLength:Int):Void {
		final count = args.length - (newLength - 1);
		if (count < 2) return;
		args.insert(pos, args.splice(pos, count).join(" "));
	}

	public function blinkTabWithTitle(title:String):Void {
		if (!document.hidden) return;
		if (onBlinkTab != null) onBlinkTab.stop();
		onBlinkTab = new Timer(1000);
		onBlinkTab.run = () -> {
			if (document.title.startsWith(pageTitle)) {
				document.title = title;
			} else {
				document.title = getPageTitle();
			}
		}
		onBlinkTab.run();
	}

	function setLeaderButton(flag:Bool):Void {
		final leaderBtn = getEl("#leader_btn");
		leaderBtn.classList.toggle("success-bg", flag);
	}

	function setPlaylistLock(isOpen:Bool):Void {
		isPlaylistOpen = isOpen;
		final lockPlaylist = getEl("#lockplaylist");
		final icon = lockPlaylist.firstElementChild;
		if (isOpen) {
			lockPlaylist.title = Lang.get("playlistOpen");
			lockPlaylist.classList.add("success");
			lockPlaylist.classList.remove("danger");
			icon.setAttribute("name", "lock-open");
		} else {
			lockPlaylist.title = Lang.get("playlistLocked");
			lockPlaylist.classList.add("danger");
			lockPlaylist.classList.remove("success");
			icon.setAttribute("name", "lock-closed");
		}
	}

	public function setSynchThreshold(s:Int):Void {
		onTimeGet.stop();
		onTimeGet = new Timer(s * 1000);
		onTimeGet.run = requestTime;
		settings.synchThreshold = s;
		Settings.write(settings);
	}

	public function toggleLeader():Void {
		// change button style before answer
		setLeaderButton(!personal.isLeader);
		final name = personal.isLeader ? "" : personal.name;
		send({
			type: SetLeader,
			setLeader: {
				clientName: name
			}
		});
	}

	public function removeLeader():Void {
		send({
			type: SetLeader,
			setLeader: {
				clientName: ""
			}
		});
	}

	public function toggleLeaderAndPause():Void {
		if (!isLeader()) {
			JsApi.once(SetLeader, event -> {
				final name = event.setLeader.clientName;
				if (name == getName()) player.pause();
			});
		}
		toggleLeader();
	}

	public function hasLeader():Bool {
		return clients.hasLeader();
	}

	public function hasLeaderOnPauseRequest():Bool {
		final hasAccess = isPageVisible && !isPageUnloading;
		return config.requestLeaderOnPause && hasAccess;
	}

	public function hasUnpauseWithoutLeader():Bool {
		final hasAccess = isPageVisible && !isPageUnloading;
		return config.unpauseWithoutLeader && hasAccess;
	}

	public function getTemplateUrl():String {
		return config.templateUrl;
	}

	public function getYoutubeApiKey():String {
		return config.youtubeApiKey;
	}

	public function getRandomVideoApiKey():String {
		if (config.randomVideoYoutubeApiKey != null && config.randomVideoYoutubeApiKey != "") {
			return config.randomVideoYoutubeApiKey;
		}
		if (config.fallbackToMainApiKey) {
			return config.youtubeApiKey;
		}
		return "";
	}

	public function getUseYoutubeCrawler():Bool {
		return config.useYoutubeCrawler;
	}

	public function getCrawlerFallbackToApi():Bool {
		return config.crawlerFallbackToApi;
	}

	public function getYoutubePlaylistLimit():Int {
		return config.youtubePlaylistLimit;
	}

	public function isAutoplayAllowed():Bool {
		final navigator:{
			getAutoplayPolicy:(type:String) -> Bool
		} = cast Browser.navigator;
		if (navigator.getAutoplayPolicy != null) return
			navigator.getAutoplayPolicy("mediaelement");
		return gotFirstPageInteraction;
	}

	public function isVerbose():Bool {
		return config.isVerbose;
	}

	// TTS methods
	function initTts():Void {
		speechSynthesis = (window : Dynamic).speechSynthesis;
		if (speechSynthesis == null) return;
		// Load Finnish voice when voices are available
		function loadFinnishVoice():Void {
			final voices:Array<Dynamic> = speechSynthesis.getVoices();
			for (voice in voices) {
				if (voice.lang.indexOf("fi") == 0) {
					finnishVoice = voice;
					break;
				}
			}
		}

		// Try to load voices immediately
		loadFinnishVoice();
		// Also listen for voice changes (some browsers load voices asynchronously)
		speechSynthesis.onvoiceschanged = loadFinnishVoice; // Load TTS state from settings
		for (item in settings.checkboxes) {
			if (item.id == "tts-enabled") {
				isTtsEnabled = item.checked == true;
			} else if (item.id == "tts-volume") {
				ttsVolume = cast item.checked;
			}
		}

		// Load TTS volume from settings
		loadTtsVolume();

		// Initialize volume slider
		initTtsVolumeSlider();

		// Always update button state after initialization
		updateTtsButton();
	}

	public function toggleTts():Void {
		isTtsEnabled = !isTtsEnabled;
		updateTtsButton();
		saveTtsState();
	}

	function updateTtsButton():Void {
		final ttsBtn = getEl("#tts-btn");
		if (ttsBtn == null) return;

		if (isTtsEnabled) {
			ttsBtn.classList.add("active");
		} else {
			ttsBtn.classList.remove("active");
		}
	}

	function saveTtsState():Void {
		// Find existing TTS setting or create new one
		var found = false;
		for (item in settings.checkboxes) {
			if (item.id == "tts-enabled") {
				item.checked = isTtsEnabled;
				found = true;
				break;
			}
		}
		if (!found) {
			settings.checkboxes.push({id: "tts-enabled", checked: isTtsEnabled});
		}
		Settings.write(settings);
	}

	function loadTtsVolume():Void {
		// Default TTS volume if not found in settings
		ttsVolume = 1.0;

		// Look for TTS volume setting in checkboxes
		for (item in settings.checkboxes) {
			if (item.id == "tts-volume") {
				ttsVolume = cast item.checked;
				break;
			}
		}
	}

	function initTtsVolumeSlider():Void {
		final volumeInput = getEl("#tts-volume-input");
		final volumeLabel = getEl(".volume-label");
		if (volumeInput == null) return;

		// Set the volume input value from current ttsVolume
		(cast volumeInput).value = Std.string(ttsVolume);

		// Update volume label to show current value
		if (volumeLabel != null) {
			var volumeText = "Volume: "
				+ (ttsVolume > 1 ? "<strong>" + ttsVolume + "x</strong>" : ttsVolume + "x");
			volumeLabel.innerHTML = volumeText;
		}

		// Add event listener for volume changes
		volumeInput.addEventListener("input", function(e) {
			final input = cast(e.target, js.html.InputElement);
			ttsVolume = Std.parseFloat(input.value);

			// Update volume label when slider changes
			if (volumeLabel != null) {
				var volumeText = "Volume: "
					+ (ttsVolume > 1 ? "<strong>" + ttsVolume + "x</strong>" : ttsVolume + "x");
				volumeLabel.innerHTML = volumeText;
			}

			saveTtsVolume();
		});
	}

	function saveTtsVolume():Void {
		// Find existing TTS volume setting or create new one
		var found = false;
		for (item in settings.checkboxes) {
			if (item.id == "tts-volume") {
				item.checked = cast ttsVolume;
				found = true;
				break;
			}
		}
		if (!found) {
			settings.checkboxes.push({id: "tts-volume", checked: cast ttsVolume});
		}
		Settings.write(settings);
	}

	function speakText(text:String):Void {
		if (!isTtsEnabled || speechSynthesis == null || text.trim() == "") return;

		// Extract text from HTML if needed
		final cleanText = extractTextFromHtml(text);
		if (cleanText.trim() == "") return;
		// Create speech utterance
		final utterance = js.Syntax.construct("SpeechSynthesisUtterance", cleanText);

		// Set Finnish voice if available
		if (finnishVoice != null) {
			utterance.voice = finnishVoice;
		} else {
			utterance.lang = "fi-FI";
		}
		// Configure speech parameters
		utterance.rate = 0.9;
		utterance.pitch = 1.0;
		utterance.volume = ttsVolume;

		// Speak the text
		speechSynthesis.speak(utterance);
	}

	function extractTextFromHtml(html:String):String {
		if (html.indexOf("<") == -1) return html;

		// Create temporary element to extract text
		final tempDiv = document.createElement("div");
		tempDiv.innerHTML = html;
		return tempDiv.textContent ?? tempDiv.innerText ?? "";
	}

	function escapeRegExp(regex:String):String {
		return ~/([.*+?^${}()|[\]\\])/g.replace(regex, "\\$1");
	}

	@:generic
	public static inline function getEl<T:Element>(id:String):T {
		return cast document.querySelector(id);
	}

	function loadUserConfig():Config {
		config.allowedFileTypes ??= ["mp4", "mp3", "webm"];
		return config;
	}

	public function getAllowedFileTypes():Array<String> {
		return config.allowedFileTypes;
	}
}
