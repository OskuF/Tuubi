package server;

import Types.UploadResponse;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import js.lib.Promise;
import js.node.Buffer;
import js.node.Fs.Fs;
import js.node.Http;
import js.node.Https;
import js.node.Path as JsPath; // Fix JsPath import
import js.node.http.ClientRequest;
import js.node.http.IncomingMessage;
import js.node.http.ServerResponse;
import js.node.url.URL;
import json2object.ErrorUtils;
import json2object.JsonParser;
import server.cache.Cache;
import sys.FileSystem;

// Emote API Types
typedef EmoteUrl = {
	size:String,
	url:String
}

typedef Emote = {
	code:String,
	provider:Int,
	zero_width:Bool,
	animated:Bool,
	urls:Array<EmoteUrl>
}

@:structInit
private class HttpServerConfig {
	public final dir:String;
	public final customDir:String = null;
	public final allowLocalRequests = false;
	public final cache:Cache = null;
}

typedef SetupAdminRequest = {
	name:String,
	password:String,
	passwordConfirmation:String,
}

class HttpServer {
	static final mimeTypes = [
		"html" => "text/html",
		"js" => "text/javascript",
		"css" => "text/css",
		"json" => "application/json",
		"png" => "image/png",
		"jpg" => "image/jpeg",
		"jpeg" => "image/jpeg",
		"gif" => "image/gif",
		"webp" => "image/webp",
		"svg" => "image/svg+xml",
		"ico" => "image/x-icon",
		"wav" => "audio/wav",
		"mp3" => "audio/mpeg",
		"mp4" => "video/mp4",
		"webm" => "video/webm",
		"woff" => "application/font-woff",
		"ttf" => "application/font-ttf",
		"eot" => "application/vnd.ms-fontobject",
		"otf" => "application/font-otf",
		"wasm" => "application/wasm"
	];

	final main:Main;
	final dir:String;
	final customDir:String;
	final hasCustomRes = false;
	final allowedLocalFiles:Map<String, Bool> = [];
	final allowLocalRequests = false;
	final cache:Cache = null;
	final CHUNK_SIZE = 1024 * 1024 * 5; // 5 MB
	// temp media data while file is uploading to allow instant streaming
	final uploadingFilesSizes:Map<String, Int> = [];
	final uploadingFilesLastChunks:Map<String, Buffer> = [];
	final allowedFileTypes:Array<String>;
	// Emotes API
	final emotesAPI:EmotesAPI;

	public function new(main:Main, config:HttpServerConfig):Void {
		this.main = main;
		dir = config.dir;
		customDir = config.customDir;
		allowLocalRequests = config.allowLocalRequests;
		cache = config.cache;
		allowedFileTypes = main.config.allowedFileTypes;
		emotesAPI = new EmotesAPI(); // Initialize EmotesAPI

		if (customDir != null) hasCustomRes = FileSystem.exists(customDir);
	}

