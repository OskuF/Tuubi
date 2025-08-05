package client;

import haxe.Http;
import haxe.Json;
import haxe.Timer;
using StringTools;

/**
 * Content type classification for anime entries
 */
private enum ContentType {
	MainSeries;
	Season;
	Movie;
	Special;
	Recap;
}

/**
 * Service for translating anime titles to English using the AniList GraphQL API
 * Used to improve AniSkip database matching for non-English anime titles
 */
class AnimeTranslationService {
	// Cache for translated titles (original title -> English title)
	static var titleTranslationCache:Map<String, String> = new Map();
	
	// Cache timestamps for expiration (7 days)
	static var cacheTimestamps:Map<String, Float> = new Map();
	
	// Cache expiration time (7 days in milliseconds)
	static final CACHE_EXPIRATION = 7 * 24 * 60 * 60 * 1000;
	
	// AniList GraphQL API endpoint
	static final ANILIST_API_URL = "https://graphql.anilist.co";
	
	/**
	 * Get multiple title variations for better database compatibility
	 * @param originalTitle The original anime title
	 * @param callback Function called with primary title and fallback variations
	 */
	public static function getTitleVariations(originalTitle:String, callback:(primaryTitle:String, variations:Array<String>)->Void):Void {
		if (originalTitle == null || originalTitle.trim() == "") {
			callback(originalTitle, []);
			return;
		}
		
		final trimmedTitle = originalTitle.trim();
		
		// For now, use existing translateToEnglish and generate variations
		translateToEnglish(trimmedTitle, (primaryTitle:String) -> {
			final variations = generateTitleVariations(primaryTitle);
			trace('Title variations for "$originalTitle": primary="$primaryTitle", variations=[${variations.join(", ")}]');
			callback(primaryTitle, variations);
		});
	}
	
	/**
	 * Translate an anime title to English using AniList API (legacy function)
	 * @param originalTitle The original anime title (may be in Japanese, Korean etc.)
	 * @param callback Function called with the English title (or original if translation fails)
	 */
	public static function translateToEnglish(originalTitle:String, callback:String->Void):Void {
		if (originalTitle == null || originalTitle.trim() == "") {
			callback(originalTitle);
			return;
		}
		
		final trimmedTitle = originalTitle.trim();
		
		// Check cache first
		if (titleTranslationCache.exists(trimmedTitle)) {
			final cachedTimestamp = cacheTimestamps.get(trimmedTitle);
			final now = Date.now().getTime();
			
			// Check if cache entry is still valid
			if (cachedTimestamp != null && (now - cachedTimestamp) < CACHE_EXPIRATION) {
				final cachedTitle = titleTranslationCache.get(trimmedTitle);
				trace('Cache hit for anime title: "$trimmedTitle" -> "$cachedTitle"');
				callback(cachedTitle);
				return;
			} else {
				// Cache expired, remove entry
				titleTranslationCache.remove(trimmedTitle);
				cacheTimestamps.remove(trimmedTitle);
				trace('Cache expired for anime title: "$trimmedTitle"');
			}
		}
		
		// Search AniList for the anime
		searchAniListAnime(trimmedTitle, callback);
	}
	
	/**
	 * Search for anime on AniList and extract English title
	 */
	static function searchAniListAnime(searchTitle:String, callback:String->Void):Void {
		trace('Searching AniList for anime title: "$searchTitle"');
		
		final query = {
			query: 'query ($$search: String!) {
				Page(page: 1, perPage: 5) {
					media(search: $$search, type: ANIME) {
						id
						title {
							romaji
							english
							native
						}
						synonyms
						startDate {
							year
						}
					}
				}
			}',
			variables: {
				search: searchTitle
			}
		};
		
		final http = new Http(ANILIST_API_URL);
		http.addHeader("Content-Type", "application/json");
		http.addHeader("Accept", "application/json");
		
		http.setPostData(Json.stringify(query));
		
