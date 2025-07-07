package server;

import Types.UploadResponse;
import haxe.io.Path;
import js.node.Buffer;
import js.node.Fs.Fs;
import js.node.Http;
import js.node.Https;
import js.node.Path as JsPath;
import js.node.http.ClientRequest;
import js.node.http.IncomingMessage;
import js.node.http.ServerResponse;
import js.node.url.URL;
import json2object.ErrorUtils;
import json2object.JsonParser;
import server.cache.Cache;
import sys.FileSystem;
import tools.HttpServerTools;

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

	public function new(main:Main, config:HttpServerConfig):Void {
		this.main = main;
		dir = config.dir;
		customDir = config.customDir;
		allowLocalRequests = config.allowLocalRequests;
		cache = config.cache;
		allowedFileTypes = main.config.allowedFileTypes;

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

		if (cache != null && req.method == "POST") {
			switch url.pathname {
				case "/upload-last-chunk":
					uploadFileLastChunk(req, res);
				case "/upload":
					uploadFile(req, res);
				case "/setup":
					finishSetup(req, res);
				case "/api/youtube-search":
					handleYouTubeSearch(req, res);
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

	function handleYouTubeSearch(req:IncomingMessage, res:ServerResponse):Void {
		var body = "";
		
		req.on("data", chunk -> {
			body += chunk;
		});
		
		req.on("end", () -> {
			try {
				final data = haxe.Json.parse(body);
				final query:String = data.query;
				final maxResults:Int = data.maxResults ?? 20;
				final userName:String = data.userName ?? "Unknown";
				final method:String = data.method ?? "crawler";
				final isRandomVideo:Bool = data.isRandomVideo ?? false;
				
				if (query == null || query.trim() == "") {
					HttpServerTools.status(res, 400);
					HttpServerTools.json(res, {
						success: false,
						error: "Query parameter is required"
					});
					return;
				}
				
				// Enhanced logging for random video requests
				if (isRandomVideo) {
					trace('[RANDOM VIDEO] User: "$userName" | Query: "$query" | Method: $method | Status: SEARCHING...');
				} else {
					trace('YouTube Search API: Searching for "$query" with max results $maxResults');
				}
				
				// Perform YouTube search using the npm package
				untyped __js__("
					var youtubeSearch = require('youtube-search-without-api-key');
					var HttpServerTools = tools_HttpServerTools;
					var userName = {3};
					var method = {4};
					var isRandomVideo = {5};
					
					youtubeSearch.search({0}, {limit: {1}}).then(function(results) {
						var videoIds = [];
						var videoTitles = [];
						var seenVideoIds = new Set(); // Deduplication using Set
						
						for (var i = 0; i < results.length; i++) {
							var result = results[i];
							// Extract video ID from nested structure: result.id.videoId
							var videoId = result.id?.videoId || result.videoId || result.url?.split('v=')[1]?.split('&')[0];
							if (videoId && typeof videoId === 'string' && !seenVideoIds.has(videoId)) {
								seenVideoIds.add(videoId); // Track this video ID to prevent duplicates
								videoIds.push(videoId);
								videoTitles.push(result.title || 'Unknown Title');
							}
						}
						
						if (isRandomVideo && videoIds.length > 0) {
							// Log detailed result for random video requests
							var firstVideoTitle = videoTitles[0] || 'Unknown';
							var firstVideoId = videoIds[0] || 'Unknown';
							console.log('[RANDOM VIDEO] User: \"' + userName + '\" | Query: \"' + {0} + '\" | Method: ' + method + ' | Result: \"' + firstVideoTitle + '\" (' + firstVideoId + ') | Count: ' + videoIds.length + ' | Status: SUCCESS');
						} else if (isRandomVideo) {
							console.log('[RANDOM VIDEO] User: \"' + userName + '\" | Query: \"' + {0} + '\" | Method: ' + method + ' | Result: No videos found | Status: FAILED');
						} else {
							console.log('YouTube Search API: Found ' + videoIds.length + ' video IDs');
						}
						
						HttpServerTools.status({2}, 200);
						HttpServerTools.json({2}, {
							success: true,
							videoIds: videoIds,
							count: videoIds.length
						});
					}).catch(function(error) {
						if (isRandomVideo) {
							console.log('[RANDOM VIDEO] User: \"' + userName + '\" | Query: \"' + {0} + '\" | Method: ' + method + ' | Error: ' + error + ' | Status: FAILED');
						} else {
							console.log('YouTube Search API error:', error);
						}
						HttpServerTools.status({2}, 500);
						HttpServerTools.json({2}, {
							success: false,
							error: 'Search request failed'
						});
					});
				", query, maxResults, res, userName, method, isRandomVideo);
				
			} catch (e:Dynamic) {
				trace('[RANDOM VIDEO] Parse error in request body: $e');
				HttpServerTools.status(res, 400);
				HttpServerTools.json(res, {
					success: false,
					error: "Invalid request format"
				});
			}
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
}