	public function serveFiles(req:IncomingMessage, res:ServerResponse):Void {
		final url = try {
			new URL(safeDecodeURI(req.url), "http://localhost");
		} catch (e) {
			new URL("/", "http://localhost");
		}
		var filePath = getPath(dir, url);
		final ext = Path.extension(filePath).toLowerCase();

		res.setHeader("accept-ranges", "bytes");
		res.setHeader("content-type", getMimeType(ext));

		// Handle emote API endpoints
		if (url.pathname.startsWith("/api/emotes")) {
			handleEmoteApiRequest(req, res, url);
			return;
		}

		if (cache != null && req.method == "POST") {
			switch url.pathname {
				case "/upload-last-chunk":
					uploadFileLastChunk(req, res);
				case "/upload":
					uploadFile(req, res);
				case "/setup":
					finishSetup(req, res);
			}
			return;
		}

		if (allowLocalRequests && req.socket.remoteAddress == req.socket.localAddress
			|| allowedLocalFiles[url.pathname]) {
			if (isMediaExtension(ext)) {
				allowedLocalFiles[url.pathname] = true;
				if (serveMedia(req, res, url.pathname.urlDecode())) return;
			}
		}

		if (!isChildOf(dir, filePath)) {
			res.statusCode = 500;
			var rel = JsPath.relative(dir, filePath);
			res.end('Error getting the file: No access to $rel.');
			return;
		}

		if (url.pathname == "/setup") {
			if (main.hasAdmins()) {
				res.redirect("/");
				return;
			}

			Fs.readFile('$dir/setup.html', (err:Dynamic, data:Buffer) -> {
				data = Buffer.from(localizeHtml(data.toString(), req.headers["accept-language"]));
				res.setHeader("content-type", getMimeType("html"));
				res.end(data);
			});
			return;
		}

		if (url.pathname == "/proxy") {
			if (!proxyUrl(req, res)) res.end('Proxy error: ${req.url}');
			return;
		}

		if (hasCustomRes) {
			final path = getPath(customDir, url);
			if (Fs.existsSync(path)) filePath = path;
			final ext = Path.extension(filePath).toLowerCase();
			res.setHeader("content-type", getMimeType(ext));
		}

		if (isMediaExtension(ext)) {
			if (serveMedia(req, res, filePath)) return;
		}

		Fs.readFile(filePath, (err:Dynamic, data:Buffer) -> {
			if (err != null) {
				readFileError(err, res, filePath);
				return;
			}

			if (ext == "html") {
				if (!main.isNoState && !main.hasAdmins()) {
					res.redirect("/setup");
					return;
				}
				// replace ${textId} to localized strings
				data = cast localizeHtml(data.toString(), req.headers["accept-language"]);
			}
			res.end(data);
		});
	}

	function uploadFileLastChunk(req:IncomingMessage, res:ServerResponse) {
		var fileName = try decodeURIComponent(req.headers["content-name"]) catch (e) "";
		if (fileName.trim().length == 0) fileName = null;

		// Restrict file types
		final ext = Path.extension(fileName).toLowerCase();
		// log the user and file extension.
		trace("Trying to upload new file to the cache: " + fileName + ", extension: " + ext);
		if (!isAllowedFileType(ext)) {
			res.status(400)
				.json({info: "Invalid file type. Filetype is not on the whitelist."});
			trace("Filetype not allowed: " + ext);
			return;
		}

		final name = cache.getFreeFileName(fileName);
		final filePath = cache.getFilePath(name);
		final body:Array<Any> = [];
		req.on("data", chunk -> body.push(chunk));
		req.on("end", () -> {
			final buffer = Buffer.concat(body);
			uploadingFilesLastChunks[filePath] = buffer;
			final json:UploadResponse = {
				info: "File last chunk uploaded",
				url: cache.getFileUrl(name)
			}
			res.status(200).json(json);
		});
	}

	function uploadFile(req:IncomingMessage, res:ServerResponse) {
		var fileName = try decodeURIComponent(req.headers["content-name"]) catch (e) "";
		if (fileName.trim().length == 0) fileName = null;

		// Restrict file types
		final ext = Path.extension(fileName).toLowerCase();
		if (!isAllowedFileType(ext)) {
			res.status(400)
				.json({info: "Invalid file type. Only mp4, mp3, and webm are allowed."});
			return;
		}

		final name = cache.getFreeFileName(fileName);
		final filePath = cache.getFilePath(name);
		final size = Std.parseInt(req.headers["content-length"]) ?? return;

		inline function end(code:Int, json:UploadResponse):Void {
			res.status(code).json(json);
			uploadingFilesSizes.remove(filePath);
			uploadingFilesLastChunks.remove(filePath);
		}

		if (size < cache.storageLimit) {
			// do not remove older cache if file is out of limit anyway
			cache.removeOlderCache(size);
		}
		if (cache.getFreeSpace() < size) {
			end(413, { // Payload Too Large
				info: cache.notEnoughSpaceErrorText,
				errorId: "freeSpace",
			});
			cache.remove(name);
			req.destroy();
			final client = main.clients.getByName(name) ?? return;
			main.serverMessage(client, cache.notEnoughSpaceErrorText);
			return;
		}

		final stream = Fs.createWriteStream(filePath);
		req.pipe(stream);

		cache.add(name);
		uploadingFilesSizes[filePath] = size;

		stream.on("close", () -> {
			end(200, {
				info: "File write stream closed.",
			});
		});
		stream.on("error", err -> {
			trace(err);
			end(500, {
				info: "File write stream error.",
			});
			cache.remove(name);
		});
		req.on("error", err -> {
			trace("Request Error:", err);
			stream.destroy();
			end(500, {
				info: "File request error.",
			});
			cache.remove(name);
		});
	}

