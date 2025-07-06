package client;

import haxe.Http;
import haxe.Json;

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
     * @param userName Optional user name for logging purposes
     * @param isRandomVideo Optional flag to indicate this is a random video search
     */
    public static function searchVideos(query:String, maxResults:Int = 20, callback:(videoIds:Array<String>) -> Void, ?userName:String, ?isRandomVideo:Bool):Void {
        trace('YouTube crawler: Searching for "$query" via server proxy');
        
        searchViaServerProxy(query, maxResults, callback, userName, isRandomVideo);
    }
    
    /**
     * Search using server-side proxy endpoint
     */
    static function searchViaServerProxy(query:String, maxResults:Int, callback:(videoIds:Array<String>) -> Void, ?userName:String, ?isRandomVideo:Bool):Void {
        final http = new Http("/api/youtube-search");
        http.setHeader("Content-Type", "application/json");
        
        final requestData = {
            query: query,
            maxResults: maxResults,
            userName: userName ?? "Unknown",
            method: "crawler",
            isRandomVideo: isRandomVideo ?? false
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
                    // Return empty array on error
                    callback([]);
                }
            } catch (e:Dynamic) {
                trace('YouTube crawler: Failed to parse server response: $e');
                callback([]);
            }
        };
        
        http.onError = function(error:String) {
            trace('YouTube crawler: Server request failed: $error');
            callback([]);
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
     * Get video metadata for a specific video ID
     * Note: Returns basic metadata since embeddability is checked during playback
     */
    public static function getVideoMetadata(videoId:String, callback:(metadata:VideoMetadata) -> Void):Void {
        trace('YouTube crawler: Getting metadata for video ID: $videoId');
        
        // Return basic metadata - embeddability will be validated during actual playback
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