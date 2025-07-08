package client.players;

import Types.PlayerType;
import Types.VideoData;
import Types.VideoDataRequest;
import Types.VideoItem;
import client.Main.getEl;
import js.Browser.document;
import js.Browser.window;
import js.html.Element;

typedef TwitchEmbedOptions = {
	width:Int,
	height:Int,
	?channel:String,
	?video:String,
	?collection:String,
	parent:Array<String>,
	?autoplay:Bool,
	?muted:Bool,
	?time:String,
	?layout:String
}

typedef TwitchPlayer = {
	function play():Void;
	function pause():Void;
	function seek(time:Float):Void;
	function setVolume(volume:Float):Void;
	function getMuted():Bool;
	function setMuted(muted:Bool):Void;
	function getVolume():Float;
	function getCurrentTime():Float;
	function getDuration():Float;
	function getEnded():Bool;
	function isPaused():Bool;
	function addEventListener(event:String, callback:Dynamic -> Void):Void;
	function removeEventListener(event:String, callback:Dynamic -> Void):Void;
}

typedef TwitchEmbed = {
	function getPlayer():TwitchPlayer;
	function addEventListener(event:String, callback:Dynamic -> Void):Void;
	function removeEventListener(event:String, callback:Dynamic -> Void):Void;
}

@:native("Twitch.Embed")
extern class TwitchEmbedClass {
	public function new(elementId:String, options:TwitchEmbedOptions):Void;
	public function getPlayer():TwitchPlayer;
	public function addEventListener(event:String, callback:Dynamic -> Void):Void;
	public function removeEventListener(event:String, callback:Dynamic -> Void):Void;
}

@:native("Twitch.Player")
extern class TwitchPlayerClass {
	public function new(elementId:String, options:TwitchEmbedOptions):Void;
	public function play():Void;
	public function pause():Void;
	public function seek(time:Float):Void;
	public function setVolume(volume:Float):Void;
	public function getMuted():Bool;
	public function setMuted(muted:Bool):Void;
	public function getVolume():Float;
	public function getCurrentTime():Float;
	public function getDuration():Float;
	public function getEnded():Bool;
	public function isPaused():Bool;
	public function addEventListener(event:String, callback:Dynamic -> Void):Void;
	public function removeEventListener(event:String, callback:Dynamic -> Void):Void;
}

class Twitch implements IPlayer {
	final main:Main;
	final player:Player;
	final playerEl:Element = getEl("#ytapiplayer");
	var video:Element;
	var twitchEmbed:TwitchEmbed;
	var twitchPlayer:TwitchPlayer;
	var isLoaded = false;
	var onReadyCallback:Void -> Void;
	var onPlayCallback:Void -> Void;
	var onPauseCallback:Void -> Void;
	var onSeekCallback:Void -> Void;
	var resizeObserver:Dynamic;
	
	public function new(main:Main, player:Player) {
		this.main = main;
		this.player = player;
	}

	public function getPlayerType():PlayerType {
		return TwitchType;
	}

	public function isSupportedLink(url:String):Bool {
		return extractChannelName(url) != "" || extractVideoId(url) != "";
	}

	public function extractChannelName(url:String):String {
		// Extract channel name from Twitch URLs
		// https://www.twitch.tv/channelname
		// https://twitch.tv/channelname
		final channelRegex = ~/^https?:\/\/(?:www\.)?twitch\.tv\/([a-zA-Z0-9_]+)(?:\/.*)?$/;
		if (channelRegex.match(url)) {
			return channelRegex.matched(1);
		}
		return "";
	}

	public function extractVideoId(url:String):String {
		// Extract video ID from Twitch video URLs
		// https://www.twitch.tv/videos/123456789
		final videoRegex = ~/^https?:\/\/(?:www\.)?twitch\.tv\/videos\/([0-9]+)(?:\/.*)?$/;
		if (videoRegex.match(url)) {
			return videoRegex.matched(1);
		}
		return "";
	}