	// Helper function to check allowed file types
	function isAllowedFileType(ext:String):Bool {
		return allowedFileTypes.contains(ext);
	}

	function finishSetup(req:IncomingMessage, res:ServerResponse) {
		if (main.hasAdmins()) {
			return res.redirect("/");
		}

		final bodyChunks:Array<Buffer> = [];

		req.on("data", chunk -> {
			bodyChunks.push(chunk);
		});

		req.on("end", () -> {
			final body = Buffer.concat(bodyChunks).toString();
			final jsonParser = new JsonParser<SetupAdminRequest>();
			final jsonData = jsonParser.fromJson(body);
			if (jsonParser.errors.length > 0) {
				final errors = ErrorUtils.convertErrorArray(jsonParser.errors);
				trace(errors);
				res.status(400).json({success: false, errors: []});
				return;
			}
			final name = jsonData.name;
			final password = jsonData.password;
			final passwordConfirmation = jsonData.passwordConfirmation;
			final lang = req.headers["accept-language"] ?? "en";
			final errors:Array<{type:String, error:String}> = [];

			if (main.isBadClientName(name)) {
				final error = Lang.get(lang, "usernameError")
					.replace("$MAX", '${main.config.maxLoginLength}');
				errors.push({
					type: "name",
					error: error
				});
			}

			final min = Main.MIN_PASSWORD_LENGTH;
			final max = Main.MAX_PASSWORD_LENGTH;
			if (password.length < min || password.length > max) {
				final error = Lang.get(lang, "passwordError")
					.replace("$MIN", '$min').replace("$MAX", '$max');
				errors.push({
					type: "password",
					error: error
				});
			}

			if (password != passwordConfirmation) {
				errors.push({
					type: "password",
					error: Lang.get(lang, "passwordsMismatchError")
				});
			}

			if (errors.length > 0) {
				res.status(400).json({success: false, errors: errors});
				return;
			}

			main.addAdmin(name, password);
			res.status(200).json({success: true});
		});
	}

	function getPath(dir:String, url:URL):String {
		final filePath = dir.urlDecode() + decodeURIComponent(url.pathname);
		if (!FileSystem.isDirectory(filePath)) return filePath;
		return Path.addTrailingSlash(filePath) + "index.html";
	}

	function readFileError(err:Dynamic, res:ServerResponse, filePath:String):Void {
		res.setHeader("content-type", getMimeType("html"));
		if (err.code == "ENOENT") {
			res.statusCode = 404;
			var rel = JsPath.relative(dir, filePath);
			res.end('File $rel not found.');
		} else {
			res.statusCode = 500;
			res.end('Error getting the file: $err.');
		}
	}