		http.onData = text -> {
			try {
				final response:Dynamic = Json.parse(text);
				
				if (response.errors != null) {
					trace('AniList GraphQL errors: ${Json.stringify(response.errors)}');
					fallbackToOriginal(searchTitle, callback);
					return;
				}
				
				if (response.data != null && response.data.Page != null && response.data.Page.media != null) {
					final mediaList:Array<Dynamic> = response.data.Page.media;
					
					if (mediaList.length == 0) {
						trace('No anime found on AniList for: "$searchTitle"');
						fallbackToOriginal(searchTitle, callback);
						return;
					}
					
					// Find the best matching anime
					final bestMatch = findBestMatch(searchTitle, mediaList);
					if (bestMatch != null) {
						final englishTitle = extractEnglishTitle(bestMatch);
						
						if (englishTitle != null && englishTitle != searchTitle) {
							// Cache the translation
							cacheTranslation(searchTitle, englishTitle);
							trace('Successfully translated: "$searchTitle" -> "$englishTitle"');
							callback(englishTitle);
						} else {
							trace('No suitable English title found for: "$searchTitle"');
							fallbackToOriginal(searchTitle, callback);
						}
					} else {
						trace('No good match found for: "$searchTitle"');
						fallbackToOriginal(searchTitle, callback);
					}
				} else {
					trace('Invalid response structure from AniList');
					fallbackToOriginal(searchTitle, callback);
				}
				
			} catch (e:Dynamic) {
				trace('Error parsing AniList response: $e');
				fallbackToOriginal(searchTitle, callback);
			}
		};
		
		http.onError = msg -> {
			trace('AniList API error: $msg');
			fallbackToOriginal(searchTitle, callback);
		};
		
