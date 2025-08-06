package client;

import Types.UploadResponse;
import client.Drawing;
import client.Main.getEl;
import haxe.Json;
import haxe.Timer;
import js.Browser.document;
import js.Browser.window;
import js.html.Blob;
import js.html.Element;
import js.html.ImageElement;
import js.html.InputElement;
import js.html.KeyboardEvent;
import js.html.ProgressEvent;
import js.html.TransitionEvent;
import js.html.VisualViewport;
import js.html.XMLHttpRequest;

class Buttons {
	static var split:Split;
	static var settings:ClientSettings;

	static function generateSearchSuggestion(main:Main):String {
		final words = main.getWordlist();
		
		// Pick 1-3 random words (same logic as keyword mode)
		final numWords = Math.floor(Math.random() * 3) + 1;
		final selectedWords = [];
		for (i in 0...numWords) {
			final word = words[Math.floor(Math.random() * words.length)];
			if (selectedWords.indexOf(word) == -1) {
				selectedWords.push(word);
			}
		}
		return selectedWords.join(" ");
	}

	public static function init(main:Main):Void {
		settings = main.settings;
		if (settings.isSwapped) swapPlayerAndChat();

		split?.destroy();
		split = new Split(settings);
		split.setSize(settings.chatSize);

		initChatInputs(main);

		for (item in settings.checkboxes) {
			if (item.checked == null) continue;
			final checkbox:InputElement = getEl('#${item.id}') ?? continue;
			checkbox.checked = item.checked;
		}

		final passIcon = getEl("#guestpass_icon");
		passIcon.onclick = e -> {
			final icon = passIcon.firstElementChild;
			final isOpen = icon.getAttribute("name") == "eye-off";
			final pass:InputElement = getEl("#guestpass");
			if (isOpen) {
				pass.type = "password";
				icon.setAttribute("name", "eye");
			} else {
				pass.type = "text";
				icon.setAttribute("name", "eye-off");
			}
		}

		final smilesBtn = getEl("#smilesbtn");
		smilesBtn.onclick = e -> {
			final wrap = getEl("#smiles-wrap");
			final list = getEl("#smiles-list");
			if (list.children.length == 0) return;
			
			if (!smilesBtn.classList.contains("active")) {
				// Hide FFZ panel if it's visible
				final ffzWrap = getEl("#ffz-wrap");
				final ffzBtn = getEl("#ffzbtn");
				if (ffzWrap.style.display != "none") {
					ffzWrap.style.display = "none";
					ffzBtn.classList.remove("active");
				}
				
				// Hide 7TV panel if it's visible
				final seventvWrap = getEl("#seventv-wrap");
				final seventvBtn = getEl("#seventvbtn");
				if (seventvWrap.style.display != "none") {
					seventvWrap.style.display = "none";
					seventvBtn.classList.remove("active");
				}
				
				// Show app emotes panel
				wrap.style.display = "";
				wrap.style.height = Utils.outerHeight(list) + "px";
				smilesBtn.classList.add("active");
			} else {
				// Hide app emotes panel
				smilesBtn.classList.remove("active");
				wrap.style.height = "0";
				function onTransitionEnd(e:TransitionEvent):Void {
					if (e.propertyName != "height") return;
					wrap.style.display = "none";
					wrap.removeEventListener("transitionend", onTransitionEnd);
				}
				wrap.addEventListener("transitionend", onTransitionEnd);
			}
			
			if (list.firstElementChild.dataset.src == null) return;
			for (child in list.children) {
				(cast child : ImageElement).src = child.dataset.src;
				child.removeAttribute("data-src");
			}
		}

		final scrollToChatEndBtn = getEl("#scroll-to-chat-end");
		scrollToChatEndBtn.onclick = e -> {
			main.scrollChatToEnd();
			main.hideScrollToChatEndBtn();
		}
		// hide scroll button when chat is scrolled to the end
		final msgBuf = getEl("#messagebuffer");
		msgBuf.onscroll = e -> {
			if (!main.isInChatEnd(1)) return;
			main.hideScrollToChatEndBtn();
		}

		getEl("#clearchatbtn").onclick = e -> {
			if (main.isAdmin()) main.send({type: ClearChat});
		}
		final userList = getEl("#userlist");
		userList.onclick = e -> {
			if (!main.isAdmin()) return;
			var el:Element = cast e.target;
			if (userList == el) return;
			if (!el.classList.contains("userlist_item")) {
				el = el.parentElement;
			}
			var name = "";
			if (el.children.length == 1) {
				name = el.lastElementChild.innerText;
			}
			main.send({
				type: SetLeader,
				setLeader: {
					clientName: name
				}
			});
		}

		final userlistToggle = getEl("#userlisttoggle");
		userlistToggle.onclick = e -> {
			final icon = userlistToggle.firstElementChild;
			final isHidden = icon.getAttribute("name") == "chevron-forward";
			final wrap = getEl("#userlist-wrap");
			final style = getEl("#userlist").style;
			if (isHidden) {
				icon.setAttribute("name", "chevron-down");
				style.display = "";
				final list = wrap.firstElementChild;
				wrap.style.height = "15vh";
				wrap.style.marginBottom = "1rem";
			} else {
				icon.setAttribute("name", "chevron-forward");
				style.display = "none";
				wrap.style.height = "0";
				wrap.style.marginBottom = "0rem";
			}
			settings.isUserListHidden = !isHidden;
			Settings.write(settings);
		}
		getEl("#usercount").onclick = userlistToggle.onclick;
		if (settings.isUserListHidden) userlistToggle.onclick();
		else {
			final wrap = getEl("#userlist-wrap");
			final list = wrap.firstElementChild;
			wrap.style.height = "15vh";
		}
		// enable animation after page loads
		Timer.delay(() -> {
			getEl("#userlist-wrap").style.transition = "200ms";
		}, 0);

		final toggleSynch = getEl("#togglesynch");
		toggleSynch.onclick = e -> {
			final icon = toggleSynch.firstElementChild;
			if (main.isSyncActive) {
				if (!window.confirm(Lang.get("toggleSynchConfirm"))) return;
				main.isSyncActive = false;
				icon.style.color = "rgba(238, 72, 67, 0.75)";
				icon.setAttribute("name", "pause");
			} else {
				main.isSyncActive = true;
				icon.style.color = "";
				icon.setAttribute("name", "play");
				main.send({type: UpdatePlaylist});
			}
		}
		final mediaRefresh = getEl("#mediarefresh");
		mediaRefresh.onclick = e -> {
			main.refreshPlayer();
		}
		final fullscreenBtn = getEl("#fullscreenbtn");
		fullscreenBtn.onclick = e -> {
			// Use pseudo-fullscreen instead of native fullscreen to preserve danmaku overlay
			final isPseudo = Utils.togglePseudoFullscreen();
			final icon = fullscreenBtn.firstElementChild;
			if (isPseudo) {
				icon.setAttribute("name", "contract");
				fullscreenBtn.title = Lang.get("exitFullscreen") ?? "Exit Fullscreen";
			} else {
				icon.setAttribute("name", "expand");
				fullscreenBtn.title = Lang.get("fullscreenPlayer") ?? "Fullscreen Player";
			}
		}
		initPageFullscreen();
		// TTS Button
		final ttsBtn = getEl("#tts-btn");
		ttsBtn.onclick = e -> {
			main.toggleTts();
		}

		// Drawing Button
		final drawingBtn = getEl("#drawingbtn");
		drawingBtn.onclick = e -> {
			Drawing.toggleDrawing();
		}

		final getPlaylist = getEl("#getplaylist");
		getPlaylist.onclick = e -> {
			final text = main.getPlaylistLinks().join(",");
			Utils.copyToClipboard(text);
			final icon = getPlaylist.firstElementChild;
			icon.setAttribute("name", "checkmark");
			Timer.delay(() -> {
				icon.setAttribute("name", "link");
			}, 2000);
		}
		final clearPlaylist = getEl("#clearplaylist");
		clearPlaylist.onclick = e -> {
			if (!window.confirm(Lang.get("clearPlaylistConfirm"))) return;
			main.send({type: ClearPlaylist});
		}
		final shufflePlaylist = getEl("#shuffleplaylist");
		shufflePlaylist.onclick = e -> {
			if (!window.confirm(Lang.get("shufflePlaylistConfirm"))) return;
			main.send({type: ShufflePlaylist});
		}
		
		final randomYoutube = getEl("#randomyoutube");
		randomYoutube.onclick = e -> {
			main.addRandomYoutubeVideo();
		}

		final lockPlaylist = getEl("#lockplaylist");
		lockPlaylist.onclick = e -> {
			if (!main.hasPermission(LockPlaylistPerm)) return;
			if (main.isPlaylistOpen) {
				if (!window.confirm(Lang.get("lockPlaylistConfirm"))) return;
			}
			main.send({
				type: TogglePlaylistLock
			});
		}

		final showMediaUrl = getEl("#showmediaurl");
		showMediaUrl.onclick = e -> {
			final isOpen = showPlayerGroup(showMediaUrl);
			if (isOpen) Timer.delay(() -> {
				getEl("#addfromurl").scrollIntoView();
				getEl("#mediaurl").focus();
			}, 100);
		}

		final showCustomEmbed = getEl("#showcustomembed");
		showCustomEmbed.onclick = e -> {
			final isOpen = showPlayerGroup(showCustomEmbed);
			if (isOpen) Timer.delay(() -> {
				getEl("#customembed").scrollIntoView();
				getEl("#customembed-title").focus();
			}, 100);
		}

		final showYoutubeSearch = getEl("#showyoutubesearch");
		showYoutubeSearch.onclick = e -> {
			final isOpen = showPlayerGroup(showYoutubeSearch);
			if (isOpen) Timer.delay(() -> {
				getEl("#youtubesearch").scrollIntoView();
				getEl("#youtube-search-input").focus();
			}, 100);
		}

		final mediaUrl:InputElement = getEl("#mediaurl");
		final checkboxCache:InputElement = getEl("#cache-on-server");
		mediaUrl.oninput = () -> {
			final url = mediaUrl.value;
			final playerType = main.getLinkPlayerType(url);
			final isSingle = main.isSingleVideoUrl(url);
			final isSingleRawVideo = url != "" && playerType == RawType && isSingle;
			getEl("#mediatitleblock").style.display = isSingleRawVideo ? "" : "none";
			getEl("#subsurlblock").style.display = isSingleRawVideo ? "" : "none";
			getEl("#voiceoverblock").style.display = (url.length > 0 && isSingle) ? "" : "none";

			final isExternal = main.isExternalVideoUrl(url);
			final showCache = isSingle && isExternal
				&& main.playersCacheSupport.contains(playerType);
			checkboxCache.parentElement.style.display = showCache ? "" : "none";
			checkboxCache.checked = settings.checkedCache.contains(playerType);

			final panel = getEl("#addfromurl");
			final oldH = panel.style.height; // save for animation
			panel.style.height = ""; // to calculate height from content
			final newH = Utils.outerHeight(panel) + "px";
			panel.style.height = oldH;
			Timer.delay(() -> panel.style.height = newH, 0);
		}
		mediaUrl.onfocus = mediaUrl.oninput;

		checkboxCache.addEventListener("change", () -> {
			final url = mediaUrl.value;
			final playerType = main.getLinkPlayerType(url);
			final checked = checkboxCache.checked;

			settings.checkedCache.remove(playerType);
			if (checked) settings.checkedCache.push(playerType);
			Settings.write(settings);
		});

		getEl("#insert_template").onclick = e -> {
			mediaUrl.value = main.getTemplateUrl();
			mediaUrl.focus();
		}

		getEl("#mediaurl-upload").onclick = e -> {
			Utils.browseFile((buffer, name) -> {
				name ??= "";
				name = ~/[?#%\/\\]/g.replace(name, "").trim();
				if (name.length == 0) name = "video";
				name = (window : Dynamic).encodeURIComponent(name);

				// Check for valid file type
				final allowedFileTypes = main.getAllowedFileTypes();
				final fileExtension = name.split(".").pop().toLowerCase();
				if (!allowedFileTypes.contains(fileExtension)) {
					main.serverMessage("Uploading this file type is not supported.", true, false);
					return;
				}

				// send last chunk separately to allow server file streaming while uploading
				final chunkSize = 1024 * 1024 * 5; // 5 MB
				final bufferOffset = (buffer.byteLength - chunkSize).limitMin(0);
				final lastChunk = buffer.slice(bufferOffset);
				final chunkReq = window.fetch("/upload-last-chunk", {
					method: "POST",
					headers: {
						"content-name": name,
					},
					body: lastChunk,
				});
				chunkReq.then(e -> {
					e.json().then((data:UploadResponse) -> {
						if (data.errorId != null) {
							main.serverMessage(data.info, true, false);
							return;
						}
						final input:InputElement = getEl("#mediaurl");
						// If data.url is empty, it means that the file was not uploaded to the server
						// and the URL is not valid. In this case, we should not set the input value.
						if (data.url == null) return;
						input.value = data.url;
					});
				});

				final request = new XMLHttpRequest();
				request.open("POST", "/upload", true);
				request.setRequestHeader("content-name", name);

				request.upload.onprogress = (event:ProgressEvent) -> {
					var ratio = 0.0;
					if (event.lengthComputable) {
						ratio = (event.loaded / event.total).clamp(0, 1);
					}
					main.onProgressEvent({
						type: Progress,
						progress: {
							type: Uploading,
							ratio: ratio
						}
					});
				}

				request.onload = (e:ProgressEvent) -> {
					final data:UploadResponse = try {
						Json.parse(request.responseText);
					} catch (e) {
						trace(e);
						return;
					}
					if (data.errorId == null) return;
					main.serverMessage(data.info, true, false);
				}
				request.onloadend = () -> {
					Timer.delay(() -> {
						main.hideDynamicChin();
					}, 500);
				}

				request.send(new Blob([buffer]));
			});
		}

		final showOptions = getEl("#showoptions");
		showOptions.onclick = e -> {
			final isActive = toggleGroup(showOptions);
			getEl("#optionsPanel").style.opacity = isActive ? "1" : "0";
			Timer.delay(() -> {
				if (showOptions.classList.contains("active") != isActive) return;
				getEl("#optionsPanel").classList.toggle("collapse", !isActive);
			}, isActive ? 0 : 200);
		}

		final exitBtn = getEl("#exitBtn");
		exitBtn.onclick = e -> {
			showOptions.onclick();
			if (main.isUser()) main.send({type: Logout});
			else getEl("#guestname").focus();
		}

		final swapLayoutBtn = getEl("#swapLayoutBtn");
		swapLayoutBtn.onclick = e -> {
			swapPlayerAndChat();
			Settings.write(settings);
		}
	}

	static function showPlayerGroup(el:Element):Bool {
		final groups:Array<Element> = cast document.querySelectorAll('[data-target]');
		for (group in groups) {
			if (el == group) continue;
			if (group.classList.contains("collapsed")) continue;
			toggleGroup(group);
		}
		return toggleGroup(el);
	}

	static function toggleGroup(el:Element):Bool {
		el.classList.toggle("collapsed");
		final target = getEl(el.dataset.target);
		final isClosed = target.classList.toggle("collapse");
		if (isClosed) {
			target.style.height = "0";
		} else {
			final list = target.firstElementChild;
			if (target.style.height == "") target.style.height = "0";
			Timer.delay(() -> {
				target.style.height = Utils.outerHeight(list) + "px";
			}, 0);
		}
		return el.classList.toggle("active");
	}

	static function swapPlayerAndChat():Void {
		settings.isSwapped = getEl("body").classList.toggle("swap");
		final sizes = document.body.style.gridTemplateColumns.split(" ");
		sizes.reverse();
		document.body.style.gridTemplateColumns = sizes.join(" ");
	}

	public static function initTextButtons(main:Main):Void {
		final synchThresholdBtn = getEl("#synchThresholdBtn");
		synchThresholdBtn.onclick = e -> {
			var secs = settings.synchThreshold + 1;
			if (secs > 5) secs = 1;
			main.setSynchThreshold(secs);
			updateSynchThresholdBtn();
		}
		updateSynchThresholdBtn();

		// Draggable default skip seconds
		final defaultSkipValue = getEl("#default-skip-value");
		if (defaultSkipValue != null) {
			defaultSkipValue.innerText = Std.string(Std.int(settings.defaultSkipSeconds));
			
			var isDragging = false;
			var lastMouseX = 0.0;
			var startValue = 0.0;
			var onDocumentMouseMove:js.html.MouseEvent -> Void = null;
			var onDocumentMouseUp:js.html.MouseEvent -> Void = null;
			
			onDocumentMouseMove = (e:js.html.MouseEvent) -> {
				if (!isDragging) return;
				final deltaX = e.clientX - lastMouseX;
				final newValue = Math.max(1, Math.round(startValue + deltaX / 5)); // 5 pixels = 1 second
				settings.defaultSkipSeconds = newValue;
				Settings.write(settings);
				defaultSkipValue.innerText = Std.string(Std.int(newValue));
			};
			
			onDocumentMouseUp = (e:js.html.MouseEvent) -> {
				isDragging = false;
				js.Browser.document.removeEventListener("mousemove", onDocumentMouseMove);
				js.Browser.document.removeEventListener("mouseup", onDocumentMouseUp);
			};
			
			defaultSkipValue.onmousedown = (e:js.html.MouseEvent) -> {
				isDragging = true;
				lastMouseX = e.clientX;
				startValue = settings.defaultSkipSeconds;
				e.preventDefault();
				
				js.Browser.document.addEventListener("mousemove", onDocumentMouseMove);
				js.Browser.document.addEventListener("mouseup", onDocumentMouseUp);
			};
		}

		final hotkeysBtn = getEl("#hotkeysBtn");
		hotkeysBtn.onclick = e -> {
			settings.hotkeysEnabled = !settings.hotkeysEnabled;
			Settings.write(settings);
			updateHotkeysBtn();
		}
		updateHotkeysBtn();

		final removeBtn = getEl("#removePlayerBtn");
		removeBtn.onclick = e -> {
			final isActive = main.toggleVideoElement();
			if (isActive) {
				removeBtn.innerText = Lang.get("removePlayer");
			} else {
				removeBtn.innerText = Lang.get("restorePlayer");
			}
		}
		final setVideoUrlBtn = getEl("#setVideoUrlBtn");
		setVideoUrlBtn.onclick = e -> {
			final src = window.prompt(Lang.get("setVideoUrlPrompt"));
			if (src.trim() == "") { // reset to default url
				main.refreshPlayer();
				return;
			}
			JsApi.setVideoSrc(src);
		}
		final selectLocalVideoBtn = getEl("#selectLocalVideoBtn");
		selectLocalVideoBtn.onclick = e -> {
			Utils.browseFileUrl((url, name) -> {
				JsApi.setVideoSrc(url);
			});
		}
	}

	public static function initHotkeys(main:Main, player:Player):Void {
		getEl("#mediarefresh").title += " (Alt-R)";
		getEl("#voteskip").title += " (Alt-S)";
		getEl("#getplaylist").title += " (Alt-C)";
		getEl("#fullscreenbtn").title += " (Alt-F)";
		getEl("#leader_btn").title += " (Alt-L)";
		window.onkeydown = (e:KeyboardEvent) -> {
			if (!settings.hotkeysEnabled) return;
			final target:Element = cast e.target;
			if (isElementEditable(target)) return;
			final key:KeyCode = cast e.keyCode;
			if (key == Backspace) e.preventDefault();
			if (!e.altKey) return;
			switch (key) {
				case R:
					getEl("#mediarefresh").onclick();
				case S:
					getEl("#voteskip").onclick();
				case C:
					getEl("#getplaylist").onclick();
				case F:
					getEl("#fullscreenbtn").onclick();
				case L:
					main.toggleLeader();
				case P:
					main.toggleLeaderAndPause();
				default:
					return;
			}
			e.preventDefault();
		}
	}

	static function isElementEditable(target:Element):Bool {
		if (target == null) return false;
		if (target.isContentEditable) return true;
		final tagName = target.tagName;
		if (tagName == "INPUT" || tagName == "TEXTAREA") return true;
		return false;
	}

	static function updateSynchThresholdBtn():Void {
		final text = Lang.get("synchThreshold");
		final secs = settings.synchThreshold;
		getEl("#synchThresholdBtn").innerText = '$text: ${secs}s';
	}

	static function updateHotkeysBtn():Void {
		final text = Lang.get("hotkeys");
		final state = settings.hotkeysEnabled ? Lang.get("on") : Lang.get("off");
		getEl("#hotkeysBtn").innerText = '$text: $state';
	}

	static function initChatInputs(main:Main):Void {
		final guestName:InputElement = getEl("#guestname");
		guestName.onkeydown = e -> {
			if (e.keyCode == KeyCode.Return) {
				main.guestLogin(guestName.value);
				if (Utils.isTouch()) guestName.blur();
			}
		}

		final guestPass:InputElement = getEl("#guestpass");
		guestPass.onkeydown = e -> {
			if (e.keyCode == KeyCode.Return) {
				main.userLogin(guestName.value, guestPass.value);
				guestPass.value = "";
				if (Utils.isTouch()) guestPass.blur();
			}
		}

		final chatline:InputElement = getEl("#chatline");
		chatline.onfocus = e -> {
			if (Utils.isIOS()) {
				// final startY = window.scrollY;
				final startY = 0;
				Timer.delay(() -> {
					window.scrollBy(0, -(window.scrollY - startY));
					getEl("#video").scrollTop = 0;
					main.scrollChatToEnd();
				}, 100);
			} else if (Utils.isTouch()) {
				main.scrollChatToEnd();
			}
		}
		final viewport = getVisualViewport();
		if (viewport != null) {
			viewport.addEventListener("resize", e -> onViewportResize());
			onViewportResize();
		}

		// Fix the constructor parameters
		final fastForwardInput = document.createElement("div");
		fastForwardInput.style.display = "none";
		new InputWithHistory(
			chatline,
			null, // Pass null for history
			50,
			value -> {
				if (main.handleCommands(value)) return true;
				main.send({
					type: Message,
					message: {
						clientName: "",
						text: value
					}
				});
				if (Utils.isTouch()) chatline.blur();
				return true;
			}
		);

		final checkboxes:Array<InputElement> = [
			getEl("#add-temp"),
		];
		for (checkbox in checkboxes) {
			checkbox.addEventListener("change", () -> {
				final checked = checkbox.checked;
				final item = settings.checkboxes.find(item -> item.id == checkbox.id);
				settings.checkboxes.remove(item);
				settings.checkboxes.push({id: checkbox.id, checked: checked});
				Settings.write(settings);
			});
		}

		// Video randomization checkboxes with mutual exclusion
		final keywordModeCheckbox:InputElement = getEl("#keywordModeBtn");
		final obscureModeCheckbox:InputElement = getEl("#obscureModeBtn");
		
		// Initialize checkbox states from settings
		keywordModeCheckbox.checked = settings.keywordMode;
		obscureModeCheckbox.checked = settings.obscureMode;

		keywordModeCheckbox.addEventListener("change", () -> {
			if (keywordModeCheckbox.checked) {
				// Enable keyword mode, disable obscure mode
				obscureModeCheckbox.checked = false;
				settings.keywordMode = true;
				settings.obscureMode = false;
			} else {
				// If trying to uncheck keyword mode, force enable obscure mode instead
				obscureModeCheckbox.checked = true;
				keywordModeCheckbox.checked = false;
				settings.keywordMode = false;
				settings.obscureMode = true;
			}
			Settings.write(settings);
		});

		obscureModeCheckbox.addEventListener("change", () -> {
			if (obscureModeCheckbox.checked) {
				// Enable obscure mode, disable keyword mode
				keywordModeCheckbox.checked = false;
				settings.obscureMode = true;
				settings.keywordMode = false;
			} else {
				// If trying to uncheck obscure mode, force enable keyword mode instead
				keywordModeCheckbox.checked = true;
				obscureModeCheckbox.checked = false;
				settings.obscureMode = false;
				settings.keywordMode = true;
			}
			Settings.write(settings);
		});

		// Twitch chat toggle checkbox
		final twitchChatCheckbox:InputElement = getEl("#twitchChatEnabled");
		
		// Initialize checkbox state from settings
		twitchChatCheckbox.checked = settings.twitchChatEnabled;
		
		twitchChatCheckbox.addEventListener("change", () -> {
			settings.twitchChatEnabled = twitchChatCheckbox.checked;
			Settings.write(settings);
			
			// Refresh the player to apply the new chat setting
			// This will work for any Twitch video currently playing
			main.refreshPlayer();
		});

		// YouTube search functionality
		final youtubeSearchInput:InputElement = getEl("#youtube-search-input");
		final youtubeSearchBtn = getEl("#youtube-search-btn");
		final youtubeSearchTemplate = getEl("#youtube_search_template");
		final randomVideoCheckbox:InputElement = getEl("#add-before-date");
		final youtubeSearchStatus = getEl("#youtube-search-status");

		youtubeSearchTemplate.onclick = e -> {
			// Generate a dynamic search suggestion using the wordlist
			final suggestion = generateSearchSuggestion(main);
			youtubeSearchInput.value = suggestion;
			youtubeSearchInput.focus();
		};

		youtubeSearchBtn.onclick = e -> {
			final searchTerm = youtubeSearchInput.value.trim();
			trace('[YOUTUBE SEARCH] Search button clicked, searchTerm: "${searchTerm}"');
			if (searchTerm == "") {
				trace('[YOUTUBE SEARCH] Empty search term, returning');
				return;
			}

			// Build search query
			var query = searchTerm;
			if (randomVideoCheckbox.checked) {
				// Add random date range (after and before on consecutive days)
				final currentYear = Date.now().getFullYear();
				final year = currentYear - (Math.floor(Math.random() * 15) + 1);
				final month = Math.floor(Math.random() * 12) + 1;
				final day = Math.floor(Math.random() * 28) + 1;
				final monthStr = month < 10 ? "0" + month : "" + month;
				final dayStr = day < 10 ? "0" + day : "" + day;
				
				// Calculate next day for "before" parameter
				final nextDay = day + 1;
				final nextDayStr = nextDay < 10 ? "0" + nextDay : "" + nextDay;
				
				// Handle month rollover (simplified - just use same month for safety)
				var nextMonthStr = monthStr;
				var nextDayFormatted = nextDayStr;
				if (nextDay > 28) {
					// If day goes beyond 28, use next month's first day
					final nextMonth = month + 1 > 12 ? 1 : month + 1;
					nextMonthStr = nextMonth < 10 ? "0" + nextMonth : "" + nextMonth;
					nextDayFormatted = "01";
				}
				
				query += ' after:$year-$monthStr-$dayStr before:$year-$nextMonthStr-$nextDayFormatted';
			}

			// Show loading state
			youtubeSearchStatus.textContent = "Searching...";

			// Use more results for better randomization when random video is enabled
			final maxResults = randomVideoCheckbox.checked ? 50 : 20;
			trace('[YOUTUBE SEARCH] About to call main.searchYoutubeVideos with query: "${query}", maxResults: ${maxResults}');
			
			// Search for videos using the existing YouTube crawler
			main.searchYoutubeVideos(query, maxResults, (videoIds:Array<String>) -> {
				trace('[YOUTUBE SEARCH] Callback received videoIds: ${videoIds}');
				trace('[YOUTUBE SEARCH] VideoIds length (before dedup): ${videoIds.length}');
				
				// Remove duplicates from the video IDs array
				final uniqueVideoIds = [];
				for (videoId in videoIds) {
					if (uniqueVideoIds.indexOf(videoId) == -1) {
						uniqueVideoIds.push(videoId);
					}
				}
				
				trace('[YOUTUBE SEARCH] VideoIds length (after dedup): ${uniqueVideoIds.length}');
				
				if (uniqueVideoIds.length > 0) {
					// Select video based on random video checkbox state
					final selectedVideoId = if (randomVideoCheckbox.checked) {
						// Random selection when checkbox is enabled
						final randomIndex = Math.floor(Math.random() * uniqueVideoIds.length);
						uniqueVideoIds[randomIndex];
					} else {
						// First video when checkbox is disabled
						uniqueVideoIds[0];
					};
					
					final videoUrl = "https://www.youtube.com/watch?v=" + selectedVideoId;
					trace('[YOUTUBE SEARCH] Auto-queueing video: ${videoUrl} (random: ${randomVideoCheckbox.checked})');
					
					// Automatically add the selected video to the end of the playlist as temporary
					main.addVideo(videoUrl, true, true, false);
					
					youtubeSearchStatus.textContent = 'Video added to playlist!';
					trace('[YOUTUBE SEARCH] Video successfully queued');
					
					// Clear status after 3 seconds
					Timer.delay(() -> {
						youtubeSearchStatus.textContent = "";
					}, 3000);
				} else {
					youtubeSearchStatus.textContent = "No videos found for this search";
					trace('[YOUTUBE SEARCH] No videos found in callback');
					
					// Clear status after 3 seconds
					Timer.delay(() -> {
						youtubeSearchStatus.textContent = "";
					}, 3000);
				}
			});
		};

		// Allow Enter key to trigger search
		youtubeSearchInput.onkeypress = e -> {
			if (e.keyCode == 13) { // Enter key
				youtubeSearchBtn.onclick(null);
			}
		};
	}

	public static function onViewportResize():Void {
		final viewport = getVisualViewport() ?? return;
		final isPortrait = window.innerHeight > window.innerWidth;
		final playerH = getEl("#ytapiplayer").offsetHeight;
		var h = viewport.height - playerH;
		if (!isPortrait) h = viewport.height;
		getEl("#chat").style.height = '${h}px';
	}

	static inline function getVisualViewport():Null<VisualViewport> {
		return (window : Dynamic).visualViewport;
	}

	static function initPageFullscreen():Void {
		document.onfullscreenchange = e -> {
			final el = document.documentElement;
			if (Utils.hasFullscreen()) {
				if (e.target == el) el.classList.add("mobile-view");
			} else el.classList.remove("mobile-view");
		}
	}
}