	function serveMedia(req:IncomingMessage, res:ServerResponse, filePath:String):Bool {
		if (!Fs.existsSync(filePath)) return false;
		var videoSize:Int = cast Fs.statSync(filePath).size;
		// use future content length to start playing it before uploaded
		if (uploadingFilesSizes.exists(filePath)) {
			videoSize = uploadingFilesSizes[filePath];
		}
		final rangeHeader:String = req.headers["range"];
		if (rangeHeader == null) {
			res.statusCode = 200;
			res.setHeader("content-length", '$videoSize');
			final videoStream = Fs.createReadStream(filePath);
			videoStream.pipe(res);
			res.on("error", () -> videoStream.destroy());
			res.on("close", () -> videoStream.destroy());
			return true;
		}
		final range = parseRangeHeader(rangeHeader, videoSize);
		final start = range.start;
		final end = range.end;
		final contentLength = end - start + 1;

		res.setHeader("content-range", 'bytes $start-$end/$videoSize');
		res.setHeader("content-length", '$contentLength');
		res.statusCode = 206; // partial content

		// check for last chunk cache for instant play while uploading
		final buffer = uploadingFilesLastChunks[filePath];
		if (buffer != null && end == videoSize - 1 && contentLength < buffer.byteLength) {
			final bufferStart = (buffer.byteLength - contentLength).limitMin(0);
			res.end(buffer.slice(bufferStart));
			return true;
		}

		// stream the video chunk to the client
		final videoStream = Fs.createReadStream(
			filePath,
			{start: start, end: end}
		);
		videoStream.pipe(res);
		res.on("error", () -> videoStream.destroy());
		res.on("close", () -> videoStream.destroy());
		return true;
	}

	function parseRangeHeader(rangeHeader:String, videoSize:Int):{start:Int, end:Int} {
		final ranges = ~/[-=]/g.split(rangeHeader);
		var start = Std.parseInt(ranges[1]);
		if (Utils.isOutOfRange(start, 0, videoSize - 1)) start = 0;
		var end = Std.parseInt(ranges[2]);
		if (end == null) end = start + CHUNK_SIZE;
		if (Utils.isOutOfRange(end, start, videoSize - 1)) end = videoSize - 1;
		return {
			start: start,
			end: end
		};
	}

	function isMediaExtension(ext:String):Bool {
		return ext == "mp4" || ext == "webm" || ext == "mp3" || ext == "wav";
	}

	final matchLang = ~/^[A-z]+/;
	final matchVarString = ~/\${([A-z_]+)}/g;

	function localizeHtml(data:String, lang:String):String {
		if (lang != null && matchLang.match(lang)) {
			lang = matchLang.matched(0);
		} else lang = "en";
		data = matchVarString.map(data, (regExp) -> {
			final key = regExp.matched(1);
			return Lang.get(lang, key);
		});
		return data;
	}

	function proxyUrl(req:IncomingMessage, res:ServerResponse):Bool {
		final url = req.url.replace("/proxy?url=", "");
		final proxy = proxyRequest(url, req, res, proxyRes -> {
			final url = proxyRes.headers["location"] ?? return false;
			final proxy2 = proxyRequest(url, req, res, proxyRes -> false);
			if (proxy2 == null) {
				res.end('Proxy error: multiple redirects for url $url');
				return true;
			}
			req.pipe(proxy2);
			return true;
		});
		if (proxy == null) return false;
		req.pipe(proxy);
		return true;
	}

	function proxyRequest(
		url:String,
		req:IncomingMessage,
		res:ServerResponse,
		cancelProxyRequest:(proxyRes:IncomingMessage) -> Bool
	):Null<ClientRequest> {
		final url = try {
			new URL(safeDecodeURI(url));
		} catch (e) {
			return null;
		}
		if (url.host == req.headers["host"]) return null;
		final options = {
			host: url.hostname,
			port: Std.parseInt(url.port),
			path: url.pathname + url.search,
			method: req.method
		};
		req.headers["referer"] = url.toString();
		req.headers["host"] = url.hostname;
		final request = url.protocol == "https:" ? Https.request : Http.request;
		final proxy = request(options, proxyRes -> {
			if (cancelProxyRequest(proxyRes)) return;
			proxyRes.headers["content-type"] = "application/octet-stream";
			res.writeHead(proxyRes.statusCode, proxyRes.headers);
			proxyRes.pipe(res);
		});
		proxy.on("error", err -> {
			res.end('Proxy error: ${url.href}');
		});
		return proxy;
	}

	function isChildOf(parent:String, child:String):Bool {
		final rel = JsPath.relative(parent, child);
		return rel.length > 0 && !rel.startsWith("..") && !JsPath.isAbsolute(rel);
	}