		http.request();
	}
	
	/**
	 * Normalize titles for comparison (handle spacing, punctuation differences)
	 */
	static function normalizeForComparison(title:String):String {
		return StringTools.trim(title.toLowerCase())
			.replace(" ", "")
			.replace(".", "")
			.replace(":", "")
			.replace("-", "")
			.replace("×", "x")
			.replace("!", "");
	}
	
	/**
	 * Check if two normalized titles are near-exact matches
	 */
	static function isNearExactMatch(search:String, candidate:String):Bool {
		// Remove all spaces and punctuation for comparison
		final searchClean = search.replace(" ", "").replace(".", "").replace(":", "").replace("-", "");
		final candidateClean = candidate.replace(" ", "").replace(".", "").replace(":", "").replace("-", "");
		
		if (searchClean == candidateClean) return true;
		
		// Check if one is a clean subset of the other (within reasonable length difference)
		final lengthRatio = Math.min(searchClean.length, candidateClean.length) / Math.max(searchClean.length, candidateClean.length);
		if (lengthRatio > 0.9) {
			return searchClean.indexOf(candidateClean) != -1 || candidateClean.indexOf(searchClean) != -1;
		}
		
		return false;
	}
	
	/**
	 * Find the best matching anime from search results
	 */
	static function findBestMatch(searchTitle:String, mediaList:Array<Dynamic>):Dynamic {
		if (mediaList.length == 0) return null;
		
		final searchLower = StringTools.trim(searchTitle.toLowerCase());
		var bestMatch:Dynamic = null;
		var bestScore = 0.0;
		
		trace('Finding best match for: "$searchTitle" among ${mediaList.length} results');
		
		for (media in mediaList) {
			var score = 0.0;
			final contentType = detectContentType(media);
			final title = media.title;
			
			if (title == null) continue;
			
			// Check for exact and near-exact matches first (highest priority)
			var hasExactMatch = false;
			if (title.english != null) {
				final englishNormalized = normalizeForComparison(title.english);
				final searchNormalized = normalizeForComparison(searchTitle);
				
				if (englishNormalized == searchNormalized) {
					score += 20.0; // Very high score for exact English match
					hasExactMatch = true;
					trace('  Exact English match: "${title.english}"');
				} else if (isNearExactMatch(searchNormalized, englishNormalized)) {
					score += 15.0; // High score for near-exact match
					hasExactMatch = true;
					trace('  Near-exact English match: "${title.english}"');
				}
			}
			if (title.romaji != null && !hasExactMatch) {
				final romajiNormalized = normalizeForComparison(title.romaji);
				final searchNormalized = normalizeForComparison(searchTitle);
				
				if (romajiNormalized == searchNormalized) {
					score += 18.0; // Very high score for exact romaji match
					hasExactMatch = true;
					trace('  Exact romaji match: "${title.romaji}"');
				} else if (isNearExactMatch(searchNormalized, romajiNormalized)) {
					score += 13.0; // High score for near-exact match
					hasExactMatch = true;
					trace('  Near-exact romaji match: "${title.romaji}"');
				}
			}
			
			// If no exact match, calculate similarity scores
			if (!hasExactMatch) {
				if (title.english != null) {
					final englishNormalized = StringTools.trim(title.english.toLowerCase());
					final similarity = calculateTitleSimilarity(searchLower, englishNormalized);
					score += similarity * 2.0; // Weight English titles highly
					trace('  English similarity: "${title.english}" = ${similarity}');
				}
				if (title.romaji != null) {
					final romajiNormalized = StringTools.trim(title.romaji.toLowerCase());
					final similarity = calculateTitleSimilarity(searchLower, romajiNormalized);
					score += similarity * 1.8; // Weight romaji slightly less
					trace('  Romaji similarity: "${title.romaji}" = ${similarity}');
				}
				if (title.native != null) {
					final nativeNormalized = StringTools.trim(title.native.toLowerCase());
					final similarity = calculateTitleSimilarity(searchLower, nativeNormalized);
					score += similarity * 0.5; // Much lower weight for native titles
				}
				
				// Check synonyms with lower weight
				if (media.synonyms != null) {
					final synonyms:Array<Dynamic> = media.synonyms;
					for (synonym in synonyms) {
						if (synonym != null) {
							final synonymStr = Std.string(synonym);
							final synonymNormalized = StringTools.trim(synonymStr.toLowerCase());
							if (synonymNormalized == searchLower) {
								score += 8.0; // High score for exact synonym match
								hasExactMatch = true;
								trace('  Exact synonym match: "$synonymStr"');
							} else {
								final similarity = calculateTitleSimilarity(searchLower, synonymNormalized);
								score += similarity * 1.0;
							}
						}
					}
				}
			}
			
			// Apply content type penalties
			switch (contentType) {
				case MainSeries: 
					score += 1.0; // Bonus for main series
					trace('  Main series bonus applied');
				case Season: 
					score += 0.5; // Small bonus for seasons
				case Movie: 
					score -= 2.0; // Penalty for movies
					trace('  Movie penalty applied');
				case Special: 
					score -= 1.5; // Penalty for specials
					trace('  Special penalty applied');
				case Recap: 
					score -= 3.0; // Heavy penalty for recap/compilation
					trace('  Recap penalty applied');
			}
			
			// Year-based scoring (prefer original series)
			if (media.startDate != null && media.startDate.year != null) {
				final year:Int = media.startDate.year;
				// For main series, prefer earlier entries (original series)
				if (contentType == MainSeries && year >= 2000 && year <= 2020) {
					score += 0.3; // Bonus for established series
				}
				// Small penalty for very recent derivatives
				if ((contentType == Movie || contentType == Special || contentType == Recap) && year >= 2024) {
					score -= 0.2;
				}
			}
			
			final finalScore = Math.max(0, score); // Ensure non-negative
			trace('  Final score for "${getDisplayTitle(media)}": ${finalScore} (type: ${contentType})');
			
			if (finalScore > bestScore) {
				bestScore = finalScore;
				bestMatch = media;
			}
		}
		
		trace('Best match selected: "${getDisplayTitle(bestMatch)}" with score ${bestScore}');
		
		// Only return match if score is reasonably good
		return bestScore > 2.0 ? bestMatch : null;
	}
	
	/**
	 * Detect the content type of an anime entry
	 */
	static function detectContentType(media:Dynamic):ContentType {
		if (media == null || media.title == null) return MainSeries;
		
		final title = media.title;
		var allTitles:Array<String> = [];
		
		// Add main titles
		if (title.english != null) allTitles.push(title.english);
		if (title.romaji != null) allTitles.push(title.romaji);
		if (title.native != null) allTitles.push(title.native);
		
		// Add synonyms if they exist
		if (media.synonyms != null) {
			final synonyms:Array<Dynamic> = media.synonyms;
			for (synonym in synonyms) {
				if (synonym != null) {
					allTitles.push(Std.string(synonym));
				}
			}
		}
		
		for (titleStr in allTitles) {
			if (titleStr == null) continue;
			final titleLower = titleStr.toLowerCase();
			
			// Check for recap/compilation indicators
			if (titleLower.indexOf("recap") != -1 || 
				titleLower.indexOf("compilation") != -1 || 
				titleLower.indexOf("mission recon") != -1 ||
				titleLower.indexOf("総集編") != -1) {
				return Recap;
			}
			
			// Check for movie indicators
			if (titleLower.indexOf("movie") != -1 || 
				titleLower.indexOf("film") != -1 ||
				titleLower.indexOf("劇場版") != -1) {
				return Movie;
			}
			
			// Check for special indicators
			if (titleLower.indexOf("special") != -1 || 
				titleLower.indexOf("ova") != -1 || 
				titleLower.indexOf("ona") != -1 ||
				titleLower.indexOf("day off") != -1 ||
				titleLower.indexOf("minute!") != -1 ||
				titleLower.indexOf("mini") != -1 ||
				titleLower.indexOf("chibi") != -1 ||
				titleLower.indexOf("petit") != -1 ||
				titleLower.indexOf("short") != -1) {
				return Special;
			}
			
			// Check for season indicators
			if (titleLower.indexOf("season") != -1 || 
				titleLower.indexOf("2nd") != -1 || 
				titleLower.indexOf("3rd") != -1 ||
				titleLower.indexOf("第") != -1 && titleLower.indexOf("期") != -1) {
				return Season;
			}
		}
		
		return MainSeries;
	}
	
	/**
	 * Get display title for logging
	 */
	static function getDisplayTitle(media:Dynamic):String {
		if (media == null || media.title == null) return "null";
		final title = media.title;
		return title.english ?? title.romaji ?? title.native ?? "unknown";
	}
	
	/**
	 * Calculate similarity between two anime titles with length penalties
	 */
	static function calculateTitleSimilarity(searchTitle:String, candidateTitle:String):Float {
		if (searchTitle == candidateTitle) return 1.0;
		if (searchTitle.length == 0 || candidateTitle.length == 0) return 0.0;
		
		var score = 0.0;
		
		// Exact substring match (high score)
		if (searchTitle.indexOf(candidateTitle) != -1 || candidateTitle.indexOf(searchTitle) != -1) {
			score = 0.9;
		} else {
			// Word-based similarity
			final searchWords = searchTitle.split(" ");
			final candidateWords = candidateTitle.split(" ");
			var matchingWords:Float = 0;
			var totalWords:Float = Math.max(searchWords.length, candidateWords.length);
			
			for (searchWord in searchWords) {
				if (searchWord.length <= 2) continue; // Skip short words
				
				for (candidateWord in candidateWords) {
					if (candidateWord.length <= 2) continue;
					
					// Exact word match
					if (searchWord == candidateWord) {
						matchingWords += 1.0;
						break;
					}
					// Partial word match for longer words
					else if (searchWord.length > 4 && candidateWord.length > 4) {
						if (searchWord.indexOf(candidateWord) != -1 || candidateWord.indexOf(searchWord) != -1) {
							matchingWords += 0.7;
							break;
						}
					}
				}
			}
			
			score = matchingWords / totalWords;
		}
		
		// Apply length penalty for significantly different lengths
		final lengthRatio = Math.min(searchTitle.length, candidateTitle.length) / Math.max(searchTitle.length, candidateTitle.length);
		if (lengthRatio < 0.5) {
			score *= 0.7; // Penalty for very different lengths
		} else if (lengthRatio < 0.8) {
			score *= 0.9; // Small penalty for moderately different lengths
		}
		
		// Bonus for shorter candidate titles when they match well (prefer concise titles)
		if (score > 0.7 && candidateTitle.length < searchTitle.length) {
			score += 0.1;
		}
		
		return Math.min(1.0, score);
	}
	
	/**
	 * Extract the best English title from AniList media object
	 */
	static function extractEnglishTitle(media:Dynamic):String {
		if (media == null || media.title == null) return null;
		
		final title = media.title;
		
		// Prefer official English title
		if (title.english != null && title.english.trim() != "") {
			return title.english.trim();
		}
		
		// Fall back to romaji if no English title
		if (title.romaji != null && title.romaji.trim() != "") {
			return title.romaji.trim();
		}
		
		return null;
	}
	
	/**
	 * Generate common title variations for different database formats
	 */
	static function generateTitleVariations(title:String):Array<String> {
		if (title == null || title.trim() == "") return [];
		
		var variations:Array<String> = [];
		final baseTitle = title.trim();
		
		// Add the original title
		variations.push(baseTitle);
		
		// Common spacing variations
		if (baseTitle.indexOf("No.") != -1) {
			variations.push(baseTitle.replace("No.", "No. ")); // "No.8" -> "No. 8"
			variations.push(baseTitle.replace("No.", "#"));     // "No.8" -> "#8"
		}
		if (baseTitle.indexOf("No. ") != -1) {
			variations.push(baseTitle.replace("No. ", "No."));  // "No. 8" -> "No.8"
			variations.push(baseTitle.replace("No. ", "#"));    // "No. 8" -> "#8"
		}
		
		// Number/symbol variations
		if (baseTitle.indexOf("#") != -1) {
			variations.push(baseTitle.replace("#", "No. "));    // "#8" -> "No. 8"
			variations.push(baseTitle.replace("#", "No."));     // "#8" -> "No.8"
		}
		
		// Colon variations
		if (baseTitle.indexOf(":") != -1) {
			variations.push(baseTitle.replace(":", " -"));      // "Title: Subtitle" -> "Title - Subtitle"
			variations.push(baseTitle.replace(":", ""));        // "Title: Subtitle" -> "Title Subtitle"
		}
		
		// Dash variations
		if (baseTitle.indexOf(" - ") != -1) {
			variations.push(baseTitle.replace(" - ", ": "));    // "Title - Subtitle" -> "Title: Subtitle"
			variations.push(baseTitle.replace(" - ", " "));     // "Title - Subtitle" -> "Title Subtitle"
		}
		
		// Punctuation variations
		variations.push(baseTitle.replace("!", ""));           // Remove exclamation marks
		variations.push(baseTitle.replace("×", "x"));          // "×" -> "x"
		variations.push(baseTitle.replace("x", "×"));          // "x" -> "×"
		
		// Remove duplicates
		var uniqueVariations:Array<String> = [];
		for (variation in variations) {
			final trimmed = variation.trim();
			if (trimmed != "" && uniqueVariations.indexOf(trimmed) == -1) {
				uniqueVariations.push(trimmed);
			}
		}
		
		return uniqueVariations;
	}
	
	/**
	 * Cache a successful translation
	 */
	static function cacheTranslation(originalTitle:String, englishTitle:String):Void {
		titleTranslationCache.set(originalTitle, englishTitle);
		cacheTimestamps.set(originalTitle, Date.now().getTime());
		trace('Cached translation: "$originalTitle" -> "$englishTitle"');
	}
	
	/**
	 * Fallback to original title when translation fails
	 */
	static function fallbackToOriginal(originalTitle:String, callback:String->Void):Void {
		// Cache the "no translation" result to avoid repeated API calls
		cacheTranslation(originalTitle, originalTitle);
		callback(originalTitle);
	}
	
	/**
	 * Clear the translation cache (useful for testing)
	 */
	public static function clearCache():Void {
		var count = 0;
		for (key in titleTranslationCache.keys()) count++;
		trace('Clearing anime translation cache ($count entries)');
		titleTranslationCache.clear();
		cacheTimestamps.clear();
	}
	
	/**
	 * Get cache statistics
	 */
	public static function getCacheInfo():{size:Int, oldestEntry:Float} {
		var size = 0;
		var oldestTimestamp = Date.now().getTime();
		
		for (key in titleTranslationCache.keys()) {
			size++;
			final timestamp = cacheTimestamps.get(key);
			if (timestamp != null && timestamp < oldestTimestamp) {
				oldestTimestamp = timestamp;
			}
		}
		
		return {size: size, oldestEntry: oldestTimestamp};
	}
}