	public function getVideoData(data:VideoDataRequest, callback:(data:VideoData) -> Void):Void {
		final url = data.url;
		final channelName = extractChannelName(url);
		final videoId = extractVideoId(url);
		
		if (channelName != "" || videoId != "") {
			var title = channelName != "" ? 'Twitch: $channelName' : 'Twitch Video: $videoId';
			callback({
				duration: 99 * 60 * 60, // Set long duration for live streams
				title: title,
				url: url
			});
		} else {
			callback({duration: 0});
		}
	}

	public function loadVideo(item:VideoItem):Void {
		if (!isTwitchSDKLoaded()) {
			// Wait for SDK to load
			window.setTimeout(() -> loadVideo(item), 100);
			return;
		}
		
		removeVideo();
		isLoaded = false;
		
		// Create container element with proper ID for responsive styling
		video = document.createDivElement();
		video.id = "videoplayer";
		playerEl.appendChild(video);
		
		final channelName = extractChannelName(item.url);
		final videoId = extractVideoId(item.url);
		final hostname = getValidTwitchParent();
		final clientId = main.getTwitchClientId();
		
		// Calculate responsive dimensions based on container
		final containerWidth = playerEl.clientWidth;
		final containerHeight = playerEl.clientHeight;
		final aspectRatio = 16.0 / 9.0;
		
		// Use container width, calculate height maintaining 16:9 aspect ratio
		final playerWidth = containerWidth > 0 ? containerWidth : 854;
		final playerHeight = Math.round(playerWidth / aspectRatio);
		
		var embedOptions:TwitchEmbedOptions = {
			width: playerWidth,
			height: playerHeight,
			parent: [hostname],
			autoplay: true,
			muted: !main.isAutoplayAllowed(),
			layout: main.settings.twitchChatEnabled ? "video-with-chat" : "video"
		};
		
		trace('Twitch embed - channel: "$channelName", video: "$videoId", layout: ${embedOptions.layout}, twitchChatEnabled: ${main.settings.twitchChatEnabled}');
		
		if (channelName != "") {
			embedOptions.channel = channelName;
		} else if (videoId != "") {
			embedOptions.video = videoId;
		}
		
		try {
			// Create a unique ID for this embed instance
			final embedId = "twitch-embed-" + Math.floor(Math.random() * 10000);
			video.id = embedId;
			
			twitchEmbed = cast new TwitchEmbedClass(embedId, embedOptions);
			
			// Set up event listeners
			twitchEmbed.addEventListener("Twitch.Embed.VIDEO_READY", onVideoReady);
			
			// After embed is created, style the container for responsiveness
			video.style.width = "100%";
			video.style.height = "100%";
			video.style.maxHeight = "80vh"; // Match other players
			
			// Set up resize observer for responsive behavior
			setupResizeObserver();
			
		} catch (e:Dynamic) {
			trace('Twitch embed error: $e');
			main.serverMessage('Error loading Twitch stream', false);
			removeVideo();
		}
	}
	
	function onVideoReady(e:Dynamic):Void {
		twitchPlayer = twitchEmbed.getPlayer();
		
		// Set up player event listeners
		twitchPlayer.addEventListener("play", onPlay);
		twitchPlayer.addEventListener("pause", onPause);
		twitchPlayer.addEventListener("seek", onSeek);
		twitchPlayer.addEventListener("ready", onReady);
		
		isLoaded = true;
		
		// Apply initial state
		if (main.lastState.paused) {
			twitchPlayer.pause();
		}
		
		player.onCanBePlayed();
	}
	
	function onReady(e:Dynamic):Void {
		// Player is ready
		if (onReadyCallback != null) {
			onReadyCallback();
		}
	}
	
	function onPlay(e:Dynamic):Void {
		player.onPlay();
		if (onPlayCallback != null) {
			onPlayCallback();
		}
	}
	
	function onPause(e:Dynamic):Void {
		player.onPause();
		if (onPauseCallback != null) {
			onPauseCallback();
		}
	}
	
	function onSeek(e:Dynamic):Void {
		player.onSetTime();
		if (onSeekCallback != null) {
			onSeekCallback();
		}
	}
	