	function getMimeType(ext:String):String {
		return mimeTypes[ext] ?? return "application/octet-stream";
	}

	final ctrlCharacters = ~/[\u0000-\u001F\u007F-\u009F\u2000-\u200D\uFEFF]/g;

	function safeDecodeURI(data:String):String {
		try {
			data = decodeURI(data);
		} catch (err) {
			data = "";
		}
		data = ctrlCharacters.replace(data, "");
		return data;
	}

	inline function decodeURI(data:String):String {
		return js.Syntax.code("decodeURI({0})", data);
	}

	inline function decodeURIComponent(data:String):String {
		return js.Syntax.code("decodeURIComponent({0})", data);
	}

	// Handle emote API endpoints
	function handleEmoteApiRequest(req:IncomingMessage, res:ServerResponse, url:URL):Void {
		// Set JSON Content-Type and CORS headers
		res.setHeader("Content-Type", "application/json");
		res.setHeader("Access-Control-Allow-Origin", "*");
		res.setHeader("Access-Control-Allow-Methods", "GET");
		res.setHeader("Access-Control-Allow-Headers", "Content-Type");
		res.setHeader("Cache-Control", "max-age=300"); // 5 minutes caching

		// Extract path segments from URL
		final pathSegments = url.pathname.split("/").filter(s -> s.length > 0);

		// Check the path format and handle the request
		if (pathSegments.length < 4 || pathSegments[0] != "api"
			|| pathSegments[1] != "emotes") {
			// Provide API documentation for the index route
			if (pathSegments.length == 2 && pathSegments[0] == "api"
				&& pathSegments[1] == "emotes") {
				res.end(Json.stringify({
					"global": "/api/emotes/global/<provider>",
					"channel": "/api/emotes/channel/<username>/<provider>",
					"providers": ["twitch", "7tv", "bttv", "ffz", "all"]
				}));
				return;
			}

			// Invalid format
			res.statusCode = 404;
			res.end(Json.stringify({
				status_code: 404,
				message: "Page not found. Valid routes are /api/emotes/global/<provider> and /api/emotes/channel/<username>/<provider>"
			}));
			return;
		}

		final requestType = pathSegments[2];

		// Handle global emotes
		if (requestType == "global") {
			final provider = pathSegments[3];
			if (!["twitch", "7tv", "bttv", "ffz", "all"].contains(provider)) {
				res.statusCode = 404;
				res.end(Json.stringify({
					status_code: 404,
					message: "Invalid provider. Valid providers are: twitch, 7tv, bttv, ffz, all"
				}));
				return;
			}
			handleGlobalEmotesRequest(res, provider);
			return;
		}

		// Handle channel emotes
		if (requestType == "channel" && pathSegments.length >= 5) {
			final username = pathSegments[3];
			final provider = pathSegments[4];
			if (!["twitch", "7tv", "bttv", "ffz", "all"].contains(provider)) {
				res.statusCode = 404;
				res.end(Json.stringify({
					status_code: 404,
					message: "Invalid provider. Valid providers are: twitch, 7tv, bttv, ffz, all"
				}));
				return;
			}
			handleChannelEmotesRequest(res, username, provider);
			return;
		}

		// Invalid request
		res.statusCode = 404;
		res.end(Json.stringify({
			status_code: 404,
			message: "Invalid request"
		}));
	}

	// Handle global emotes request
	function handleGlobalEmotesRequest(res:ServerResponse, provider:String):Void {
		emotesAPI.getEmotes("_global", provider).then(emotes -> {
			res.end(Json.stringify(emotes));
		}).catchError(err -> {
			res.statusCode = 500;
			res.end(Json.stringify({
				status_code: 500,
				message: "Failed to fetch emotes: " + err
			}));
		});
	}

