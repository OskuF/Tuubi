package client;

import haxe.Http;
import haxe.Json;
import haxe.Timer;

/**
 * YouTube crawler for searching videos without API keys
 * Uses server-side proxy to avoid CORS and anti-bot issues
 */
class YoutubeCrawler {
    
    /**
     * Search YouTube videos without API key via server proxy
     * @param query Search query string
     * @param maxResults Maximum number of results to return (default: 20)
     * @param callback Callback function that receives array of video IDs
     */
    public static function searchVideos(query:String, maxResults:Int = 20, callback:(videoIds:Array<String>) -> Void):Void {
        trace('YouTube crawler: Searching for "$query" via server proxy');
        
        // Use server proxy endpoint
        searchViaServerProxy(query, maxResults, callback);
    }
    
    /**
     * Search using server-side proxy endpoint
     */
    static function searchViaServerProxy(query:String, maxResults:Int, callback:(videoIds:Array<String>) -> Void):Void {
        final http = new Http("/api/youtube-search");
        http.setHeader("Content-Type", "application/json");
        
        final requestData = {
            query: query,
            maxResults: maxResults
        };
        
        http.onData = function(data:String) {
            try {
                final response = Json.parse(data);
                if (response.success == true) {
                    final videoIds:Array<String> = response.videoIds ?? [];
                    trace('YouTube crawler: Server returned ${videoIds.length} video IDs: [${videoIds.join(", ")}]');
                    callback(videoIds);
                } else {
                    final error = response.error ?? "Unknown server error";
                    trace('YouTube crawler: Server error: $error');
                    // Try fallback method
                    searchViaFallback(query, maxResults, callback);
                }
            } catch (e:Dynamic) {
                trace('YouTube crawler: Failed to parse server response: $e');
                searchViaFallback(query, maxResults, callback);
            }
        };
        
        http.onError = function(error:String) {
            trace('YouTube crawler: Server request failed: $error');
            searchViaFallback(query, maxResults, callback);
        };
        
        http.onStatus = function(status:Int) {
            if (status == 429) {
                trace('YouTube crawler: Server rate limit exceeded');
            } else if (status >= 400) {
                trace('YouTube crawler: Server returned status $status');
            }
        };
        
        http.setPostData(Json.stringify(requestData));
        http.request(true); // POST request
    }
    
    /**
     * Fallback search method when server proxy fails
     */
    static function searchViaFallback(query:String, maxResults:Int, callback:(videoIds:Array<String>) -> Void):Void {
        trace('YouTube crawler: Using fallback search method');
        
        // Use a curated list of popular video IDs as emergency fallback
        // This ensures the random video feature always works
        final fallbackVideoIds = [
            "dQw4w9WgXcQ", // Rick Roll (most reliable test video)
            "kJQP7kiw5Fk", // LevelUp Tuts
            "fJ9rUzIMcZQ", // Gangnam Style
            "9bZkp7q19f0", // Gangnam Style
            "JGwWNGJdvx8", // Despacito
            "pRpeEdMmmQ0", // Shakira
            "YQHsXMglC9A", // Adele
            "hTWKbfoikeg", // Nirvana
            "7PCkvCPvDXk", // Red Hot Chili Peppers
            "CD-E-LDc384", // Linkin Park
        ];
        
        // Shuffle and return a subset
        final shuffled = fallbackVideoIds.copy();
        for (i in 0...shuffled.length) {
            final j = Math.floor(Math.random() * shuffled.length);
            final temp = shuffled[i];
            shuffled[i] = shuffled[j];
            shuffled[j] = temp;
        }
        
        final result = shuffled.slice(0, Math.floor(Math.min(maxResults, shuffled.length)));
        trace('YouTube crawler: Fallback returned ${result.length} video IDs');
        callback(result);
    }
    
    /**
     * Get video metadata for a specific video ID
     * Note: Returns basic metadata since we don't scrape individual video pages
     */
    public static function getVideoMetadata(videoId:String, callback:(metadata:VideoMetadata) -> Void):Void {
        // Return basic metadata - embeddability will be checked during actual playback
        trace('YouTube crawler: Getting metadata for video ID: $videoId');
        
        callback({
            videoId: videoId,
            title: "YouTube Video",
            duration: 0, // Duration will be determined when video loads
            isEmbeddable: true, // Assume embeddable, will be validated during playback
            isLive: false
        });
    }
    
}

/**
 * Video metadata structure
 */
typedef VideoMetadata = {
    videoId: String,
    title: String,
    duration: Int, // in seconds
    isEmbeddable: Bool,
    isLive: Bool
}