	function setupResizeObserver():Void {
		// Create a resize observer to handle responsive resizing
		if (js.Syntax.code("typeof ResizeObserver !== 'undefined'")) {
			resizeObserver = js.Syntax.code("new ResizeObserver(function(entries) {
				// Throttle resize events to avoid performance issues
				clearTimeout(this.resizeTimeout);
				this.resizeTimeout = setTimeout(function() {
					if (video && video.style) {
						// Ensure the container maintains responsive behavior
						video.style.width = '100%';
						video.style.height = '100%';
					}
				}, 100);
			})");
			js.Syntax.code("{0}.observe({1})", resizeObserver, playerEl);
		}
	}

	function isTwitchSDKLoaded():Bool {
		return js.Syntax.code("typeof Twitch !== 'undefined' && typeof Twitch.Embed !== 'undefined'");
	}

	function getValidTwitchParent():String {
		final hostname = js.Browser.location.hostname;
		
		// For localhost and IP addresses, return localhost
		if (hostname == "localhost" || hostname == "127.0.0.1") {
			return "localhost";
		}
		
		// For IP addresses (IPv4), use localhost
		if (~/^\d+\.\d+\.\d+\.\d+$/.match(hostname)) {
			return "localhost";
		}
		
		// For Windows machine names or other non-domain hostnames, use localhost
		// Valid domain names should contain at least one dot
		if (hostname.indexOf(".") == -1) {
			return "localhost";
		}
		
		// For valid domain names, return as-is
		return hostname;
	}

	public function removeVideo():Void {
		if (video == null) return;
		
		if (twitchEmbed != null) {
			try {
				twitchEmbed.removeEventListener("Twitch.Embed.VIDEO_READY", onVideoReady);
			} catch (e:Dynamic) {
				trace('Error removing Twitch embed listeners: $e');
			}
		}
		
		if (twitchPlayer != null) {
			try {
				twitchPlayer.removeEventListener("play", onPlay);
				twitchPlayer.removeEventListener("pause", onPause);
				twitchPlayer.removeEventListener("seek", onSeek);
				twitchPlayer.removeEventListener("ready", onReady);
			} catch (e:Dynamic) {
				trace('Error removing Twitch player listeners: $e');
			}
		}
		
		// Clean up resize observer
		if (resizeObserver != null) {
			try {
				js.Syntax.code("{0}.disconnect()", resizeObserver);
				resizeObserver = null;
			} catch (e:Dynamic) {
				trace('Error cleaning up resize observer: $e');
			}
		}
		
		isLoaded = false;
		twitchEmbed = null;
		twitchPlayer = null;
		
		if (playerEl.contains(video)) {
			playerEl.removeChild(video);
		}
		video = null;
	}

	public function isVideoLoaded():Bool {
		return isLoaded && twitchPlayer != null;
	}

	public function play():Void {
		if (twitchPlayer != null) {
			twitchPlayer.play();
		}
	}

	public function pause():Void {
		if (twitchPlayer != null) {
			twitchPlayer.pause();
		}
	}

	public function isPaused():Bool {
		if (twitchPlayer != null) {
			return twitchPlayer.isPaused();
		}
		return false;
	}

	public function getTime():Float {
		if (twitchPlayer != null) {
			return twitchPlayer.getCurrentTime();
		}
		return 0;
	}

	public function setTime(time:Float):Void {
		if (twitchPlayer != null) {
			twitchPlayer.seek(time);
		}
	}

	public function getPlaybackRate():Float {
		// Twitch doesn't support playback rate changes
		return 1.0;
	}

	public function setPlaybackRate(rate:Float):Void {
		// Twitch doesn't support playback rate changes
	}

	public function getVolume():Float {
		if (twitchPlayer != null) {
			return twitchPlayer.getVolume();
		}
		return 1.0;
	}

	public function setVolume(volume:Float):Void {
		if (twitchPlayer != null) {
			twitchPlayer.setVolume(volume);
		}
	}

	public function unmute():Void {
		if (twitchPlayer != null) {
			twitchPlayer.setMuted(false);
		}
	}
}