	// Handle channel emotes request
	function handleChannelEmotesRequest(res:ServerResponse, username:String, provider:String):Void {
		emotesAPI.getEmotes(username, provider).then(emotes -> {
			res.end(Json.stringify(emotes));
		}).catchError(err -> {
			res.statusCode = 500;
			res.end(Json.stringify({
				status_code: 500,
				message: "Failed to fetch emotes: " + err
			}));
		});
	}
}

// Emote API logic for handling emote fetching and caching
class EmotesAPI {
	// Cache duration in seconds
	static final CACHE_TIMEOUT = 300; // 5 minutes

	// Provider constants
	public static inline final TWITCH = 0;
	public static inline final SEVENTV = 1;
	public static inline final BTTV = 2;
	public static inline final FFZ = 3;

	// Cache for emotes
	private var emoteCache:Map<String, {data:Array<Emote>, timestamp:Float}> = [];

	public function new() {}

	// Main method to get emotes by provider
	public function getEmotes(login:String, provider:String):Promise<Array<Emote>> {
		// Check if we have cached results
		final cacheKey = '${login}_${provider}';
		final cachedData = emoteCache.get(cacheKey);

		if (cachedData != null
			&& (Date.now().getTime() - cachedData.timestamp) < CACHE_TIMEOUT * 1000) {
			// Return cached data if it's still valid
			return Promise.resolve(cachedData.data);
		}

		// Fetch fresh data
		return switch (provider) {
			case "twitch": getTwitchEmotes(login);
			case "7tv": get7TVEmotes(login);
			case "bttv": getBTTVEmotes(login);
			case "ffz": getFFZEmotes(login);
			case "all": getAllEmotes(login);
			default: Promise.resolve([]);
		}
	}

	// Search emotes across all providers
	public function searchEmotes(query:String, login:String = "_global"):Promise<Array<Emote>> {
		// Normalize the query for case-insensitive search
		final searchQuery = query.toLowerCase();

		if (searchQuery.length == 0) {
			return Promise.resolve([]);
		}

		// Get all emotes and filter them
		return getAllEmotes(login).then(function(emotes:Array<Emote>):Array<Emote> {
			// Filter emotes whose code contains the search query
			return emotes.filter(function(emote:Emote):Bool {
				return emote.code.toLowerCase().indexOf(searchQuery) >= 0;
			});
		});
	}

	// Fetch Twitch emotes
	private function getTwitchEmotes(login:String):Promise<Array<Emote>> {
		return new Promise<Array<Emote>>((resolve, reject) -> {
			final url = login == "_global" ? "https://api.twitchemotes.com/api/v4/channels/0" : 'https://api.twitchemotes.com/api/v4/channels/${login}';

			makeHttpRequest(url).then(data -> {
				try {
					final parsed = Json.parse(data);
					final emotes:Array<Emote> = [];

					if (parsed.emotes != null) {
						final emoteList:Array<Dynamic> = parsed.emotes;

						for (emoteData in emoteList) {
							final code = emoteData.code;
							final id = emoteData.id;

							final emote:Emote = {
								code: code,
								provider: TWITCH,
								zero_width: false,
								animated: false,
								urls: [
									{
										size: "1x",
										url: 'https://static-cdn.jtvnw.net/emoticons/v1/${id}/1.0'
									},
									{
										size: "2x",
										url: 'https://static-cdn.jtvnw.net/emoticons/v1/${id}/2.0'
									},
									{size: "3x", url: 'https://static-cdn.jtvnw.net/emoticons/v1/${id}/3.0'}
								]
							};

							emotes.push(emote);
						}
					}

					// Cache the results
					cacheEmotes(login + "_twitch", emotes);
					resolve(emotes);
				} catch (e) {
					reject('Error parsing Twitch emotes: ${e}');
				}
			}).catchError(err -> {
				reject('Failed to fetch Twitch emotes: ${err}');
			});
		});
	}

	// Fetch 7TV emotes
	private function get7TVEmotes(login:String):Promise<Array<Emote>> {
		return new Promise<Array<Emote>>((resolve, reject) -> {
			final url = login == "_global" ? "https://api.7tv.app/v2/emotes/global" : 'https://api.7tv.app/v2/users/${login}/emotes';

			makeHttpRequest(url).then(data -> {
				try {
					final parsed:Array<Dynamic> = Json.parse(data);
					final emotes:Array<Emote> = [];

					for (emoteData in parsed) {
						final code = emoteData.name;
						final id = emoteData.id;
						final animated = emoteData.animated != null ? emoteData.animated : false;

						final urls:Array<EmoteUrl> = [];
						final sizes = ["1x", "2x", "3x", "4x"];

						for (size in sizes) {
							urls.push({
								size: size,
								url: 'https://cdn.7tv.app/emote/${id}/${size}'
							});
						}

						final emote:Emote = {
							code: code,
							provider: SEVENTV,
							zero_width: emoteData.visibility_simple != null ? emoteData.visibility_simple.contains("ZERO_WIDTH") : false,
							animated: animated,
							urls: urls
						};

						emotes.push(emote);
					}

					// Cache the results
					cacheEmotes(login + "_7tv", emotes);
					resolve(emotes);
				} catch (e) {
					reject('Error parsing 7TV emotes: ${e}');
				}
			}).catchError(err -> {
				reject('Failed to fetch 7TV emotes: ${err}');
			});
		});
	}

	// Fetch BTTV emotes
	private function getBTTVEmotes(login:String):Promise<Array<Emote>> {
		return new Promise<Array<Emote>>((resolve, reject) -> {
			final url = login == "_global" ? "https://api.betterttv.net/3/cached/emotes/global" : 'https://api.betterttv.net/3/cached/users/twitch/${login}';

			makeHttpRequest(url).then(data -> {
				try {
					final emotes:Array<Emote> = [];
					final parsed:Dynamic = Json.parse(data);

					// Handle different response structures for global vs channel emotes
					final emoteList:Array<Dynamic> = [];
					if (login == "_global") {
						// Global emotes are directly an array
						if (Std.isOfType(parsed, Array)) {
							// Add each item individually instead of using spread operator
							final parsedArray:Array<Dynamic> = cast parsed;
							for (item in parsedArray) {
								emoteList.push(item);
							}
						}
					} else {
						// Channel emotes have channelEmotes and sharedEmotes arrays
						if (parsed.channelEmotes != null && Std.isOfType(parsed.channelEmotes, Array)) {
							// Add each item individually
							final channelEmotes:Array<Dynamic> = cast parsed.channelEmotes;
							for (item in channelEmotes) {
								emoteList.push(item);
							}
						}
						if (parsed.sharedEmotes != null && Std.isOfType(parsed.sharedEmotes, Array)) {
							// Add each item individually
							final sharedEmotes:Array<Dynamic> = cast parsed.sharedEmotes;
							for (item in sharedEmotes) {
								emoteList.push(item);
							}
						}
					}

					// Process each emote
					for (i in 0...emoteList.length) {
						final emoteData = emoteList[i];
						if (emoteData == null) continue;

						final code:String = emoteData.code;
						final id:String = emoteData.id;
						final animated:Bool = emoteData.imageType == "gif";

						if (code == null || id == null) continue;

						final emote:Emote = {
							code: code,
							provider: BTTV,
							zero_width: code.charAt(0) == '&',
							animated: animated,
							urls: [
								{
									size: "1x",
									url: 'https://cdn.betterttv.net/emote/${id}/1x'
								},
								{size: "2x", url: 'https://cdn.betterttv.net/emote/${id}/2x'},
								{size: "3x", url: 'https://cdn.betterttv.net/emote/${id}/3x'}
							]
						};

						emotes.push(emote);
					}

					// Cache the results
					cacheEmotes(login + "_bttv", emotes);
					resolve(emotes);
				} catch (e) {
					reject('Error parsing BTTV emotes: ${e}');
				}
			}).catchError(err -> {
				reject('Failed to fetch BTTV emotes: ${err}');
			});
		});
	}

	// Fetch FFZ emotes
	private function getFFZEmotes(login:String):Promise<Array<Emote>> {
		return new Promise<Array<Emote>>((resolve, reject) -> {
			final url = login == "_global" ? "https://api.frankerfacez.com/v1/set/global" : 'https://api.frankerfacez.com/v1/room/${login}';

			makeHttpRequest(url).then(data -> {
				try {
					final emotes:Array<Emote> = [];
					final parsed = Json.parse(data);

					// FFZ global emotes have a different structure than channel emotes
					final setIds:Array<String> = login == "_global" ? Reflect.fields(parsed.sets) : [Std.string(parsed.room.set)];

					for (setId in setIds) {
						final emoteSet = Reflect.field(parsed.sets, setId);
						final emoteList:Dynamic = emoteSet.emoticons;

						// Convert to Array and iterate safely
						if (Std.isOfType(emoteList, Array)) {
							final typedEmoteList:Array<Dynamic> = cast emoteList;
							for (i in 0...typedEmoteList.length) {
								final emoteData = typedEmoteList[i];
								if (emoteData == null) continue;

								final code = emoteData.name;
								final id = emoteData.id;

								final urls:Array<EmoteUrl> = [];

								// Parse URLs map
								final scales = Reflect.fields(emoteData.urls);
								for (scale in scales) {
									final urlValue = Reflect.field(emoteData.urls, scale);
									// Handle URL properly using Reflect
									urls.push({
										size: scale + "x",
										url: 'https://' + urlValue.replace("//", "")
									});
								}

								final emote:Emote = {
									code: code,
									provider: FFZ,
									zero_width: false, // FFZ doesn't have zero-width emotes
									animated: false, // FFZ doesn't have animated emotes
									urls: urls
								};

								emotes.push(emote);
							}
						}
					}

					// Cache the results
					cacheEmotes(login + "_ffz", emotes);
					resolve(emotes);
				} catch (e) {
					reject('Error parsing FFZ emotes: ${e}');
				}
			}).catchError(err -> {
				reject('Failed to fetch FFZ emotes: ${err}');
			});
		});
	}

	// Fetch emotes from all providers and combine them
	private function getAllEmotes(login:String):Promise<Array<Emote>> {
		final promises:Array<Promise<Array<Emote>>> = [
			getTwitchEmotes(login),
			get7TVEmotes(login),
			getBTTVEmotes(login),
			getFFZEmotes(login)
		];

		return Promise.all(promises).then(results -> {
			final allEmotes:Array<Emote> = [];
			for (emoteList in results) {
				for (emote in emoteList) {
					allEmotes.push(emote);
				}
			}

			// Cache the combined results
			cacheEmotes(login + "_all", allEmotes);
			return allEmotes;
		});
	}

	// Helper method to make HTTP requests
	private function makeHttpRequest(url:String):Promise<String> {
		return new Promise<String>((resolve, reject) -> {
			final parsedUrl = new URL(url);
			final options = {
				hostname: parsedUrl.hostname,
				path: parsedUrl.pathname + parsedUrl.search,
				headers: cast({
					'User-Agent': 'TuubiPlayer/1.0'
				} : DynamicAccess<haxe.extern.EitherType<String, Array<String>>>)
			};

			// Use the correct protocol module based on URL
			final request = parsedUrl.protocol == "https:" ? Https.request : Http.request;

			final req = request(options, (res) -> {
				if (res.statusCode >= 400) {
					reject('HTTP Error: ${res.statusCode}');
					return;
				}

				final chunks:Array<Buffer> = [];
				res.on('data', (chunk) -> {
					chunks.push(cast chunk);
				});

				res.on('end', () -> {
					final responseBody = Buffer.concat(chunks).toString();
					resolve(responseBody);
				});
			});

			req.on('error', (error) -> {
				reject('Request Error: $error');
			});

			req.end();
		});
	}

	// Helper method to cache emotes
	private function cacheEmotes(key:String, emotes:Array<Emote>):Void {
		emoteCache.set(key, {
			data: emotes,
			timestamp: Date.now().getTime()
		});
	}
}
