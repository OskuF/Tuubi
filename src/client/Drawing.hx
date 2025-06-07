package client;

import Types.WsEvent;
import client.Main.getEl;
import haxe.Timer;
import js.Browser.document;
import js.Browser.window;
import js.html.CanvasElement;
import js.html.CanvasRenderingContext2D;
import js.html.Element;
import js.html.MouseEvent;
import js.html.TouchEvent;

// Seeded random number generator for synchronized brush effects
class SeededRandom {
	private var seed:Float;

	public function new(seed:Float) {
		this.seed = seed;
	}

	public function next():Float {
		// Linear congruential generator (LCG) algorithm
		// Using same constants as Java's Random class for consistency
		seed = (seed * 1103515245 + 12345) % 2147483648;
		return seed / 2147483648;
	}

	public function setSeed(newSeed:Float):Void {
		this.seed = newSeed;
	}
}

// Structure to represent other users' cursors
typedef UserCursor = {
	name:String,
	x:Float,
	y:Float,
	lastUpdate:Float
}

// Structure to represent other users' drawing state
typedef UserDrawingState = {
	color:String,
	size:Float,
	tool:String,
	lastX:Float,
	lastY:Float
}

class Drawing {
	static var canvas:CanvasElement;
	static var ctx:CanvasRenderingContext2D;
	static var main:Main;
	static var isDrawingUIVisible = false;
	static var isDrawingEnabled = false;
	static var isDrawing = false;
	static var lastX = 0.0;
	static var lastY = 0.0;
	static var currentColor = "#FF0000";
	static var currentSize = 3.0;
	static var currentTool = "pen"; // "pen", "eraser", "brush", "airbrush", "marker", "pencil", "charcoal", "watercolor"

	// Advanced brush properties for Photoshop-like functionality
	static var brushOpacity = 1.0; // Master opacity (0.0-1.0)
	static var brushFlow = 1.0; // Flow rate for airbrush effects (0.0-1.0)
	static var brushHardness = 1.0; // Brush edge hardness (0.0-1.0)
	static var brushSpacing = 0.1; // Distance between brush stamps (0.0-1.0)
	static var brushScatter = 0.0; // Random scatter amount (0.0-1.0)
	static var brushRotation = 0.0; // Brush rotation angle (0-360 degrees)
	static var brushRoundness = 1.0; // Brush roundness (0.0-1.0, 1.0 = circle)
	static var brushTexture = 1.0; // Texture intensity (0.0-1.0)
	static var brushDynamics = true; // Enable pressure dynamics

	// Advanced brush state tracking
	static var lastBrushX = 0.0;
	static var lastBrushY = 0.0;
	static var brushAccumulation:Array<{
		x:Float,
		y:Float,
		pressure:Float,
		time:Float
	}> = [];
	static var brushVelocity = 0.0; // Current brush velocity for dynamics
	static var lastBrushTime = 0.0;

	// Tablet/stylus support variables
	static var supportsPressure = false;
	static var currentPressure = 1.0;
	static var currentTiltX = 0.0;
	static var currentTiltY = 0.0;
	static var currentPointerType = "mouse"; // "mouse", "pen", "touch"
	static var pressureSensitivity = true; // Can be toggled by user
	static var palmRejection = true; // Reject touch when pen is being used
	static var isPenActive = false; // Track if pen is currently being used	// Map to store other users' cursor positions
	static var userCursors:Map<String, UserCursor> = new Map<String, UserCursor>();
	// Map to store other users' drawing states for per-user position tracking
	static var userDrawingStates:Map<String, UserDrawingState> = new Map<String,
		UserDrawingState>();
	static var cursorCheckTimer:Timer;
	static var lastCursorSendTime:Float = 0;
	static var cursorThrottleInterval:Float = 33; // ~30fps for cursor position updates
	static var animFrameId:Int;

	// Background control variables
	static var currentBackgroundMode = "transparent"; // "transparent" or "color"
	static var currentBackgroundColor = "#FFFFFF";

	// Legacy variables kept for backward compatibility but no longer used for multi-user
	static var incomingColor = "#FF0000";
	static var incomingSize = 3.0;
	static var incomingTool = "pen"; // "pen" or "eraser"
	static var incomingLastX = 0.0;
	static var incomingLastY = 0.0;
	static var playerEl:Element; // Synchronized random generator for consistent brush effects across clients
	static var syncRandom:SeededRandom = new SeededRandom(12345);
	static var currentStrokeSeed:Float = 0;

	// Dragging variables
	static var isDragging = false;
	static var dragOffsetX = 0.0;
	static var dragOffsetY = 0.0;

	// Auto-save variables
	static var hasUnsavedChanges = false;
	static var autoSaveTimer:Timer;

	public static function init(main:Main):Void {
		Drawing.main = main;
		canvas = cast getEl("#drawing-canvas");
		ctx = canvas.getContext2d();
		playerEl = getEl("#ytapiplayer");

		setupCanvas();
		setupEventListeners();
		setupDrawingTools();
		setupBrushControls();

		// Start periodic cursor rendering and cleanup
		startCursorTimer();
	}

	static function startCursorTimer():Void {
		// Stop any existing timer
		if (cursorCheckTimer != null) {
			cursorCheckTimer.stop();
		}

		// Use requestAnimationFrame for smoother rendering
		if (animFrameId != null) {
			js.Browser.window.cancelAnimationFrame(animFrameId);
		}

		// Define the render loop function with proper typing
		function renderLoop(timestamp:Float):Void {
			renderCursors();
			animFrameId = js.Browser.window.requestAnimationFrame(renderLoop);
		}

		// Start animation frame loop for rendering
		animFrameId = js.Browser.window.requestAnimationFrame(renderLoop);

		// Use a slower timer only for cleanup of stale cursors
		cursorCheckTimer = new Timer(1000); // Check for stale cursors every second
		cursorCheckTimer.run = () -> cleanupOldCursors();
	}

	static function cleanupOldCursors():Void {
		final now = Date.now().getTime();
		final keysToRemove = [];

		// Find cursors that haven't been updated in the last 5 seconds
		for (key => cursor in userCursors) {
			if (now - cursor.lastUpdate > 5000) { // 5 seconds timeout
				keysToRemove.push(key);
			}
		}

		// Remove stale cursors and their associated drawing states
		for (key in keysToRemove) {
			userCursors.remove(key);
			// Also clean up drawing state for disconnected users
			userDrawingStates.remove(key);
		}
	}

	static function setupCanvas():Void {
		// Set canvas size to match player
		resizeCanvas();

		// Setup canvas properties
		ctx.lineCap = "round";
		ctx.lineJoin = "round";
		ctx.strokeStyle = currentColor;
		ctx.lineWidth = currentSize;
	}

	static function resizeCanvas():Void {
		if (playerEl == null) return;

		final rect = playerEl.getBoundingClientRect();

		// Set canvas to exactly match the video player dimensions and position
		canvas.width = Std.int(rect.width);
		canvas.height = Std.int(rect.height);
		canvas.style.width = rect.width + "px";
		canvas.style.height = rect.height + "px";

		// Position canvas to perfectly overlay the video player
		canvas.style.position = "absolute";
		canvas.style.left = rect.left + "px";
		canvas.style.top = rect.top + "px";
		canvas.style.zIndex = "10"; // Ensure canvas is above video but below UI elements

		// Reapply drawing settings after resize
		ctx.lineCap = "round";
		ctx.lineJoin = "round";
		ctx.strokeStyle = currentColor;
		ctx.lineWidth = currentSize;
		// Redraw any existing content by reloading the drawing
		if (isDrawingUIVisible) {
			loadDrawing();
		}
	}

	static function setupEventListeners():Void {
		// Prevent default browser behaviors on canvas for better stylus support
		setupCanvasStyleForStylus();

		// Check for pointer events support (better for tablets)
		if (untyped window.PointerEvent != null) {
			// Modern pointer events (preferred for tablet support)
			canvas.addEventListener("pointerdown", onPointerDown, {passive: false});
			canvas.addEventListener("pointermove", onPointerMove, {passive: false});
			canvas.addEventListener("pointerup", onPointerUp, {passive: false});
			canvas.addEventListener("pointercancel", onPointerUp, {passive: false});
			canvas.addEventListener("pointerout", onPointerUp, {passive: false});
			canvas.addEventListener("pointerleave", onPointerUp, {passive: false});

			// Prevent context menu on long press/right click
			canvas.addEventListener("contextmenu", preventDefaultEvent, {passive: false});

			// Prevent browser gestures and shortcuts
			canvas.addEventListener("gesturestart", preventDefaultEvent, {passive: false});
			canvas.addEventListener("gesturechange", preventDefaultEvent, {passive: false});
			canvas.addEventListener("gestureend", preventDefaultEvent, {passive: false});

			// Check if pressure is supported
			supportsPressure = true; // Will be verified on first pointer event
		} else {
			// Fallback to mouse and touch events
			canvas.addEventListener("mousedown", onMouseDown, {passive: false});
			canvas.addEventListener("mousemove", onMouseMove, {passive: false});
			canvas.addEventListener("mouseup", onMouseUp, {passive: false});
			canvas.addEventListener("mouseout", onMouseUp, {passive: false});
			canvas.addEventListener("contextmenu", preventDefaultEvent, {passive: false});

			// Touch events for mobile
			canvas.addEventListener("touchstart", onTouchStart, {passive: false});
			canvas.addEventListener("touchmove", onTouchMove, {passive: false});
			canvas.addEventListener("touchend", onTouchEnd, {passive: false});
		}

		// Resize observer to keep canvas in sync with player
		window.addEventListener("resize", resizeCanvas);

		// Prevent browser shortcuts when drawing area is focused
		document.addEventListener("keydown", preventBrowserShortcuts, {passive: false});

		// Also listen for video player size changes (e.g., fullscreen, theater mode)
		Timer.delay(() -> {
			// Set up a periodic check for player size changes
			var lastWidth = 0.0;
			var lastHeight = 0.0;

			final checkResize = () -> {
				if (playerEl != null) {
					final rect = playerEl.getBoundingClientRect();
					if (rect.width != lastWidth || rect.height != lastHeight) {
						lastWidth = rect.width;
						lastHeight = rect.height;
						resizeCanvas();
					}
				}
			};

			// Check every 500ms for size changes
			new Timer(500).run = checkResize;
		}, 100);
	}

	static function getMousePos(e:MouseEvent):{x:Float, y:Float} {
		return getVideoNormalizedCoords(e.clientX, e.clientY);
	}

	static function getTouchPos(e:TouchEvent):{x:Float, y:Float} {
		if (e.touches.length == 0) return {x: 0, y: 0};
		final touch = e.touches[0];
		return getVideoNormalizedCoords(touch.clientX, touch.clientY);
	}

	// Convert screen coordinates to video-content normalized coordinates (0.0-1.0)
	// This ensures drawings appear at the same relative position regardless of screen resolution
	static function getVideoNormalizedCoords(clientX:Float, clientY:Float):{x:Float, y:Float} {
		final canvasRect = canvas.getBoundingClientRect();
		final playerRect = playerEl.getBoundingClientRect();

		// Calculate position relative to the player element
		final relativeX = clientX - playerRect.left;
		final relativeY = clientY - playerRect.top;

		// Normalize to 0.0-1.0 range based on player dimensions
		// This creates a coordinate system that's independent of actual screen size
		final normalizedX = relativeX / playerRect.width;
		final normalizedY = relativeY / playerRect.height;

		// Clamp to valid range to handle edge cases
		final clampedX = Math.max(0.0, Math.min(1.0, normalizedX));
		final clampedY = Math.max(0.0, Math.min(1.0, normalizedY));

		return {x: clampedX, y: clampedY};
	}

	static function onMouseDown(e:MouseEvent):Void {
		if (!isDrawingEnabled) return;
		e.preventDefault();
		e.stopPropagation();

		final pos = getMousePos(e);
		startDrawing(pos.x, pos.y);
	}

	static function onMouseMove(e:MouseEvent):Void {
		if (!isDrawingEnabled) return;
		e.preventDefault();
		e.stopPropagation();

		// Get normalized cursor position
		final pos = getMousePos(e);

		// If actively drawing, continue the drawing
		if (isDrawing) {
			continueDrawing(pos.x, pos.y);
		}

		// Send cursor position to other clients when drawing UI is visible
		if (isDrawingUIVisible) {
			sendCursorPosition(pos.x, pos.y);
		}
	}

	static function onMouseUp(e:MouseEvent):Void {
		if (!isDrawingEnabled || !isDrawing) return;
		e.preventDefault();
		e.stopPropagation();

		stopDrawing();
	}

	// Send cursor position to server for broadcasting to other clients
	static function sendCursorPosition(x:Float, y:Float):Void {
		// Get current time for throttling
		final now = Date.now().getTime();

		// Only send updates at the specified throttle rate to reduce network traffic
		if (now - lastCursorSendTime < cursorThrottleInterval) return;

		lastCursorSendTime = now;

		main.send({
			type: DrawCursor,
			drawCursor: {
				x: x,
				y: y,
				clientName: main.getName()
			}
		});
	}

	static function onTouchStart(e:TouchEvent):Void {
		if (!isDrawingEnabled) return;
		e.preventDefault();
		e.stopPropagation();

		final pos = getTouchPos(e);
		startDrawing(pos.x, pos.y);
	}

	static function onTouchMove(e:TouchEvent):Void {
		if (!isDrawingEnabled) return;
		e.preventDefault();
		e.stopPropagation();

		// Get normalized cursor position
		final pos = getTouchPos(e);

		// If actively drawing, continue the drawing
		if (isDrawing) {
			continueDrawing(pos.x, pos.y);
		}

		// Send cursor position to other clients when drawing UI is visible
		if (isDrawingUIVisible) {
			sendCursorPosition(pos.x, pos.y);
		}
	}

	static function onTouchEnd(e:TouchEvent):Void {
		if (!isDrawingEnabled || !isDrawing) return;
		e.preventDefault();
		e.stopPropagation();

		stopDrawing();
	}

	static function startDrawing(x:Float, y:Float):Void {
		isDrawing = true;
		lastX = x;
		lastY = y;

		// Generate a new random seed for this stroke to ensure consistency across clients
		currentStrokeSeed = Math.random() * 1000000;
		syncRandom.setSeed(currentStrokeSeed);

		// Send drawing start event to server
		main.send({
			type: DrawStart,
			drawStart: {
				x: x,
				y: y,
				color: currentColor,
				size: currentSize,
				tool: currentTool,
				clientName: main.getName(),
				pressure: currentPressure,
				brushOpacity: brushOpacity,
				brushFlow: brushFlow,
				brushHardness: brushHardness,
				brushTexture: brushTexture,
				brushScatter: brushScatter,
				seed: currentStrokeSeed
			}
		});
	}

	static function continueDrawing(x:Float, y:Float):Void {
		if (!isDrawing) return;

		// Draw locally
		drawLine(lastX, lastY, x, y, currentColor, currentSize, currentTool);
		// Send drawing move event to server
		main.send({
			type: DrawMove,
			drawMove: {
				x: x,
				y: y,
				clientName: main.getName(),
				pressure: currentPressure
			}
		});

		lastX = x;
		lastY = y;
	}

	static function stopDrawing():Void {
		if (!isDrawing) return;
		isDrawing = false;

		// Send drawing end event to server
		main.send({
			type: DrawEnd,
			drawEnd: {}
		});

		// Mark that we have unsaved changes and trigger auto-save
		hasUnsavedChanges = true;
		saveDrawingInBackground();
	}

	static function startAutoSave():Void {
		// Stop any existing timer
		stopAutoSave();

		// Start a timer that saves every 10 seconds if there are unsaved changes
		autoSaveTimer = new Timer(10000);
		autoSaveTimer.run = () -> {
			if (hasUnsavedChanges) {
				saveDrawingInBackground();
			}
		};
	}

	static function stopAutoSave():Void {
		if (autoSaveTimer != null) {
			autoSaveTimer.stop();
			autoSaveTimer = null;
		}
	}

	static function saveDrawingInBackground():Void {
		if (!hasUnsavedChanges) return;

		// Convert canvas to base64 data URL
		final dataURL = canvas.toDataURL("image/png");

		// Send to server for saving
		main.send({
			type: SaveDrawing,
			saveDrawing: {
				data: dataURL
			}
		});

		hasUnsavedChanges = false;
	}

	public static function drawLine(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, ?tool:String):Void {
		drawLineWithPressure(x1, y1, x2, y2, color, size, currentPressure, tool);
	}

	public static function drawLineWithPressure(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float, ?tool:String):Void {
		// Convert normalized coordinates (0.0-1.0) back to canvas pixels
		final pixelX1 = x1 * canvas.width;
		final pixelY1 = y1 * canvas.height;
		final pixelX2 = x2 * canvas.width;
		final pixelY2 = y2 * canvas.height;

		// Calculate brush velocity for dynamics
		final currentTime = Date.now().getTime();
		final distance = Math.sqrt((pixelX2 - pixelX1) * (pixelX2 - pixelX1)
			+ (pixelY2 - pixelY1) * (pixelY2 - pixelY1));
		final deltaTime = currentTime - lastBrushTime;
		brushVelocity = deltaTime > 0 ? distance / deltaTime : 0;
		lastBrushTime = currentTime;

		// Apply different drawing methods based on tool type
		switch (tool) {
			case "brush":
				drawBrush(pixelX1, pixelY1, pixelX2, pixelY2, color, size, pressure);
			case "airbrush":
				drawAirbrush(pixelX1, pixelY1, pixelX2, pixelY2, color, size, pressure);
			case "marker":
				drawMarker(pixelX1, pixelY1, pixelX2, pixelY2, color, size, pressure);
			case "pencil":
				drawPencil(pixelX1, pixelY1, pixelX2, pixelY2, color, size, pressure);
			case "charcoal":
				drawCharcoal(pixelX1, pixelY1, pixelX2, pixelY2, color, size, pressure);
			case "watercolor":
				drawWatercolor(pixelX1, pixelY1, pixelX2, pixelY2, color, size, pressure);
			case "eraser":
				drawEraser(pixelX1, pixelY1, pixelX2, pixelY2, size, pressure);
			default: // "pen"
				drawPen(pixelX1, pixelY1, pixelX2, pixelY2, color, size, pressure);
		}

		// Update last brush position for next stroke
		lastBrushX = pixelX2;
		lastBrushY = pixelY2;
	}

	static function hexToRgb(hex:String):{r:Int, g:Int, b:Int} {
		final regex = ~/^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i;
		return regex.match(hex) ? {
			r: Std.parseInt("0x" + regex.matched(1)),
			g: Std.parseInt("0x" + regex.matched(2)),
			b: Std.parseInt("0x" + regex.matched(3))
		} : {r: 0, g: 0, b: 0};
	}

	public static function clearCanvas():Void {
		ctx.clearRect(0, 0, canvas.width, canvas.height);
		hasUnsavedChanges = true;
		saveDrawingInBackground();
	}

	public static function toggleDrawing():Void {
		isDrawingUIVisible = !isDrawingUIVisible;

		// Show/hide drawing UI elements
		final drawingBtn = getEl("#drawingbtn");
		final drawingTools = getEl("#drawing-tools");
		if (isDrawingUIVisible) {
			drawingBtn.classList.add("active");
			drawingTools.style.display = "block";
			canvas.style.display = "block";
			resizeCanvas();

			// Automatically enable drawing when UI is shown
			isDrawingEnabled = true;
			canvas.style.pointerEvents = "auto"; // Update tool buttons to reflect current tool state
			updateToolButtonsState();

			// Update background style to reflect current background mode
			updateBackgroundStyle(false);

			// Automatically load the saved drawing when opening
			loadDrawing();

			// Start auto-save timer
			startAutoSave();
		} else {
			drawingBtn.classList.remove("active");
			drawingTools.style.display = "none";
			canvas.style.display = "none";
			if (isDrawing) {
				stopDrawing();
			}
			// Automatically disable drawing when UI is hidden
			isDrawingEnabled = false;
			canvas.style.pointerEvents = "none";

			// Stop auto-save timer
			stopAutoSave();
		}
	}

	public static function setDrawingEnabled(enabled:Bool):Void {
		isDrawingEnabled = enabled;
		canvas.style.pointerEvents = enabled ? "auto" : "none";

		final drawingBtn = getEl("#drawingbtn");
		if (enabled) {
			drawingBtn.classList.add("active");
			canvas.style.display = "block";
			resizeCanvas();
		} else {
			drawingBtn.classList.remove("active");
			canvas.style.display = "none";
			if (isDrawing) {
				isDrawing = false;
			}
		}
	}

	public static function onDrawStart(x:Float, y:Float, color:String, size:Float, tool:String, clientName:String, seed:Float = 0):Void {
		// Set the synchronized random generator seed for this stroke
		if (seed != 0) {
			currentStrokeSeed = seed;
			syncRandom.setSeed(currentStrokeSeed);
		}

		// Store or update drawing state for this specific user
		userDrawingStates.set(clientName, {
			color: color,
			size: size,
			tool: tool,
			lastX: x,
			lastY: y
		});

		// Update legacy variables for backward compatibility (using the most recent user's data)
		incomingColor = color;
		incomingSize = size;
		incomingTool = tool;
		incomingLastX = x;
		incomingLastY = y;
	}

	public static function onDrawMove(x:Float, y:Float, clientName:String):Void {
		// Get the drawing state for this specific user
		final userState = userDrawingStates.get(clientName);
		if (userState == null) {
			// If we don't have a state for this user, ignore the move event
			// This can happen if we missed the DrawStart event
			return;
		}

		// Draw the line using this user's drawing state
		drawLine(userState.lastX, userState.lastY, x, y, userState.color, userState.size, userState.tool);

		// Update the user's last position
		userState.lastX = x;
		userState.lastY = y;

		// Update legacy variables for backward compatibility (using the most recent user's data)
		incomingLastX = x;
		incomingLastY = y;
	}

	public static function onDrawEnd():Void {
		// Nothing special needed for draw end
	}

	public static function getIsDrawingEnabled():Bool {
		return isDrawingEnabled;
	}

	static function setupDraggable():Void {
		final drawingTools:js.html.Element = cast getEl("#drawing-tools");
		final header:js.html.Element = cast getEl("#drawing-tools-header");

		// Function to handle mouse move during drag
		function onDocumentMouseMove(e:MouseEvent):Void {
			if (!isDragging) return;

			// Calculate new position
			final newX = e.clientX - dragOffsetX;
			final newY = e.clientY - dragOffsetY;

			// Keep panel within viewport bounds
			final viewportWidth = window.innerWidth;
			final viewportHeight = window.innerHeight;
			final panelWidth = (cast drawingTools : js.html.HtmlElement).offsetWidth;
			final panelHeight = (cast drawingTools : js.html.HtmlElement).offsetHeight;

			final clampedX = Math.max(0, Math.min(newX, viewportWidth - panelWidth));
			final clampedY = Math.max(0, Math.min(newY, viewportHeight - panelHeight));

			drawingTools.style.left = clampedX + "px";
			drawingTools.style.top = clampedY + "px";
			drawingTools.style.right = "auto"; // Remove right positioning

			e.preventDefault();
		}

		// Function to handle mouse up during drag
		function onDocumentMouseUp(e:MouseEvent):Void {
			if (isDragging) {
				isDragging = false;
				// Remove the global event listeners
				document.removeEventListener("mousemove", onDocumentMouseMove);
				document.removeEventListener("mouseup", onDocumentMouseUp);
				e.preventDefault();
			}
		}

		// Mouse events for dragging
		header.onmousedown = (e:MouseEvent) -> {
			// Only start dragging if clicking directly on the header, not child elements
			if (e.target != header) return;

			isDragging = true;

			// Calculate offset from mouse to top-left corner of panel
			final rect = drawingTools.getBoundingClientRect();
			dragOffsetX = e.clientX - rect.left;
			dragOffsetY = e.clientY - rect.top;

			// Add global event listeners only when dragging starts
			document.addEventListener("mousemove", onDocumentMouseMove);
			document.addEventListener("mouseup", onDocumentMouseUp);

			// Prevent text selection
			e.preventDefault();
			e.stopPropagation();
		};

		// Function to handle touch move during drag
		function onDocumentTouchMove(e:TouchEvent):Void {
			if (!isDragging || e.touches.length != 1) return;

			final touch = e.touches[0];
			final newX = touch.clientX - dragOffsetX;
			final newY = touch.clientY - dragOffsetY;

			final viewportWidth = window.innerWidth;
			final viewportHeight = window.innerHeight;
			final panelWidth = (cast drawingTools : js.html.HtmlElement).offsetWidth;
			final panelHeight = (cast drawingTools : js.html.HtmlElement).offsetHeight;

			final clampedX = Math.max(0, Math.min(newX, viewportWidth - panelWidth));
			final clampedY = Math.max(0, Math.min(newY, viewportHeight - panelHeight));

			drawingTools.style.left = clampedX + "px";
			drawingTools.style.top = clampedY + "px";
			drawingTools.style.right = "auto";

			e.preventDefault();
		}

		// Function to handle touch end during drag
		function onDocumentTouchEnd(e:TouchEvent):Void {
			if (isDragging) {
				isDragging = false;
				// Remove the global event listeners
				document.removeEventListener("touchmove", onDocumentTouchMove);
				document.removeEventListener("touchend", onDocumentTouchEnd);
				e.preventDefault();
			}
		}

		// Touch events for mobile dragging
		header.ontouchstart = (e:TouchEvent) -> {
			if (e.touches.length != 1) return;
			// Only start dragging if touching directly on the header
			if (e.target != header) return;

			isDragging = true;
			final touch = e.touches[0];

			final rect = drawingTools.getBoundingClientRect();
			dragOffsetX = touch.clientX - rect.left;
			dragOffsetY = touch.clientY - rect.top;

			// Add global event listeners only when dragging starts
			document.addEventListener("touchmove", onDocumentTouchMove);
			document.addEventListener("touchend", onDocumentTouchEnd);

			e.preventDefault();
			e.stopPropagation();
		};
	}

	static function setupDrawingTools():Void {
		// Setup draggable functionality for drawing tools panel
		setupDraggable();
		// Color picker
		final colorPicker:js.html.InputElement = cast getEl("#drawing-color");
		colorPicker.oninput = e -> {
			currentColor = colorPicker.value;
			updateCanvasStyle();
		};
		// Prevent drag interference with color picker
		colorPicker.onmousedown = e -> e.stopPropagation();

		// Size slider
		final sizeSlider:js.html.InputElement = cast getEl("#drawing-size");
		final sizeValue = getEl("#size-value");
		sizeSlider.oninput = e -> {
			currentSize = Std.parseFloat(sizeSlider.value);
			sizeValue.innerText = Std.string(Std.int(currentSize));
			updateCanvasStyle();
		};
		// Prevent drag interference with size slider
		sizeSlider.onmousedown = e -> e.stopPropagation(); // Tool buttons
		final toolButtons = document.querySelectorAll(".drawing-tool");
		for (i in 0...toolButtons.length) {
			final button:js.html.Element = cast toolButtons.item(i);
			button.onclick = e -> {
				// Remove active class from all buttons and reset to grey
				for (j in 0...toolButtons.length) {
					final btn:js.html.Element = cast toolButtons.item(j);
					btn.classList.remove("active");
					btn.style.background = "#555"; // Grey for inactive
				}

				// Add active class to clicked button and set to blue
				button.classList.add("active");
				button.style.background = "#2196F3"; // Blue for active

				currentTool = button.getAttribute("data-tool");

				// Apply tool-specific presets
				applyToolPreset(currentTool);

				updateCanvasStyle();
			}; // Prevent drag interference with tool buttons
			button.onmousedown = e -> e.stopPropagation();
		}

		// Background option buttons
		final backgroundButtons = document.querySelectorAll(".background-option");
		for (i in 0...backgroundButtons.length) {
			final button:js.html.Element = cast backgroundButtons.item(i);
			button.onclick = e -> {
				// Remove active class from all background buttons and reset to grey
				for (j in 0...backgroundButtons.length) {
					final btn:js.html.Element = cast backgroundButtons.item(j);
					btn.classList.remove("active");
					btn.style.background = "#555"; // Grey for inactive
				}

				// Add active class to clicked button and set to blue
				button.classList.add("active");
				button.style.background = "#2196F3"; // Blue for active

				currentBackgroundMode = button.getAttribute("data-background");
				updateBackgroundStyle();
			};
			// Prevent drag interference with background buttons
			button.onmousedown = e -> e.stopPropagation();
		}

		// Background color picker
		final backgroundColorPicker:js.html.InputElement = cast getEl("#drawing-background-color");
		backgroundColorPicker.oninput = e -> {
			currentBackgroundColor = backgroundColorPicker.value;
			updateBackgroundStyle();
		};
		// Prevent drag interference with background color picker
		backgroundColorPicker.onmousedown = e -> e.stopPropagation();

		// Clear drawing button
		final clearButton = getEl("#clear-drawing");
		clearButton.onclick = e -> {
			// Show confirmation dialog before clearing the canvas
			if (js.Browser.window.confirm(Lang.get("confirmClearDrawing") ?? "Are you sure you want to clear the drawing?")) {
				clearCanvas();
				main.send({
					type: ClearDrawing,
					clearDrawing: {}
				});
			}
		};
		// Download drawing button
		final downloadButton = getEl("#download-drawing");
		downloadButton.onclick = e -> {
			downloadDrawing();
		};

		// Setup tablet/stylus controls
		setupTabletControls();
	}

	static function setupBrushControls():Void {
		// Brush opacity control
		final opacitySlider:js.html.InputElement = cast getEl("#brush-opacity");
		if (opacitySlider != null) {
			final opacityValue = getEl("#opacity-value");
			opacitySlider.oninput = e -> {
				brushOpacity = Std.parseFloat(opacitySlider.value);
				opacityValue.innerText = Std.string(Std.int(brushOpacity * 100)) + "%";
			};
		}

		// Brush flow control
		final flowSlider:js.html.InputElement = cast getEl("#brush-flow");
		if (flowSlider != null) {
			final flowValue = getEl("#flow-value");
			flowSlider.oninput = e -> {
				brushFlow = Std.parseFloat(flowSlider.value);
				flowValue.innerText = Std.string(Std.int(brushFlow * 100)) + "%";
			};
		}

		// Brush hardness control
		final hardnessSlider:js.html.InputElement = cast getEl("#brush-hardness");
		if (hardnessSlider != null) {
			final hardnessValue = getEl("#hardness-value");
			hardnessSlider.oninput = e -> {
				brushHardness = Std.parseFloat(hardnessSlider.value);
				hardnessValue.innerText = Std.string(Std.int(brushHardness * 100)) + "%";
			};
		}

		// Brush spacing control
		final spacingSlider:js.html.InputElement = cast getEl("#brush-spacing");
		if (spacingSlider != null) {
			final spacingValue = getEl("#spacing-value");
			spacingSlider.oninput = e -> {
				brushSpacing = Std.parseFloat(spacingSlider.value);
				spacingValue.innerText = Std.string(Std.int(brushSpacing * 100)) + "%";
			};
		}

		// Brush scatter control
		final scatterSlider:js.html.InputElement = cast getEl("#brush-scatter");
		if (scatterSlider != null) {
			final scatterValue = getEl("#scatter-value");
			scatterSlider.oninput = e -> {
				brushScatter = Std.parseFloat(scatterSlider.value);
				scatterValue.innerText = Std.string(Std.int(brushScatter * 100)) + "%";
			};
		}

		// Brush texture control
		final textureSlider:js.html.InputElement = cast getEl("#brush-texture");
		if (textureSlider != null) {
			final textureValue = getEl("#texture-value");
			textureSlider.oninput = e -> {
				brushTexture = Std.parseFloat(textureSlider.value);
				textureValue.innerText = Std.string(Std.int(brushTexture * 100)) + "%";
			};
		}

		// Brush dynamics toggle
		final dynamicsToggle = getEl("#brush-dynamics");
		if (dynamicsToggle != null) {
			dynamicsToggle.onclick = e -> {
				brushDynamics = !brushDynamics;
				final button:js.html.Element = cast dynamicsToggle;
				if (brushDynamics) {
					button.style.background = "#2196F3";
					button.innerText = "ON";
				} else {
					button.style.background = "#555";
					button.innerText = "OFF";
				}
			};
		}
	}

	// Apply tool-specific preset configurations
	static function applyToolPreset(tool:String):Void {
		switch (tool) {
			case "pen":
				brushOpacity = 1.0;
				brushFlow = 1.0;
				brushHardness = 1.0;
				brushSpacing = 0.05;
				brushScatter = 0.0;
				brushTexture = 1.0;
			case "brush":
				brushOpacity = 0.8;
				brushFlow = 0.7;
				brushHardness = 0.6;
				brushSpacing = 0.1;
				brushScatter = 0.1;
				brushTexture = 0.9;
			case "pencil":
				brushOpacity = 0.9;
				brushFlow = 0.8;
				brushHardness = 0.8;
				brushSpacing = 0.02;
				brushScatter = 0.2;
				brushTexture = 0.7;
			case "airbrush":
				brushOpacity = 0.6;
				brushFlow = 0.3;
				brushHardness = 0.1;
				brushSpacing = 0.3;
				brushScatter = 0.4;
				brushTexture = 1.0;
			case "marker":
				brushOpacity = 0.7;
				brushFlow = 1.0;
				brushHardness = 0.9;
				brushSpacing = 0.05;
				brushScatter = 0.0;
				brushTexture = 1.0;
			case "charcoal":
				brushOpacity = 0.8;
				brushFlow = 0.6;
				brushHardness = 0.3;
				brushSpacing = 0.15;
				brushScatter = 0.6;
				brushTexture = 0.4;
			case "watercolor":
				brushOpacity = 0.5;
				brushFlow = 0.4;
				brushHardness = 0.2;
				brushSpacing = 0.2;
				brushScatter = 0.3;
				brushTexture = 0.8;
			case "eraser":
				brushOpacity = 1.0;
				brushFlow = 1.0;
				brushHardness = 0.7;
				brushSpacing = 0.05;
				brushScatter = 0.0;
				brushTexture = 1.0;
		}

		// Update UI to reflect the new preset values
		updateBrushControlsUI();
	}

	// Update the brush controls UI to reflect current values
	static function updateBrushControlsUI():Void {
		// Update opacity
		final opacitySlider:js.html.InputElement = cast getEl("#brush-opacity");
		final opacityValue = getEl("#opacity-value");
		if (opacitySlider != null && opacityValue != null) {
			opacitySlider.value = Std.string(brushOpacity);
			opacityValue.innerText = Std.string(Std.int(brushOpacity * 100)) + "%";
		}

		// Update flow
		final flowSlider:js.html.InputElement = cast getEl("#brush-flow");
		final flowValue = getEl("#flow-value");
		if (flowSlider != null && flowValue != null) {
			flowSlider.value = Std.string(brushFlow);
			flowValue.innerText = Std.string(Std.int(brushFlow * 100)) + "%";
		}

		// Update hardness
		final hardnessSlider:js.html.InputElement = cast getEl("#brush-hardness");
		final hardnessValue = getEl("#hardness-value");
		if (hardnessSlider != null && hardnessValue != null) {
			hardnessSlider.value = Std.string(brushHardness);
			hardnessValue.innerText = Std.string(Std.int(brushHardness * 100)) + "%";
		}

		// Update spacing
		final spacingSlider:js.html.InputElement = cast getEl("#brush-spacing");
		final spacingValue = getEl("#spacing-value");
		if (spacingSlider != null && spacingValue != null) {
			spacingSlider.value = Std.string(brushSpacing);
			spacingValue.innerText = Std.string(Std.int(brushSpacing * 100)) + "%";
		}

		// Update scatter
		final scatterSlider:js.html.InputElement = cast getEl("#brush-scatter");
		final scatterValue = getEl("#scatter-value");
		if (scatterSlider != null && scatterValue != null) {
			scatterSlider.value = Std.string(brushScatter);
			scatterValue.innerText = Std.string(Std.int(brushScatter * 100)) + "%";
		}

		// Update texture
		final textureSlider:js.html.InputElement = cast getEl("#brush-texture");
		final textureValue = getEl("#texture-value");
		if (textureSlider != null && textureValue != null) {
			textureSlider.value = Std.string(brushTexture);
			textureValue.innerText = Std.string(Std.int(brushTexture * 100)) + "%";
		}
	}

	static function updateCanvasStyle():Void {
		if (currentTool == "eraser") {
			ctx.globalCompositeOperation = "destination-out";
			ctx.strokeStyle = "rgba(0,0,0,1)";
		} else {
			ctx.globalCompositeOperation = "source-over";
			ctx.strokeStyle = currentColor;
		}
		ctx.lineWidth = currentSize;

		// Update tool buttons visual state to match current tool
		updateToolButtonsState();
	}

	static function updateBackgroundStyle(broadcast:Bool = true):Void {
		if (currentBackgroundMode == "transparent") {
			// Set transparent background
			canvas.style.backgroundColor = "transparent";
			// Show/hide background color picker
			final colorPickerDiv = getEl("#background-color-picker");
			colorPickerDiv.style.display = "none";
		} else {
			// Set solid background color
			canvas.style.backgroundColor = currentBackgroundColor;
			// Show background color picker
			final colorPickerDiv = getEl("#background-color-picker");
			colorPickerDiv.style.display = "block";
		}
		// Update background button visual state
		updateBackgroundButtonsState();

		// Broadcast change to other clients (unless this is from receiving an update)
		if (broadcast) {
			broadcastBackgroundChange();
		}
	}

	static function updateBackgroundButtonsState():Void {
		final transparentButton = getEl("#background-transparent");
		final colorButton = getEl("#background-color");

		// Reset both buttons
		transparentButton.classList.remove("active");
		colorButton.classList.remove("active");

		// Reset button colors
		transparentButton.style.background = "#555"; // Grey for inactive
		colorButton.style.background = "#555"; // Grey for inactive

		// Set active background mode with blue color
		if (currentBackgroundMode == "transparent") {
			transparentButton.classList.add("active");
			transparentButton.style.background = "#2196F3"; // Blue for active
		} else {
			colorButton.classList.add("active");
			colorButton.style.background = "#2196F3"; // Blue for active
		}
	}

	static function updateToolButtonsState():Void {
		final toolButtons = document.querySelectorAll(".drawing-tool");

		// Reset all buttons
		for (i in 0...toolButtons.length) {
			final button:js.html.Element = cast toolButtons.item(i);
			button.classList.remove("active");
			button.style.background = "#555"; // Grey for inactive

			// Reset icon style
			final iconElement = button.querySelector("ion-icon");
			if (iconElement != null) {
				iconElement.setAttribute("style", "");
			}
		}

		// Set active tool with blue color and bold icon
		final activeButton = getEl("#drawing-tool-" + currentTool);
		if (activeButton != null) {
			activeButton.classList.add("active");
			activeButton.style.background = "#2196F3"; // Blue for active

			// Update tool icon to show it's active
			final iconElement = activeButton.querySelector("ion-icon");
			if (iconElement != null) {
				iconElement.setAttribute("style", "color: white; font-weight: bold;");
			}
		}

		// Display current tool in the header with appropriate icon
		final toolsHeader = getEl("#drawing-tools-header");
		if (toolsHeader != null) {
			final toolIcon = switch (currentTool) {
				case "pen": "✏️";
				case "brush": "🖌️";
				case "pencil": "✏️";
				case "airbrush": "💨";
				case "marker": "🖊️";
				case "charcoal": "⚫";
				case "watercolor": "🎨";
				case "eraser": "🧽";
				default: "📝";
			}
			toolsHeader.innerHTML = '$toolIcon Drawing Tools (${currentTool.charAt(0).toUpperCase() + currentTool.substring(1)})';
		}
	}

	static function saveDrawing():Void {
		// Convert canvas to base64 data URL
		final dataURL = canvas.toDataURL("image/png");

		// Send to server for saving
		main.send({
			type: SaveDrawing,
			saveDrawing: {
				data: dataURL
			}
		});
	}

	static function loadDrawing():Void {
		// Request saved drawing from server
		main.send({
			type: LoadDrawing,
			loadDrawing: {
				data: "request" // Indicate this is a request for saved data
			}
		});
	}

	public static function onLoadDrawing(data:String):Void {
		// Only load if there's actual data and it's not empty
		if (data == null || data == "" || data == "data:,") return;

		// Load drawing data onto canvas
		final img = js.Browser.document.createImageElement();
		img.onload = () -> {
			// Clear canvas before loading the saved drawing
			ctx.clearRect(0, 0, canvas.width, canvas.height);
			ctx.drawImage(img, 0, 0);
			// Don't mark as unsaved since we just loaded
			hasUnsavedChanges = false;
		};
		img.src = data;
	}

	static function downloadDrawing():Void {
		// Create a download link
		final link = js.Browser.document.createAnchorElement();

		// Convert canvas to blob and create download URL
		final dataURL = canvas.toDataURL("image/png");

		// Set up the download
		link.href = dataURL;
		link.download = "tuubi_drawing_" + Date.now().getTime() + ".png";

		// Trigger the download
		js.Browser.document.body.appendChild(link);
		link.click();
		js.Browser.document.body.removeChild(link);
	}

	static function renderCursors():Void {
		// Don't render cursors if drawing UI is not visible
		if (!isDrawingUIVisible) return;

		// Get a reference to the cursor canvas
		final userCursorCanvas:js.html.CanvasElement = cast getEl("#user-cursor-canvas");

		// Create cursor canvas if it doesn't exist yet
		if (userCursorCanvas == null) {
			// Create a new canvas element for rendering cursors
			final cursorCanvas = document.createCanvasElement();
			cursorCanvas.id = "user-cursor-canvas";
			cursorCanvas.style.position = "absolute";
			cursorCanvas.style.left = "0px";
			cursorCanvas.style.top = "0px";
			cursorCanvas.style.pointerEvents = "none"; // Don't interfere with mouse events
			cursorCanvas.style.zIndex = "1001"; // Above drawing canvas but below UI

			// Use the modern transform style for hardware acceleration
			cursorCanvas.style.transform = "translate3d(0,0,0)";
			cursorCanvas.style.backfaceVisibility = "hidden";

			// Match size with drawing canvas
			cursorCanvas.width = canvas.width;
			cursorCanvas.height = canvas.height;

			// Position the cursor canvas (use transform for better performance)
			final canvasRect = canvas.getBoundingClientRect();
			cursorCanvas.style.left = canvasRect.left + "px";
			cursorCanvas.style.top = canvasRect.top + "px";
			cursorCanvas.style.width = canvasRect.width + "px";
			cursorCanvas.style.height = canvasRect.height + "px";

			// Add canvas to DOM, right after the drawing canvas
			canvas.parentNode.insertBefore(cursorCanvas, canvas.nextSibling);
		}

		final cursorCanvas:js.html.CanvasElement = cast getEl("#user-cursor-canvas");
		final cursorCtx = cursorCanvas.getContext2d();

		// Ensure cursor canvas size matches drawing canvas
		if (cursorCanvas.width != canvas.width || cursorCanvas.height != canvas.height) {
			cursorCanvas.width = canvas.width;
			cursorCanvas.height = canvas.height;

			final canvasRect = canvas.getBoundingClientRect();
			cursorCanvas.style.left = canvasRect.left + "px";
			cursorCanvas.style.top = canvasRect.top + "px";
			cursorCanvas.style.width = canvasRect.width + "px";
			cursorCanvas.style.height = canvasRect.height + "px";
		}

		// Clear the cursor canvas with optimized clear method
		cursorCtx.clearRect(0, 0, cursorCanvas.width, cursorCanvas.height);

		// Pre-draw text shadows only once to optimize text rendering
		cursorCtx.shadowColor = "rgba(0, 0, 0, 0.7)";
		cursorCtx.shadowBlur = 3;
		cursorCtx.shadowOffsetX = 1;
		cursorCtx.shadowOffsetY = 1;
		cursorCtx.font = "12px Arial";
		cursorCtx.textAlign = "center";

		// Draw each cursor using a single batch operation where possible
		for (clientId => cursor in userCursors) {
			// Skip own cursor
			if (cursor.name == main.getName()) continue;

			// Convert normalized coordinates to actual canvas pixels
			final pixelX = cursor.x * canvas.width;
			final pixelY = cursor.y * canvas.height;

			// Draw cursor as a circle with name
			cursorCtx.beginPath();
			cursorCtx.arc(pixelX, pixelY, 8, 0, 2 * Math.PI);
			cursorCtx.fillStyle = "rgba(100, 149, 237, 0.6)"; // Semi-transparent cornflower blue
			cursorCtx.fill();

			// Draw name above cursor with shadow already configured
			cursorCtx.fillStyle = "white";
			cursorCtx.fillText(cursor.name, pixelX, pixelY - 15);
		}
	}

	public static function onDrawCursor(clientName:String, x:Float, y:Float):Void {
		// If drawing UI is not visible, don't track cursors
		if (!isDrawingUIVisible) return;

		// Find client ID based on name, or create a new one
		final clientId = clientName;

		// Update or create cursor data
		userCursors.set(clientId, {
			name: clientName,
			x: x,
			y: y,
			lastUpdate: Date.now().getTime()
		});
	}

	static function broadcastBackgroundChange():Void {
		main.send({
			type: SetBackground,
			setBackground: {
				isTransparent: currentBackgroundMode == "transparent",
				color: currentBackgroundColor
			}
		});
	}

	public static function onSetBackground(isTransparent:Bool, color:String):Void {
		// Update local background state from other client
		currentBackgroundMode = isTransparent ? "transparent" : "color";
		currentBackgroundColor = color;

		// Update the background color picker input to reflect the new color
		final backgroundColorPicker:js.html.InputElement = cast getEl("#drawing-background-color");
		backgroundColorPicker.value = currentBackgroundColor;

		// Apply the background change visually (don't broadcast back)
		updateBackgroundStyle(false);
	}

	// Pointer Events for better tablet/stylus support
	static function onPointerDown(e:js.html.PointerEvent):Void {
		if (!isDrawingEnabled) return;

		// Aggressively prevent all default behaviors to stop browser interference
		e.preventDefault();
		e.stopPropagation();
		e.stopImmediatePropagation();

		// Update current pointer properties
		updatePointerProperties(e);

		// Enhanced palm rejection: ignore touch events if pen is active
		if (palmRejection && e.pointerType == "touch" && isPenActive) {
			return;
		}

		// Track pen usage for palm rejection
		if (e.pointerType == "pen") {
			isPenActive = true;

			// For pen input, also prevent any potential browser gestures
			if (canvas.setPointerCapture != null) {
				canvas.setPointerCapture(e.pointerId);
			}
		}

		final pos = getPointerPos(e);
		startDrawing(pos.x, pos.y);
	}

	static function onPointerMove(e:js.html.PointerEvent):Void {
		if (!isDrawingEnabled) return;

		// Aggressively prevent all default behaviors
		e.preventDefault();
		e.stopPropagation();
		e.stopImmediatePropagation();

		// Update current pointer properties
		updatePointerProperties(e);

		// Enhanced palm rejection: ignore touch events if pen is active
		if (palmRejection && e.pointerType == "touch" && isPenActive) {
			return;
		}

		// Get normalized cursor position
		final pos = getPointerPos(e);

		// If actively drawing, continue the drawing
		if (isDrawing) {
			continueDrawing(pos.x, pos.y);
		}

		// Send cursor position to other clients when drawing UI is visible
		if (isDrawingUIVisible) {
			sendCursorPosition(pos.x, pos.y);
		}
	}

	static function onPointerUp(e:js.html.PointerEvent):Void {
		if (!isDrawingEnabled) return;

		// Aggressively prevent all default behaviors
		e.preventDefault();
		e.stopPropagation();
		e.stopImmediatePropagation();

		// Update current pointer properties
		updatePointerProperties(e);

		// Reset pen active state when pen is lifted
		if (e.pointerType == "pen") {
			isPenActive = false;

			// Release pointer capture for pen
			if (canvas.releasePointerCapture != null) {
				canvas.releasePointerCapture(e.pointerId);
			}
		}

		// Enhanced palm rejection: ignore touch events if pen is active
		if (palmRejection && e.pointerType == "touch" && isPenActive) {
			return;
		}

		if (isDrawing) {
			stopDrawing();
		}
	}

	static function getPointerPos(e:js.html.PointerEvent):{x:Float, y:Float} {
		return getVideoNormalizedCoords(e.clientX, e.clientY);
	}

	static function updatePointerProperties(e:js.html.PointerEvent):Void {
		currentPointerType = e.pointerType;

		// Update pressure (0.0 to 1.0, defaults to 0.5 for non-pressure devices)
		if (e.pressure != null && e.pressure > 0) {
			currentPressure = e.pressure;
			supportsPressure = true;
		} else {
			currentPressure = 0.5; // Default pressure for devices without pressure support
		}

		// Update tilt values (in degrees, -90 to 90)
		if (e.tiltX != null) {
			currentTiltX = e.tiltX;
		}
		if (e.tiltY != null) {
			currentTiltY = e.tiltY;
		}

		// Update pressure display in real-time
		updatePressureDisplay();
	}

	static function setupTabletControls():Void {
		final tabletSettings = getEl("#tablet-settings");
		final pressureToggle = getEl("#pressure-toggle");
		final palmRejectionToggle = getEl("#palm-rejection-toggle");
		final pressureDisplay = getEl("#pressure-display");
		final pressureValue = getEl("#pressure-value");
		final pressureBar = getEl("#pressure-bar");
		final pointerType = getEl("#pointer-type");

		// Show tablet settings only if pointer events are supported
		if (untyped window.PointerEvent != null) {
			tabletSettings.style.display = "block";
		}

		// Pressure sensitivity toggle
		pressureToggle.onclick = e -> {
			pressureSensitivity = !pressureSensitivity;
			updateTabletButtonState(pressureToggle, pressureSensitivity);
		};

		// Palm rejection toggle
		palmRejectionToggle.onclick = e -> {
			palmRejection = !palmRejection;
			updateTabletButtonState(palmRejectionToggle, palmRejection);
		};

		// Setup pressure monitoring
		if (untyped window.PointerEvent != null) {
			// Show pressure display when pen is detected
			Timer.delay(() -> {
				updatePressureDisplay();
			}, 100);
		}
	}

	static function updateTabletButtonState(button:js.html.Element, enabled:Bool):Void {
		if (enabled) {
			button.style.background = "#2196F3";
			button.innerText = "ON";
			button.setAttribute("data-enabled", "true");
		} else {
			button.style.background = "#555";
			button.innerText = "OFF";
			button.setAttribute("data-enabled", "false");
		}
	}

	static function updatePressureDisplay():Void {
		final pressureDisplay = getEl("#pressure-display");
		final pressureValue = getEl("#pressure-value");
		final pressureBar = getEl("#pressure-bar");
		final pointerType = getEl("#pointer-type");

		// Show pressure display when using a pen or when pressure is detected
		if (currentPointerType == "pen" || supportsPressure) {
			pressureDisplay.style.display = "block";

			// Update pressure value and bar
			pressureValue.innerText = Math.round(currentPressure * 100) + "%";
			pressureBar.style.width = (currentPressure * 100) + "%";

			// Update pointer type display
			pointerType.innerText = currentPointerType;

			// Color the pressure bar based on pressure level
			if (currentPressure < 0.3) {
				pressureBar.style.background = "#ff9800"; // Orange for light pressure
			} else if (currentPressure < 0.7) {
				pressureBar.style.background = "#2196F3"; // Blue for medium pressure
			} else {
				pressureBar.style.background = "#4caf50"; // Green for high pressure
			}
		} else {
			pressureDisplay.style.display = "none";
		}
	}

	// Helper function to prevent default event behavior
	static function preventDefaultEvent(e:js.html.Event):Void {
		e.preventDefault();
		e.stopPropagation();
	}

	// Setup canvas style properties to prevent browser interference with stylus input
	static function setupCanvasStyleForStylus():Void {
		// Prevent browser default behaviors that interfere with stylus input
		canvas.style.touchAction = "none"; // Disable touch gestures like pinch-zoom, pan
		canvas.style.userSelect = "none"; // Disable text selection

		// Use untyped access for vendor-specific properties
		untyped canvas.style.webkitUserSelect = "none"; // Disable text selection on webkit browsers
		untyped canvas.style.msUserSelect = "none"; // Disable text selection on IE/Edge
		untyped canvas.style.mozUserSelect = "none"; // Disable text selection on Firefox

		// Prevent drag and drop
		canvas.draggable = false;
		canvas.ondragstart = (e) -> {
			e.preventDefault();
			return false;
		};

		// Prevent context menu (right-click menu)
		canvas.oncontextmenu = (e) -> {
			e.preventDefault();
			return false;
		};

		// Set cursor to crosshair when drawing is enabled
		canvas.style.cursor = "crosshair";
	}

	// Prevent browser shortcuts that could interfere with drawing
	static function preventBrowserShortcuts(e:js.html.KeyboardEvent):Void {
		// Only prevent shortcuts when drawing UI is visible and canvas is focused
		if (!isDrawingUIVisible) return;

		// Check if the canvas or its container has focus
		final activeElement = document.activeElement;
		final isCanvasFocused = activeElement == canvas || canvas.contains(activeElement);

		if (!isCanvasFocused) return;

		// Prevent common browser shortcuts that might interfere
		final key = e.key != null ? e.key.toLowerCase() : "";
		final ctrl = e.ctrlKey;
		final alt = e.altKey;
		final shift = e.shiftKey;

		// Prevent Ctrl+Shift+N (incognito mode in Chrome)
		if (ctrl && shift && key == "n") {
			e.preventDefault();
			e.stopPropagation();
		}

		// Prevent other problematic shortcuts
		if (ctrl && (key == "t" || key == "w" || key == "n" || key == "r")) {
			e.preventDefault();
			e.stopPropagation();
		}

		// Prevent F11 (fullscreen) if it might interfere
		if (key == "f11") {
			e.preventDefault();
			e.stopPropagation();
		}

		// Prevent Alt+Tab on Windows
		if (alt && key == "tab") {
			e.preventDefault();
			e.stopPropagation();
		}
	}

	// Advanced brush drawing functions with Photoshop-like features
	static function drawPen(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float):Void {
		// Ultra-premium digital pen with advanced ink flow physics and micro-precision
		var effectiveSize = size;
		var baseAlpha = brushOpacity;
		var inkFlow = brushFlow * 1.2; // Enhanced ink responsiveness

		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			// Advanced pressure curve with multiple sensitivity zones
			final lightPressure = Math.min(pressure * 2.0, 1.0); // Enhanced light touch sensitivity
			final heavyPressure = Math.max(0, (pressure - 0.5) * 2.0); // Heavy pressure zone

			final minSize = size * 0.08; // Ultra-fine minimum for precision work
			final normalSize = size * 1.4;
			final maxSize = size * 2.2; // Dramatic size range

			// Dual-zone pressure response: precise control + expressive range
			if (pressure < 0.5) {
				effectiveSize = minSize + (normalSize - minSize) * Math.pow(lightPressure, 0.6);
			} else {
				effectiveSize = normalSize
					+ (maxSize - normalSize) * Math.pow(heavyPressure, 0.8);
			}

			// Natural ink flow with pressure-sensitive opacity
			final inkAlpha = Math.pow(pressure, 0.5) * (0.6 + Math.pow(pressure, 1.5) * 0.4);
			baseAlpha = inkAlpha * brushOpacity * inkFlow;
		}

		final rgbColor = hexToRgb(color);
		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
		final strokeVelocity = distance / Math.max(1, Date.now().getTime() - lastBrushTime);

		ctx.globalCompositeOperation = "source-over";

		// Advanced anti-aliasing with sub-pixel rendering
		if (brushHardness >= 0.95) {
			// Ultra-hard pen: laser-precise lines with perfect edges
			ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${baseAlpha})';
			ctx.lineWidth = effectiveSize;
			ctx.lineCap = "round";
			ctx.lineJoin = "round";

			ctx.beginPath();
			ctx.moveTo(x1, y1);
			ctx.lineTo(x2, y2);
			ctx.stroke();

			// Add micro-detail sharpening for crisp lines
			if (pressure > 0.7 && effectiveSize > 3) {
				final sharpAlpha = baseAlpha * 0.15;
				ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${sharpAlpha})';
				ctx.lineWidth = effectiveSize * 0.7;

				ctx.beginPath();
				ctx.moveTo(x1, y1);
				ctx.lineTo(x2, y2);
				ctx.stroke();
			}
		} else {
			// Premium soft pen: multi-layer anti-aliasing with natural edges
			final aaLayers = Math.ceil((1 - brushHardness) * 6)
				+ 2; // More layers for smoother gradients
			for (i in 0...aaLayers) {
				final layerRatio = i / (aaLayers - 1);
				final falloff = Math.pow(1 - layerRatio, 1.8); // Natural opacity falloff
				final layerAlpha = baseAlpha * falloff * brushHardness;
				final layerSize = effectiveSize * (1.0 + layerRatio * (1 - brushHardness) * 0.6);

				ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${layerAlpha})';
				ctx.lineWidth = layerSize;
				ctx.lineCap = "round";
				ctx.lineJoin = "round";

				ctx.beginPath();
				ctx.moveTo(x1, y1);
				ctx.lineTo(x2, y2);
				ctx.stroke();
			}
		}

		// Advanced ink flow simulation with velocity-sensitive texture
		if (brushTexture < 0.95) {
			final velocityInfluence = Math.min(strokeVelocity * 0.8, 1.0);
			final textureIntensity = (1 - brushTexture) * (0.7 + velocityInfluence * 0.3);
			final textureSteps = Math.floor(distance / 1.2) + 2;
			for (i in 0...Std.int(textureSteps)) {
				final t = i / textureSteps;
				final texNoise = (syncRandom.next() - 0.5) * textureIntensity * 2.5;
				final texX = x1 + t * (x2 - x1) + texNoise;
				final texY = y1 + t * (y2 - y1) + texNoise;

				// Velocity-based ink droplet physics
				if (syncRandom.next() < textureIntensity * 0.4) {
					final dropletSize = effectiveSize * 0.06 * textureIntensity * (0.5
						+ syncRandom.next() * 0.5);
					final dropletAlpha = baseAlpha * 0.4 * textureIntensity * syncRandom.next();

					ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${dropletAlpha})';
					ctx.beginPath();
					ctx.arc(texX, texY, dropletSize, 0, Math.PI * 2);
					ctx.fill();
				}
			}
		}

		// Advanced ink pooling effect for slow strokes with high pressure
		if (pressure > 0.8 && strokeVelocity < 0.3 && distance > 1) {
			final poolSteps = Math.floor(distance / 2.5) + 1;
			for (i in 0...Std.int(poolSteps)) {
				final t = i / poolSteps;
				final poolX = x1 + t * (x2 - x1);
				final poolY = y1 + t * (y2 - y1);

				// Ink accumulation with pressure sensitivity
				final poolRadius = effectiveSize * pressure * 0.25 * inkFlow;
				final poolAlpha = baseAlpha * 0.2 * pressure;

				// Create radial gradient for natural pooling
				final poolGradient = ctx.createRadialGradient(poolX, poolY, 0, poolX, poolY, poolRadius);
				poolGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${poolAlpha})');
				poolGradient.addColorStop(0.6, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${poolAlpha * 0.5})');
				poolGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, 0)');

				ctx.fillStyle = poolGradient;
				ctx.beginPath();
				ctx.arc(poolX, poolY, poolRadius, 0, Math.PI * 2);
				ctx.fill();
			}
		}

		// Pressure-sensitive ink bleed for authentic pen behavior
		if (pressure > 0.6 && brushFlow > 0.7) {
			final bleedSteps = Math.floor(distance / 4) + 1;
			for (i in 0...Std.int(bleedSteps)) {
				final t = i / bleedSteps;
				final bleedX = x1 + t * (x2 - x1);
				final bleedY = y1 + t * (y2 - y1);

				// Micro-bleeds around main stroke
				final bleedCount = Math.floor(pressure * 4) + 2;
				for (j in 0...bleedCount) {
					final bleedAngle = syncRandom.next() * Math.PI * 2;
					final bleedDist = syncRandom.next() * effectiveSize * 0.3 * pressure;
					final microX = bleedX + Math.cos(bleedAngle) * bleedDist;
					final microY = bleedY + Math.sin(bleedAngle) * bleedDist;
					final microSize = syncRandom.next() * 0.8 + 0.3;
					final microAlpha = baseAlpha * 0.15 * pressure * syncRandom.next();

					ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${microAlpha})';
					ctx.beginPath();
					ctx.arc(microX, microY, microSize, 0, Math.PI * 2);
					ctx.fill();
				}
			}
		}
	}

	static function drawBrush(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float):Void {
		// Professional paint brush with authentic bristle physics and paint behavior
		var effectiveSize = size;
		var baseAlpha = brushOpacity * brushFlow * 0.35; // Paint buildup factor

		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			// Natural brush response - size increases more gradually with pressure
			effectiveSize = size * (0.3 + pressure * 0.7);
			baseAlpha *= (0.5 + pressure * 0.5);
		}

		final rgbColor = hexToRgb(color);
		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));

		// Calculate brush movement dynamics
		final brushAngle = Math.atan2(y2 - y1, x2 - x1);
		final perpAngle = brushAngle + Math.PI / 2;
		final strokeSpeed = distance / Math.max(1, Date.now().getTime() - lastBrushTime);

		// Realistic bristle simulation based on brush size
		final bristleCount = Math.floor(effectiveSize * 1.2) + 5;
		final bristleSpread = effectiveSize * 0.85;

		ctx.globalCompositeOperation = "source-over";

		// Create individual bristle groups for natural paint distribution
		final bristleGroups = 3; // Inner, middle, outer bristles
		for (group in 0...bristleGroups) {
			final groupRadius = bristleSpread * (group + 1) / bristleGroups;
			final groupBristles = Math.floor(bristleCount * (1 - group * 0.2) / bristleGroups);

			for (i in 0...Std.int(groupBristles)) {
				final bristleAngle = (i / groupBristles) * Math.PI * 2;
				final bristleRadius = groupRadius * (0.7 + syncRandom.next() * 0.6);

				// Calculate bristle base position
				final bristleBaseX = x1 + Math.cos(bristleAngle) * bristleRadius;
				final bristleBaseY = y1 + Math.sin(bristleAngle) * bristleRadius;

				// Bristle bending physics under pressure and movement
				final bendStrength = pressure * 0.4 + Math.min(strokeSpeed * 0.01, 0.3);
				final bendX = Math.cos(brushAngle) * bendStrength * bristleRadius * 0.3;
				final bendY = Math.sin(brushAngle) * bendStrength * bristleRadius * 0.3;

				// Calculate bristle tip position with bending
				final bristleTipX = x2
					+ Math.cos(bristleAngle) * bristleRadius * (1 - bendStrength * 0.5)
					+ bendX;
				final bristleTipY = y2
					+ Math.sin(bristleAngle) * bristleRadius * (1 - bendStrength * 0.5)
					+ bendY;

				// Paint load varies by bristle position and paint flow
				final distanceFromCenter = bristleRadius / bristleSpread;
				final basePaintLoad = Math.max(0.4, 1.0 - distanceFromCenter * 0.4);
				final paintLoad = basePaintLoad * brushFlow * (0.8 + syncRandom.next() * 0.4);

				// Bristle paint depletion over stroke length
				final paintDepletion = Math.min(distance * 0.002, 0.3);
				final effectivePaintLoad = paintLoad * (1 - paintDepletion);

				final bristleAlpha = baseAlpha * effectivePaintLoad * (0.9 + pressure * 0.3);
				final bristleThickness = effectiveSize * (0.08 + effectivePaintLoad * 0.12) * (1.2
					- distanceFromCenter * 0.5); // Multiple bristle layers for paint texture
				final bristleLayers = Std.int(Math.max(1, Math.floor(effectivePaintLoad * 3)));
				for (layer in 0...bristleLayers) {
					final layerAlpha = bristleAlpha * (1 - layer * 0.2) / bristleLayers;
					final layerThickness = bristleThickness * (1
						+ layer * 0.3); // Add paint texture variation
					final textureNoise = (syncRandom.next() - 0.5) * 0.4;
					final textureX1 = bristleBaseX + textureNoise;
					final textureY1 = bristleBaseY + textureNoise;
					final textureX2 = bristleTipX + textureNoise * 0.7;
					final textureY2 = bristleTipY + textureNoise * 0.7;

					ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${layerAlpha})';
					ctx.lineWidth = layerThickness;
					ctx.lineCap = "round";
					ctx.lineJoin = "round";

					ctx.beginPath();
					ctx.moveTo(textureX1, textureY1);
					ctx.lineTo(textureX2, textureY2);
					ctx.stroke();
				}
			}
		}

		// Paint pooling and bleeding effects
		if (brushFlow > 0.5 && pressure > 0.6) {
			final poolingSteps = Math.floor(distance / 3) + 1;
			for (i in 0...Std.int(poolingSteps)) {
				final t = i / poolingSteps;
				final poolX = x1 + t * (x2 - x1);
				final poolY = y1 + t * (y2 - y1);

				// Paint spreads from wet brush
				final poolRadius = effectiveSize * brushFlow * 0.3 * pressure;
				final poolGradient = ctx.createRadialGradient(poolX, poolY, 0, poolX, poolY, poolRadius);

				final poolAlpha = baseAlpha * 0.4 * brushFlow * pressure;
				poolGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${poolAlpha})');
				poolGradient.addColorStop(0.6, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${poolAlpha * 0.6})');
				poolGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, 0)');

				ctx.fillStyle = poolGradient;
				ctx.beginPath();
				ctx.arc(poolX, poolY, poolRadius, 0, Math.PI * 2);
				ctx.fill();
			}
		}
		// Paint texture and impasto effects
		if (brushTexture > 0.3 && syncRandom.next() < 0.6) {
			final textureSteps = Math.floor(distance / 1.5) + 2;
			for (i in 0...Std.int(textureSteps)) {
				final t = i / textureSteps;
				final texX = x1 + t * (x2 - x1) + (syncRandom.next() - 0.5) * brushScatter * 4;
				final texY = y1 + t * (y2 - y1) + (syncRandom.next() - 0.5) * brushScatter * 4;

				// Paint thickness varies creating impasto texture
				final impastoHeight = pressure * brushTexture * 0.8;
				if (syncRandom.next() < impastoHeight) {
					final texSize = effectiveSize * 0.08 * brushTexture * (1 + impastoHeight);
					final texAlpha = baseAlpha * 0.5 * brushTexture * syncRandom.next();

					// Slight color mixing for paint texture realism
					final mixVariation = 0.08;
					final mixR = Math.floor(rgbColor.r * (1
						+ (syncRandom.next() - 0.5) * mixVariation));
					final mixG = Math.floor(rgbColor.g * (1
						+ (syncRandom.next() - 0.5) * mixVariation));
					final mixB = Math.floor(rgbColor.b * (1
						+ (syncRandom.next() - 0.5) * mixVariation));

					ctx.fillStyle = 'rgba(${Math.max(0, Math.min(255, mixR))}, ${Math.max(0, Math.min(255, mixG))}, ${Math.max(0, Math.min(255, mixB))}, ${texAlpha})';
					ctx.beginPath();
					ctx.arc(texX, texY, texSize, 0, Math.PI * 2);
					ctx.fill();
				}
			}
		}

		// Central paint stroke with variable opacity for paint building
		final coreSteps = Math.max(2, Math.floor(distance / 1.2));
		for (i in 0...Std.int(coreSteps)) {
			final t = i / coreSteps;
			final nextT = Math.min(1.0, (i + 1) / coreSteps);

			final startX = x1 + t * (x2 - x1);
			final startY = y1 + t * (y2 - y1);
			final endX = x1 + nextT * (x2 - x1);
			final endY = y1 + nextT * (y2 - y1);

			// Paint density decreases slightly along stroke (brush running out of paint)
			final paintDensity = 1.0 - t * 0.1;
			final coreAlpha = baseAlpha * 0.9 * paintDensity;
			final coreSize = effectiveSize * (0.7 + pressure * 0.4) * paintDensity;

			ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${coreAlpha})';
			ctx.lineWidth = coreSize;
			ctx.lineCap = "round";
			ctx.lineJoin = "round";

			ctx.beginPath();
			ctx.moveTo(startX, startY);
			ctx.lineTo(endX, endY);
			ctx.stroke();
		}
		// Paint splattering for dynamic brush strokes
		if (pressure > 0.8 && strokeSpeed > 0.1) {
			final splatterCount = Math.floor(syncRandom.next() * 3) + 1;
			for (i in 0...splatterCount) {
				final splatterAngle = brushAngle + (syncRandom.next() - 0.5) * 1.2;
				final splatterDistance = syncRandom.next() * effectiveSize * 1.5;
				final splatterX = x2 + Math.cos(splatterAngle) * splatterDistance;
				final splatterY = y2 + Math.sin(splatterAngle) * splatterDistance;
				final splatterSize = syncRandom.next() * 2.2 + 0.8;
				final splatterAlpha = baseAlpha * 0.3 * pressure * syncRandom.next();

				ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${splatterAlpha})';
				ctx.beginPath();
				ctx.arc(splatterX, splatterY, splatterSize, 0, Math.PI * 2);
				ctx.fill();
			}
		}
	}

	static function drawAirbrush(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float):Void {
		// Ultra-realistic airbrush with advanced particle physics and authentic spray dynamics
		var effectiveSize = size * 3.5; // Enhanced spray pattern width
		var sprayIntensity = pressure * brushFlow * 0.15;
		var sprayDensity = pressure * brushOpacity * 1.2;
		var airPressure = Math.pow(pressure, 0.8); // Non-linear pressure response for authentic feel

		final rgbColor = hexToRgb(color);
		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
		final steps = Math.max(1, Math.floor(distance / (brushSpacing * 1.5)));
		final strokeVelocity = distance / Math.max(1, Date.now().getTime() - lastBrushTime);

		ctx.globalCompositeOperation = "source-over";

		for (i in 0...Std.int(steps)) {
			final t = i / steps;
			final sprayX = x1 + t * (x2 - x1);
			final sprayY = y1 + t * (y2 - y1);

			// Advanced multi-ring spray pattern with realistic particle physics
			final sprayRings = 6; // More rings for smoother gradation
			final baseParticleCount = effectiveSize * sprayIntensity * sprayDensity * 4;

			for (ring in 0...sprayRings) {
				final ringRadius = effectiveSize * (ring + 1) / sprayRings;
				final ringDensity = Math.pow(1.0 - ring * 0.18, 2.2); // Natural density falloff
				final ringParticles = Std.int(baseParticleCount * ringDensity / sprayRings);
				final ringIntensity = sprayIntensity * ringDensity;

				for (j in 0...ringParticles) { // Advanced particle distribution with realistic turbulence
					final angle = syncRandom.next() * Math.PI * 2;

					// Multi-octave noise for natural spray patterns
					var particleDistance = 0.0;
					final octaves = 3;
					for (octave in 0...octaves) {
						final octaveWeight = Math.pow(0.5, octave);
						final octaveNoise = (syncRandom.next() - 0.5) * octaveWeight;
						particleDistance += octaveNoise;
					}

					// Normalized distance with realistic distribution
					particleDistance = Math.abs(particleDistance) * ringRadius * 0.9; // Velocity-based spray cone expansion
					final velocitySpread = Math.min(strokeVelocity * 0.4, 1.0);
					final turbulence = (syncRandom.next()
						- 0.5) * brushScatter * 8 * (1 + velocitySpread);

					// Air pressure affects particle spread and velocity
					final pressureSpread = airPressure * (1 + velocitySpread * 0.5);
					final finalDistance = particleDistance * pressureSpread;

					final particleX = sprayX + Math.cos(angle) * finalDistance + turbulence;
					final particleY = sprayY + Math.sin(angle) * finalDistance + turbulence;

					// Realistic particle size physics based on air pressure and distance
					final baseSize = 0.4 + syncRandom.next() * 2.2;
					final distanceFromCenter = Math.sqrt((particleX - sprayX) * (particleX - sprayX)
						+ (particleY - sprayY) * (particleY - sprayY));
					final falloffFactor = Math.max(0, 1
						- (distanceFromCenter / (effectiveSize * 0.8)));

					// Air pressure affects particle atomization (smaller particles at higher pressure)
					final pressureAtomization = 1.0 - (airPressure - 0.3) * 0.4;
					final particleSize = baseSize * Math.max(0.3, pressureAtomization) * (0.6
						+ falloffFactor * 0.7); // Advanced opacity calculation with realistic physics
					final baseOpacity = ringIntensity * falloffFactor * (0.5
						+ syncRandom.next() * 0.5);
					final pressureOpacity = baseOpacity * brushOpacity * airPressure;

					// Paint atomization affects color density
					final densityVariation = syncRandom.next() * 0.12;
					final colorR = Math.floor(rgbColor.r * (1
						+ (syncRandom.next() - 0.5) * densityVariation));
					final colorG = Math.floor(rgbColor.g * (1
						+ (syncRandom.next() - 0.5) * densityVariation));
					final colorB = Math.floor(rgbColor.b * (1
						+ (syncRandom.next() - 0.5) * densityVariation));

					// Only render visible particles
					if (pressureOpacity > 0.01) {
						ctx.fillStyle = 'rgba(${Math.max(0, Math.min(255, colorR))}, ${Math.max(0, Math.min(255, colorG))}, ${Math.max(0, Math.min(255, colorB))}, ${pressureOpacity})';
						ctx.beginPath();
						ctx.arc(particleX, particleY, particleSize, 0, Math.PI * 2);
						ctx.fill();
					}
				}
			}

			// Enhanced central core with pressure-sensitive density
			final coreSize = effectiveSize * 0.18 * airPressure;
			final coreGradient = ctx.createRadialGradient(sprayX, sprayY, 0, sprayX, sprayY, coreSize);
			final coreAlpha = sprayIntensity * brushOpacity * airPressure * 1.1;

			coreGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${coreAlpha})');
			coreGradient.addColorStop(0.3, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${coreAlpha * 0.8})');
			coreGradient.addColorStop(0.7, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${coreAlpha * 0.4})');
			coreGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, 0)');

			ctx.fillStyle = coreGradient;
			ctx.beginPath();
			ctx.arc(sprayX, sprayY, coreSize, 0, Math.PI * 2);
			ctx.fill();

			// Advanced overspray effects for high-pressure applications
			if (airPressure > 0.7) {
				final oversprayCount = Math.floor(airPressure * 6) + 2;
				for (k in 0...oversprayCount) {
					final oversprayAngle = syncRandom.next() * Math.PI * 2;
					final oversprayDistance = (syncRandom.next()
						+ 0.5) * effectiveSize * 1.2 * airPressure;
					final oversprayX = sprayX + Math.cos(oversprayAngle) * oversprayDistance;
					final oversprayY = sprayY + Math.sin(oversprayAngle) * oversprayDistance;

					// Overspray particles are smaller and less opaque
					final overspraySize = syncRandom.next() * 1.8 + 0.4;
					final oversprayAlpha = sprayIntensity * 0.25 * airPressure * syncRandom.next();

					ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${oversprayAlpha})';
					ctx.beginPath();
					ctx.arc(oversprayX, oversprayY, overspraySize, 0, Math.PI * 2);
					ctx.fill();
				}
			} // Paint drip simulation for vertical strokes with high pressure
			if (airPressure > 0.8 && Math.abs(y2 - y1) > Math.abs(x2 - x1)
				&& syncRandom.next() < 0.3) {
				final dripLength = syncRandom.next() * effectiveSize * 0.6 * airPressure;
				final dripX = sprayX + (syncRandom.next() - 0.5) * effectiveSize * 0.3;
				final dripStartY = sprayY;
				final dripEndY = dripStartY + dripLength;

				// Create drip gradient
				final dripGradient = ctx.createLinearGradient(dripX, dripStartY, dripX, dripEndY);
				final dripAlpha = sprayIntensity * 0.4 * airPressure;

				dripGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${dripAlpha})');
				dripGradient.addColorStop(0.8, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${dripAlpha * 0.5})');
				dripGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, 0)');

				ctx.strokeStyle = dripGradient;
				ctx.lineWidth = syncRandom.next() * 2 + 0.5;
				ctx.lineCap = "round";

				ctx.beginPath();
				ctx.moveTo(dripX, dripStartY);
				ctx.lineTo(dripX, dripEndY);
				ctx.stroke();
			}
		}
	}

	static function drawMarker(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float):Void {
		// Ultra-realistic felt tip marker with advanced fiber physics and authentic ink flow
		var effectiveSize = size;
		var baseAlpha = 0.85 * brushOpacity; // Markers are very opaque

		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			// Markers are very sensitive to pressure variations
			effectiveSize = size * (0.2 + pressure * 1.1);
			baseAlpha = (0.4 + pressure * 0.8) * brushOpacity;
		}

		final rgbColor = hexToRgb(color);
		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
		final strokeVelocity = distance / Math.max(1, Date.now().getTime() - lastBrushTime);

		// Calculate stroke angle for chisel tip orientation
		final strokeAngle = Math.atan2(y2 - y1, x2 - x1);
		final perpAngle = strokeAngle + Math.PI / 2;

		ctx.globalCompositeOperation = "multiply";

		// Advanced felt tip fiber simulation with realistic ink distribution
		final fiberDensity = Math.floor(effectiveSize * 1.2) + 5; // More fibers for realism
		final fiberSpread = effectiveSize * 1.1;

		// Create multiple fiber layers for depth
		final fiberLayers = 3;
		for (layer in 0...fiberLayers) {
			final layerOffset = layer * 0.3;
			final layerAlpha = baseAlpha * (1 - layer * 0.2) / fiberLayers;

			for (i in 0...Std.int(fiberDensity)) {
				final fiberPos = (i - fiberDensity / 2) / (fiberDensity / 2); // -1 to 1
				final fiberOffset = fiberPos * fiberSpread * 0.45; // Advanced chisel effect - realistic ink concentration profile
				final distanceFromCenter = Math.abs(fiberPos);
				final chiselProfile = Math.pow(1.0 - distanceFromCenter, 1.5); // Smooth falloff
				final inkLoad = Math.max(0.2, chiselProfile) * (0.7 + syncRandom.next() * 0.6);

				// Felt tip fiber physics - fibers bend and spread under pressure
				final fiberBend = pressure * strokeVelocity * 0.8;
				final fiberSpread = Math.max(0.1, pressure * 1.2);

				// Calculate realistic fiber positions with authentic bending
				final fiberNoise = (syncRandom.next() - 0.5) * fiberSpread;
				final bendOffset = fiberBend * (syncRandom.next() - 0.5);

				final fiberX1 = x1
					+ Math.cos(perpAngle) * (fiberOffset + fiberNoise)
					+ layerOffset;
				final fiberY1 = y1
					+ Math.sin(perpAngle) * (fiberOffset + fiberNoise)
					+ layerOffset;
				final fiberX2 = x2
					+ Math.cos(perpAngle) * (fiberOffset + fiberNoise * 0.6 + bendOffset);
				final fiberY2 = y2
					+ Math.sin(perpAngle) * (fiberOffset + fiberNoise * 0.6 + bendOffset);

				// Realistic fiber thickness and ink deposition
				final fiberThickness = effectiveSize * 0.08 * inkLoad * (1 + pressure * 0.4);
				final fiberAlpha = layerAlpha * inkLoad * (0.6 + pressure * 0.5);

				ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${fiberAlpha})';
				ctx.lineWidth = fiberThickness;
				ctx.lineCap = "round";
				ctx.lineJoin = "round";

				ctx.beginPath();
				ctx.moveTo(fiberX1, fiberY1);
				ctx.lineTo(fiberX2, fiberY2);
				ctx.stroke();
			}
		}

		// Advanced ink bleeding with paper fiber simulation
		if (pressure > 0.4) {
			final bleedSteps = Math.max(3, Math.floor(distance / 1.8));
			for (i in 0...Std.int(bleedSteps)) {
				final t = i / bleedSteps;
				final bleedX = x1 + t * (x2 - x1);
				final bleedY = y1 + t * (y2 - y1);

				// Ink capillary action through paper fibers
				final capillaryCount = Math.floor(pressure * 8) + 3;
				for (j in 0...capillaryCount) {
					final capillaryAngle = syncRandom.next() * Math.PI * 2;
					final capillaryLength = syncRandom.next() * effectiveSize * 0.6 * pressure;

					// Multi-step capillary bleeding for authentic effect
					final bleedSteps2 = Math.floor(capillaryLength / 2) + 2;
					for (k in 0...Std.int(bleedSteps2)) {
						final bleedT = k / bleedSteps2;
						final capillaryX = bleedX
							+ Math.cos(capillaryAngle) * capillaryLength * bleedT;
						final capillaryY = bleedY
							+ Math.sin(capillaryAngle) * capillaryLength * bleedT;

						final bleedSize = Math.max(0.2, syncRandom.next() * 2.0 * (1 - bleedT));
						final bleedAlpha = baseAlpha * 0.25 * pressure * (1
							- bleedT) * syncRandom.next();

						ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${bleedAlpha})';
						ctx.beginPath();
						ctx.arc(capillaryX, capillaryY, bleedSize, 0, Math.PI * 2);
						ctx.fill();
					}
				}
			}
		}

		// Premium chisel tip main stroke with authentic flat profile
		final mainStrokeAlpha = baseAlpha * 0.95;
		final mainStrokeSize = effectiveSize * (0.7 + pressure * 0.5);

		// Create chisel gradient for realistic tip profile
		final tipGradient = ctx.createLinearGradient(x1
			- Math.cos(perpAngle) * mainStrokeSize * 0.5,
			y1
			- Math.sin(perpAngle) * mainStrokeSize * 0.5,
			x1
			+ Math.cos(perpAngle) * mainStrokeSize * 0.5,
			y1
			+ Math.sin(perpAngle) * mainStrokeSize * 0.5);
		tipGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${mainStrokeAlpha * 0.6})');
		tipGradient.addColorStop(0.5, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${mainStrokeAlpha})');
		tipGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${mainStrokeAlpha * 0.6})');

		ctx.strokeStyle = tipGradient;
		ctx.lineWidth = mainStrokeSize;
		ctx.lineCap = "square"; // Flat marker tip
		ctx.lineJoin = "miter";

		ctx.beginPath();
		ctx.moveTo(x1, y1);
		ctx.lineTo(x2, y2);
		ctx.stroke();
		// Advanced dry marker effect with realistic fiber separation
		if (pressure < 0.5 && syncRandom.next() < 0.8) {
			final dryStreakCount = Math.floor(effectiveSize * 0.4) + 3;
			for (i in 0...dryStreakCount) {
				final streakPos = (syncRandom.next() - 0.5) * effectiveSize * 0.9;
				final streakGap = syncRandom.next() * effectiveSize * 0.2; // Random gaps

				final streakX1 = x1 + Math.cos(perpAngle) * streakPos;
				final streakY1 = y1 + Math.sin(perpAngle) * streakPos;
				final streakX2 = x2 + Math.cos(perpAngle) * streakPos;
				final streakY2 = y2 + Math.sin(perpAngle) * streakPos;

				// Create realistic fiber separation gaps
				if (syncRandom.next() < 0.5) continue; // Skip some streaks

				// Multi-segment streak for natural dry marker texture
				final streakSegments = Math.floor(distance / 3) + 2;
				for (seg in 0...Std.int(streakSegments)) {
					if (syncRandom.next() < 0.3) continue; // Random gaps in streaks

					final segT1 = seg / streakSegments;
					final segT2 = Math.min(1.0, (seg + 0.7) / streakSegments);

					final segX1 = streakX1 + segT1 * (streakX2 - streakX1);
					final segY1 = streakY1 + segT1 * (streakY2 - streakY1);
					final segX2 = streakX1 + segT2 * (streakX2 - streakX1);
					final segY2 = streakY1 + segT2 * (streakY2 - streakY1);

					final streakAlpha = baseAlpha * 0.4 * (1 - pressure) * syncRandom.next();
					final streakSize = effectiveSize * 0.06;

					ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${streakAlpha})';
					ctx.lineWidth = streakSize;
					ctx.lineCap = "round";

					ctx.beginPath();
					ctx.moveTo(segX1, segY1);
					ctx.lineTo(segX2, segY2);
					ctx.stroke();
				}
			}
		}

		// Ink pooling effect for heavy pressure and slow strokes
		if (pressure > 0.7 && strokeVelocity < 0.2) {
			final poolSteps = Math.floor(distance / 4) + 1;
			for (i in 0...Std.int(poolSteps)) {
				final t = i / poolSteps;
				final poolX = x1 + t * (x2 - x1);
				final poolY = y1 + t * (y2 - y1);

				// Create ink pool with realistic spreading
				final poolRadius = effectiveSize * pressure * 0.35;
				final poolAlpha = baseAlpha * 0.2 * pressure;

				final poolGradient = ctx.createRadialGradient(poolX, poolY, 0, poolX, poolY, poolRadius);
				poolGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${poolAlpha})');
				poolGradient.addColorStop(0.7, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${poolAlpha * 0.5})');
				poolGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, 0)');

				ctx.fillStyle = poolGradient;
				ctx.beginPath();
				ctx.arc(poolX, poolY, poolRadius, 0, Math.PI * 2);
				ctx.fill();
			}
		}

		// Final overlay for marker transparency and color blending
		final overlayAlpha = baseAlpha * 0.3;
		ctx.globalCompositeOperation = "source-over";

		// Subtle transparency overlay with chisel profile
		final overlayGradient = ctx.createLinearGradient(x1
			- Math.cos(perpAngle) * effectiveSize * 0.5,
			y1
			- Math.sin(perpAngle) * effectiveSize * 0.5,
			x1
			+ Math.cos(perpAngle) * effectiveSize * 0.5,
			y1
			+ Math.sin(perpAngle) * effectiveSize * 0.5);
		overlayGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${overlayAlpha * 0.5})');
		overlayGradient.addColorStop(0.5, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${overlayAlpha})');
		overlayGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${overlayAlpha * 0.5})');

		ctx.strokeStyle = overlayGradient;
		ctx.lineWidth = effectiveSize * 0.8;
		ctx.lineCap = "square";
		ctx.lineJoin = "miter";

		ctx.beginPath();
		ctx.moveTo(x1, y1);
		ctx.lineTo(x2, y2);
		ctx.stroke();
	}

	static function drawPencil(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float):Void {
		// Ultra-realistic graphite pencil with authentic paper grain interaction
		var effectiveSize = size * 0.75;
		var baseAlpha = 0.85 * brushOpacity;

		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			// More sensitive pressure response for authentic pencil feel
			effectiveSize = size * (0.1 + pressure * 0.8);
			baseAlpha = (0.2 + pressure * 0.7) * brushOpacity;
		}

		final rgbColor = hexToRgb(color);
		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));

		// Calculate stroke angle for directional graphite deposits
		final strokeAngle = Math.atan2(y2 - y1, x2 - x1);
		final perpAngle = strokeAngle + Math.PI / 2;

		// Enhanced paper tooth simulation - much higher detail
		final grainSteps = Math.max(5, Math.floor(distance / 0.25));

		ctx.globalCompositeOperation = "multiply";
		ctx.lineCap = "round";
		ctx.lineJoin = "round";

		// Create authentic paper fiber texture with enhanced realism
		for (i in 0...Std.int(grainSteps)) {
			final t = i / grainSteps;
			final baseX = x1 + t * (x2 - x1);
			final baseY = y1 + t * (y2 - y1);

			// Multi-octave paper texture simulation (like real paper fibers)
			final grain1 = Math.sin(baseX * 0.4
				+ baseY * 0.35) * Math.cos(baseX * 0.8 - baseY * 0.6);
			final grain2 = Math.sin(baseX * 1.3
				+ baseY * 0.95) * Math.cos(baseX * 1.1 + baseY * 1.25);
			final grain3 = Math.sin(baseX * 3.2
				- baseY * 2.4) * Math.cos(baseX * 3.8 + baseY * 3.1);
			final grain4 = Math.sin(baseX * 6.1
				+ baseY * 4.7) * Math.cos(baseX * 5.9 - baseY * 5.3);

			// Weighted combination for realistic paper texture
			final paperTooth = (grain1 * 0.5
				+ grain2 * 0.3
				+ grain3 * 0.15
				+ grain4 * 0.05) * brushTexture * 2.2;

			// Paper valleys and peaks - graphite settles in valleys
			final toothHeight = 0.5 + paperTooth * 0.6;
			final graphiteCatch = Math.max(0, toothHeight
				+ pressure * 0.5); // Only deposit graphite where pencil catches paper
			if (syncRandom.next() < graphiteCatch) {
				// Calculate fiber direction influence
				final fiberDirection = Math.sin(baseX * 0.15) * Math.cos(baseY * 0.18);
				final fiberX = Math.cos(perpAngle + fiberDirection * 0.3) * paperTooth * 1.5;
				final fiberY = Math.sin(perpAngle + fiberDirection * 0.3) * paperTooth * 1.5;

				final grainX = baseX + fiberX + (syncRandom.next() - 0.5) * 0.6;
				final grainY = baseY + fiberY + (syncRandom.next() - 0.5) * 0.6;

				// Realistic graphite particle clusters
				final particleCount = Math.floor(pressure * 6) + 2;
				for (j in 0...particleCount) {
					final clusterSpread = effectiveSize * 0.15;
					final particleX = grainX + (syncRandom.next() - 0.5) * clusterSpread;
					final particleY = grainY + (syncRandom.next() - 0.5) * clusterSpread;

					// Graphite particle size based on pressure and paper texture
					final particleSize = effectiveSize * (0.02 +
						syncRandom.next() * 0.08) * Math.max(0.3, pressure) * toothHeight; // Graphite deposition varies with pressure and paper contact
					final depositIntensity = baseAlpha * graphiteCatch * (0.6
						+ syncRandom.next() * 0.5) * (0.7 + pressure * 0.5);

					// Add graphite crystal shine effect
					final crystalShine = syncRandom.next();
					var particleAlpha = depositIntensity;
					if (crystalShine > 0.92 && pressure > 0.8) {
						// Bright graphite crystal reflection
						particleAlpha *= 1.4;
					} else if (crystalShine < 0.2) {
						// Dark graphite clumping
						particleAlpha *= 0.6;
					}

					// Create micro-streak for graphite particle direction
					final streakLength = syncRandom.next() * 0.8 + 0.2;
					final streakAngle = strokeAngle + (syncRandom.next() - 0.5) * 0.4;
					final streakEndX = particleX + Math.cos(streakAngle) * streakLength;
					final streakEndY = particleY + Math.sin(streakAngle) * streakLength;

					ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${particleAlpha})';
					ctx.lineWidth = particleSize;

					ctx.beginPath();
					ctx.moveTo(particleX, particleY);
					ctx.lineTo(streakEndX, streakEndY);
					ctx.stroke();
				}
			}
		}

		// Enhanced graphite core with realistic density variation
		final coreSteps = Math.max(3, Math.floor(distance / 0.8));
		for (i in 0...Std.int(coreSteps)) {
			final t = i / coreSteps;
			final nextT = Math.min(1.0, (i + 1) / coreSteps);

			final startX = x1 + t * (x2 - x1);
			final startY = y1 + t * (y2 - y1);
			final endX = x1 + nextT * (x2 - x1);
			final endY = y1 + nextT * (y2 - y1);

			// Graphite hardness simulation - harder pencils are more consistent
			final hardness = 0.7; // Simulate HB pencil hardness
			final consistencyVariation = (1 - hardness) * 0.4;
			final coreDensity = 0.8
				+ (syncRandom.next() - 0.5) * consistencyVariation
				+ pressure * 0.3;

			final coreAlpha = baseAlpha * Math.max(0.3, coreDensity) * 0.7;
			final coreSize = effectiveSize * (0.6
				+ pressure * 0.5) * Math.max(0.5, coreDensity);

			ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${coreAlpha})';
			ctx.lineWidth = coreSize;

			ctx.beginPath();
			ctx.moveTo(startX, startY);
			ctx.lineTo(endX, endY);
			ctx.stroke();
		}
		// Add graphite metallic reflection (very important for realism)
		if (pressure > 0.6 && syncRandom.next() < 0.5) {
			final reflectionIntensity = (pressure - 0.6) * 2.5; // Scale to 0-1
			final sheenAlpha = baseAlpha * 0.12 * reflectionIntensity;
			final sheenSize = effectiveSize * 0.25;

			// Multiple reflection layers for authentic graphite shine
			for (layer in 0...2) {
				final layerOffset = layer * 0.3;
				final layerAlpha = sheenAlpha * (1 - layer * 0.4);

				ctx.globalCompositeOperation = "screen";
				ctx.strokeStyle = 'rgba(${240 - layer * 20}, ${240 - layer * 20}, ${240 - layer * 20}, ${layerAlpha})';
				ctx.lineWidth = sheenSize * (1 + layerOffset);

				ctx.beginPath();
				ctx.moveTo(x1 + layerOffset, y1 + layerOffset);
				ctx.lineTo(x2 + layerOffset, y2 + layerOffset);
				ctx.stroke();
			}

			ctx.globalCompositeOperation = "multiply"; // Reset blend mode
		}
		// Add pencil drag texture for very light pressure (barely touching paper)
		if (pressure < 0.3 && syncRandom.next() < 0.6) {
			final dragSteps = Math.floor(distance / 1.2) + 1;
			for (i in 0...Std.int(dragSteps)) {
				final t = i / dragSteps;
				final dragX = x1
					+ t * (x2 - x1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 0.8;
				final dragY = y1
					+ t * (y2 - y1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 0.8;

				// Light graphite touches only paper peaks
				if (syncRandom.next() < 0.3) {
					final dragSize = effectiveSize * 0.05 * syncRandom.next();
					final dragAlpha = baseAlpha * 0.4 * pressure * syncRandom.next();

					ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${dragAlpha})';
					ctx.beginPath();
					ctx.arc(dragX, dragY, dragSize, 0, Math.PI * 2);
					ctx.fill();
				}
			}
		}
	}

	static function drawCharcoal(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float):Void {
		// Ultra-realistic charcoal with authentic paper tooth interaction and organic texture
		var effectiveSize = size * 1.6;
		var baseAlpha = 0.75 * brushOpacity;

		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			// Charcoal is very responsive to pressure
			effectiveSize = size * (0.5 + pressure * 1.2);
			baseAlpha = (0.4 + pressure * 0.7) * brushOpacity;
		}

		final rgbColor = hexToRgb(color);
		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));

		// Calculate stroke direction for charcoal grain orientation
		final strokeAngle = Math.atan2(y2 - y1, x2 - x1);
		final perpAngle = strokeAngle + Math.PI / 2;

		ctx.globalCompositeOperation = "multiply";

		// Advanced paper tooth simulation - charcoal catches on fiber peaks and valleys
		final paperToothSteps = Math.max(8, Math.floor(distance / 0.3));
		for (i in 0...Std.int(paperToothSteps)) {
			final t = i / paperToothSteps;
			final baseX = x1 + t * (x2 - x1);
			final baseY = y1 + t * (y2 - y1);

			// Multi-layer paper texture simulation for authentic feel
			final noise1 = Math.sin(baseX * 0.35
				+ baseY * 0.28) * Math.cos(baseX * 0.73 - baseY * 0.51);
			final noise2 = Math.sin(baseX * 1.17
				+ baseY * 0.94) * Math.cos(baseX * 1.33 + baseY * 1.28);
			final noise3 = Math.sin(baseX * 2.91
				- baseY * 2.15) * Math.cos(baseX * 3.42 + baseY * 2.87);
			final noise4 = Math.sin(baseX * 5.23
				+ baseY * 4.61) * Math.cos(baseX * 6.11 - baseY * 5.77);

			// Weighted combination creating realistic paper fiber pattern
			final paperTooth = (noise1 * 0.45
				+ noise2 * 0.3
				+ noise3 * 0.15
				+ noise4 * 0.1) * brushTexture;

			// Paper height variation - charcoal deposits differently on peaks vs valleys
			final paperHeight = 0.5 + paperTooth * 0.7;
			final charcoalContact = Math.max(0, paperHeight
				+ pressure * 0.6
				- 0.3); // Only deposit charcoal where it physically contacts paper
			if (syncRandom.next() < charcoalContact * 1.2) {
				// Create realistic charcoal particle clusters with directional grain
				final clusterDensity = Math.floor(effectiveSize * 0.5 * charcoalContact) + 3;
				for (j in 0...Std.int(clusterDensity)) {
					final clusterSpread = effectiveSize * 0.4;
					final scatterX = baseX + (syncRandom.next() - 0.5) * clusterSpread;
					final scatterY = baseY + (syncRandom.next() - 0.5) * clusterSpread;

					// Charcoal particles follow stroke direction with natural variation
					final particleDirection = strokeAngle + (syncRandom.next() - 0.5) * 0.6;
					final particleLength = (0.5
						+ syncRandom.next() * 2.5) * pressure * charcoalContact;

					// Charcoal streak end position
					final streakEndX = scatterX + Math.cos(particleDirection) * particleLength;
					final streakEndY = scatterY
						+
						Math.sin(particleDirection) * particleLength; // Particle properties based on pressure and paper contact
					final particleSize = (0.3
						+ syncRandom.next() * 1.8) * pressure * charcoalContact * (1
							+ paperHeight * 0.3);
					final particleIntensity = baseAlpha * charcoalContact * (0.6
						+ syncRandom.next() * 0.6) * brushTexture;

					// Add charcoal density variation for organic look
					final densityVariation = 0.7 + syncRandom.next() * 0.5;
					final finalIntensity = particleIntensity * densityVariation;

					ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${finalIntensity})';
					ctx.lineWidth = particleSize;
					ctx.lineCap = "round";

					ctx.beginPath();
					ctx.moveTo(scatterX, scatterY);
					ctx.lineTo(streakEndX, streakEndY);
					ctx.stroke();
				}
			}
		}

		// Charcoal main body with organic edge variation and natural texture
		final bodySteps = Math.max(4, Math.floor(distance / 1.0));
		for (i in 0...Std.int(bodySteps)) {
			final t = i / bodySteps;
			final nextT = Math.min(1.0, (i
				+ 1) / bodySteps); // Create organic, irregular edges typical of charcoal
			final edgeVariation1 = Math.sin(t * distance * 0.3) * effectiveSize * 0.3;
			final edgeVariation2 = (syncRandom.next() - 0.5) * effectiveSize * 0.5;
			final totalVariation = edgeVariation1 + edgeVariation2;

			final perpOffsetX = Math.cos(perpAngle) * totalVariation;
			final perpOffsetY = Math.sin(perpAngle) * totalVariation;

			final startX = x1 + t * (x2 - x1) + perpOffsetX;
			final startY = y1 + t * (y2 - y1) + perpOffsetY;
			final endX = x1 + nextT * (x2 - x1) + perpOffsetX * 0.8;
			final endY = y1 + nextT * (y2 - y1) + perpOffsetY * 0.8;

			// Charcoal density varies naturally based on pressure and material breakdown
			final materialDensity = 0.6 + syncRandom.next() * 0.6 + pressure * 0.4;
			final segmentAlpha = baseAlpha * materialDensity * 0.85;
			final segmentSize = effectiveSize * (0.8 + pressure * 0.5) * materialDensity;

			ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${segmentAlpha})';
			ctx.lineWidth = segmentSize;
			ctx.lineCap = "round";
			ctx.lineJoin = "round";

			ctx.beginPath();
			ctx.moveTo(startX, startY);
			ctx.lineTo(endX, endY);
			ctx.stroke();
		}

		// Charcoal dust and debris - characteristic of real charcoal drawing
		if (pressure > 0.6) {
			final dustCloud = Math.floor(pressure * distance * 0.15) + 3;
			for (i in 0...Std.int(dustCloud)) { // Dust spreads wider than the main stroke
				final dustSpread = effectiveSize * 2.0;
				final dustX = x1
					+ syncRandom.next() * (x2 - x1)
					+ (syncRandom.next() - 0.5) * dustSpread;
				final dustY = y1
					+ syncRandom.next() * (y2 - y1)
					+ (syncRandom.next() - 0.5) * dustSpread;

				final dustSize = syncRandom.next() * 1.8 + 0.2;
				final dustAlpha = baseAlpha * 0.25 * syncRandom.next() * pressure * brushTexture;

				// Slight color variation in charcoal dust for realism
				final dustVariation = 0.1;
				final dustR = Math.floor(rgbColor.r * (1
					+ (syncRandom.next() - 0.5) * dustVariation));
				final dustG = Math.floor(rgbColor.g * (1
					+ (syncRandom.next() - 0.5) * dustVariation));
				final dustB = Math.floor(rgbColor.b * (1
					+ (syncRandom.next() - 0.5) * dustVariation));

				ctx.fillStyle = 'rgba(${Math.max(0, Math.min(255, dustR))}, ${Math.max(0, Math.min(255, dustG))}, ${Math.max(0, Math.min(255, dustB))}, ${dustAlpha})';
				ctx.beginPath();
				ctx.arc(dustX, dustY, dustSize, 0, Math.PI * 2);
				ctx.fill();
			}
		}

		// Side-stroke effect for flat charcoal drawing (when charcoal is held sideways)
		if (brushScatter > 0.5 && pressure > 0.4) {
			final sideStrokeWidth = effectiveSize * 3.2;
			final sideStrokeAlpha = baseAlpha * 0.25 * brushScatter * pressure;

			// Create multiple overlapping flat strokes for natural variation
			final flatLayers = 3;
			for (layer in 0...flatLayers) {
				final layerOffset = (layer - 1) * 0.8;
				final layerAlpha = sideStrokeAlpha * (1 - layer * 0.2) / flatLayers;
				final layerWidth = sideStrokeWidth * (1 + layer * 0.1);

				ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${layerAlpha})';
				ctx.lineWidth = layerWidth;
				ctx.lineCap = "round";
				ctx.lineJoin = "round";

				ctx.beginPath();
				ctx.moveTo(x1 + layerOffset, y1 + layerOffset);
				ctx.lineTo(x2 + layerOffset, y2 + layerOffset);
				ctx.stroke();
			}
		}
		// Charcoal smudging effect for heavy pressure
		if (pressure > 0.8 && syncRandom.next() < 0.4) {
			final smudgeLength = effectiveSize * 1.5;
			final smudgeDirection = strokeAngle + (syncRandom.next() - 0.5) * 0.8;

			final smudgeSteps = Math.floor(smudgeLength / 2) + 2;
			for (i in 0...Std.int(smudgeSteps)) {
				final smudgeDistance = (i / smudgeSteps) * smudgeLength;
				final smudgeX = x2 + Math.cos(smudgeDirection) * smudgeDistance;
				final smudgeY = y2 + Math.sin(smudgeDirection) * smudgeDistance;

				final smudgeSize = effectiveSize * (1 - i / smudgeSteps) * 0.3;
				final smudgeAlpha = baseAlpha * (1 - i / smudgeSteps) * 0.2 * pressure;

				ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${smudgeAlpha})';
				ctx.beginPath();
				ctx.arc(smudgeX, smudgeY, smudgeSize, 0, Math.PI * 2);
				ctx.fill();
			}
		}
	}

	static function drawWatercolor(x1:Float, y1:Float, x2:Float, y2:Float, color:String, size:Float, pressure:Float):Void {
		// Professional watercolor with authentic wet-on-wet behavior and pigment physics
		var effectiveSize = size * 2.2;
		var baseAlpha = 0.35 * brushOpacity;
		var waterLoad = pressure * brushFlow * 1.2; // Enhanced water responsiveness

		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			effectiveSize = size * (0.6 + pressure * 1.6);
			baseAlpha = (0.15 + pressure * 0.4) * brushOpacity;
			waterLoad = Math.min(1.0, waterLoad * (0.7 + pressure * 0.5));
		}

		final rgbColor = hexToRgb(color);
		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));

		ctx.globalCompositeOperation = "multiply";

		// Advanced watercolor bleeding with surface tension simulation
		final bleedLayers = 6; // More layers for smoother gradients
		for (layer in 0...bleedLayers) {
			final layerSize = effectiveSize * (1 + layer * 0.8);
			final layerIntensity = waterLoad * (1 - layer * 0.18);
			final layerAlpha = baseAlpha * (1 - layer * 0.15) / bleedLayers;

			// Create organic bleeding with irregular edges
			final bleedSteps = Math.max(3, Math.floor(distance / 1.5));
			for (i in 0...Std.int(bleedSteps)) {
				final t = i / bleedSteps;
				final centerX = x1 + t * (x2 - x1);
				final centerY = y1 + t * (y2 - y1);

				// Simulate water surface tension creating circular spreads
				final spreadRadius = layerSize * layerIntensity * 0.85;

				// Create multiple concentric rings for natural water spread
				final ringCount = Math.floor(spreadRadius / 3) + 3;
				for (j in 0...ringCount) {
					final ringRatio = j / ringCount;
					final ringRadius = spreadRadius * ringRatio;
					final ringAlpha = layerAlpha * (1 - ringRatio * 0.7) * layerIntensity;

					// Add organic irregularity to water spread using noise
					final noisePoints = 16;
					ctx.beginPath();
					for (k in 0...noisePoints) {
						final angle = (k / noisePoints) * Math.PI * 2;

						// Multi-octave noise for natural water edge variation
						final noise1 = Math.sin(angle * 3 + centerX * 0.01) * 0.3;
						final noise2 = Math.sin(angle * 7 - centerY * 0.01) * 0.15;
						final noise3 = Math.sin(angle * 13 + (centerX + centerY) * 0.005) * 0.08;
						final totalNoise = noise1 + noise2 + noise3;

						final radiusVariation = 1 + totalNoise + (syncRandom.next() - 0.5) * 0.2;
						final irregularRadius = ringRadius * radiusVariation;

						final pointX = centerX + Math.cos(angle) * irregularRadius;
						final pointY = centerY + Math.sin(angle) * irregularRadius;

						if (k == 0) {
							ctx.moveTo(pointX, pointY);
						} else {
							ctx.lineTo(pointX, pointY);
						}
					}
					ctx.closePath();

					ctx.fillStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${ringAlpha})';
					ctx.fill();
				}
			}
		}

		// Enhanced pigment granulation with realistic settling
		if (brushTexture > 0.3) {
			final granulationDensity = brushTexture * waterLoad;
			final granulationSteps = Math.floor(distance / 1.0) + 4;
			for (i in 0...Std.int(granulationSteps)) {
				final t = i / granulationSteps;
				final grainCenterX = x1
					+ t * (x2 - x1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 0.9;
				final grainCenterY = y1
					+ t * (y2 - y1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 0.9;

				// Simulate pigment particles settling based on paper texture
				final settlementPattern = Math.sin(grainCenterX * 0.03) * Math.cos(grainCenterY * 0.025);
				final settlementIntensity = Math.max(0.3, 0.7 + settlementPattern * 0.4);

				if (syncRandom.next() < granulationDensity * settlementIntensity) {
					final clusterSize = Math.floor(syncRandom.next() * 6) + 3;
					for (j in 0...clusterSize) {
						final clusterSpread = 4.0;
						final clusterX = grainCenterX + (syncRandom.next() - 0.5) * clusterSpread;
						final clusterY = grainCenterY + (syncRandom.next() - 0.5) * clusterSpread;

						final grainSize = syncRandom.next() * 2.2 + 0.4;
						final grainAlpha = baseAlpha * 0.7 * brushTexture * syncRandom.next() * settlementIntensity; // Pigment color variation for realistic granulation
						final colorShift = 0.12;
						final shiftR = Math.floor(rgbColor.r * (1
							+ (syncRandom.next() - 0.5) * colorShift));
						final shiftG = Math.floor(rgbColor.g * (1
							+ (syncRandom.next() - 0.5) * colorShift));
						final shiftB = Math.floor(rgbColor.b * (1
							+ (syncRandom.next() - 0.5) * colorShift));

						ctx.fillStyle = 'rgba(${Math.max(0, Math.min(255, shiftR))}, ${Math.max(0, Math.min(255, shiftG))}, ${Math.max(0, Math.min(255, shiftB))}, ${grainAlpha})';
						ctx.beginPath();
						ctx.arc(clusterX, clusterY, grainSize, 0, Math.PI * 2);
						ctx.fill();
					}
				}
			}
		}
		// Realistic watercolor blooms and backruns
		if (waterLoad > 0.5 && syncRandom.next() < 0.5) {
			final bloomCount = Math.floor(syncRandom.next() * 4) + 1;
			for (i in 0...bloomCount) {
				final bloomX = x1
					+ syncRandom.next() * (x2 - x1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 1.2;
				final bloomY = y1
					+ syncRandom.next() * (y2 - y1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 1.2;
				final bloomSize = effectiveSize * (0.4 + syncRandom.next() * 0.6) * waterLoad;

				// Create bloom as water pushing pigment outward
				final bloomRings = 4;
				for (ring in 0...bloomRings) {
					final ringRadius = bloomSize * (ring + 1) / bloomRings;
					final ringIntensity = waterLoad * (1 - ring * 0.2);

					// Bloom creates lighter areas by diluting pigment
					ctx.globalCompositeOperation = "destination-out";

					final bloomAlpha = baseAlpha * 0.25 * ringIntensity / bloomRings;
					ctx.fillStyle = 'rgba(0,0,0,${bloomAlpha})';
					ctx.beginPath();
					ctx.arc(bloomX, bloomY, ringRadius, 0, Math.PI * 2);
					ctx.fill();
				}

				// Add subtle pigment ring around bloom edge
				ctx.globalCompositeOperation = "multiply";
				final edgeAlpha = baseAlpha * 0.3 * waterLoad;
				ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${edgeAlpha})';
				ctx.lineWidth = 1.5;
				ctx.beginPath();
				ctx.arc(bloomX, bloomY, bloomSize * 0.9, 0, Math.PI * 2);
				ctx.stroke();
			}

			ctx.globalCompositeOperation = "multiply"; // Reset blend mode
		}

		// Main brush stroke with natural water flow variation
		final coreSteps = Math.max(3, Math.floor(distance / 1.2));
		for (i in 0...Std.int(coreSteps)) {
			final t = i / coreSteps;
			final nextT = Math.min(1.0, (i + 1) / coreSteps);

			final startX = x1 + t * (x2 - x1);
			final startY = y1 + t * (y2 - y1);
			final endX = x1 + nextT * (x2 - x1);
			final endY = y1
				+ nextT * (y2 - y1); // Water and pigment concentration varies along stroke
			final flowVariation = Math.sin(t * Math.PI * 4) * 0.2 + 1;
			final strokeIntensity = waterLoad * flowVariation * (0.8 + syncRandom.next() * 0.3);
			final strokeAlpha = baseAlpha * strokeIntensity;
			final strokeSize = effectiveSize * (0.7 + strokeIntensity * 0.4);

			ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${strokeAlpha})';
			ctx.lineWidth = strokeSize;
			ctx.lineCap = "round";
			ctx.lineJoin = "round";

			ctx.beginPath();
			ctx.moveTo(startX, startY);
			ctx.lineTo(endX, endY);
			ctx.stroke();
		}
		// Water droplet formation and drips for very wet applications
		if (waterLoad > 0.8 && syncRandom.next() < 0.4) {
			final dropletCount = Math.floor(syncRandom.next() * 3) + 1;
			for (i in 0...dropletCount) {
				final dropletX = x1
					+ syncRandom.next() * (x2 - x1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 1.8;
				final dropletY = y1
					+ syncRandom.next() * (y2 - y1)
					+ (syncRandom.next() - 0.5) * effectiveSize * 1.8;

				// Create realistic water droplet with meniscus effect
				final dropletSize = syncRandom.next() * effectiveSize * 0.2 + 1.0;
				final dropletAlpha = baseAlpha * 0.5 * syncRandom.next() * waterLoad;

				// Droplet gradient for 3D water effect
				final dropletGradient = ctx.createRadialGradient(
					dropletX - dropletSize * 0.3, dropletY - dropletSize * 0.3, 0,
					dropletX, dropletY, dropletSize
				);
				dropletGradient.addColorStop(0, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${dropletAlpha * 0.3})');
				dropletGradient.addColorStop(0.7, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${dropletAlpha})');
				dropletGradient.addColorStop(1, 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${dropletAlpha * 1.2})');

				ctx.fillStyle = dropletGradient;
				ctx.beginPath();
				ctx.arc(dropletX, dropletY, dropletSize, 0, Math.PI * 2);
				ctx.fill();

				// Add droplet highlight for water surface reflection
				ctx.fillStyle = 'rgba(255, 255, 255, ${dropletAlpha * 0.15})';
				ctx.beginPath();
				ctx.arc(dropletX
					- dropletSize * 0.4, dropletY
					- dropletSize * 0.4, dropletSize * 0.3, 0, Math.PI * 2);
				ctx.fill();
			}
		}

		// Wet-on-wet color bleeding simulation
		if (waterLoad > 0.6) {
			final bleedingSteps = Math.floor(distance / 2.5) + 2;
			for (i in 0...Std.int(bleedingSteps)) {
				final t = i / bleedingSteps;
				final bleedX = x1 + t * (x2 - x1);
				final bleedY = y1 + t * (y2 - y1); // Color spreads in random directions when wet
				final bleedDirections = Math.floor(syncRandom.next() * 3) + 2;
				for (j in 0...bleedDirections) {
					final bleedAngle = syncRandom.next() * Math.PI * 2;
					final bleedDistance = syncRandom.next() * effectiveSize * 0.6 * waterLoad;
					final bleedEndX = bleedX + Math.cos(bleedAngle) * bleedDistance;
					final bleedEndY = bleedY + Math.sin(bleedAngle) * bleedDistance;

					final bleedAlpha = baseAlpha * 0.3 * waterLoad * syncRandom.next();
					final bleedSize = syncRandom.next() * 2.5 + 0.8;

					ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${bleedAlpha})';
					ctx.lineWidth = bleedSize;
					ctx.lineCap = "round";

					ctx.beginPath();
					ctx.moveTo(bleedX, bleedY);
					ctx.lineTo(bleedEndX, bleedEndY);
					ctx.stroke();
				}
			}
		}
	}

	static function drawEraser(x1:Float, y1:Float, x2:Float, y2:Float, size:Float, pressure:Float):Void {
		// Ultra-realistic eraser with authentic rubber texture, advanced crumb physics, and selective erasing
		var effectiveSize = size;
		var baseIntensity = 1.0;

		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			// Erasers respond very sensitively to pressure
			effectiveSize = size * (0.1 + pressure * 1.0);
			baseIntensity = 0.3 + pressure * 0.8;
		}

		final distance = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
		final strokeVelocity = distance / Math.max(1, Date.now().getTime() - lastBrushTime);
		final strokeAngle = Math.atan2(y2 - y1, x2 - x1);

		ctx.globalCompositeOperation = "destination-out";

		if (brushHardness >= 0.8) {
			// Hard eraser: clean, precise erasing with slight texture variation
			final hardIntensity = baseIntensity * brushHardness;

			// Add subtle texture variation even for hard erasers
			final textureLayers = 2;
			for (layer in 0...textureLayers) {
				final layerIntensity = hardIntensity * (1 - layer * 0.1);
				final layerSize = effectiveSize * (1 - layer * 0.05);

				ctx.strokeStyle = 'rgba(0, 0, 0, ${layerIntensity})';
				ctx.lineWidth = layerSize;
				ctx.lineCap = "round";
				ctx.lineJoin = "round";

				ctx.beginPath();
				ctx.moveTo(x1, y1);
				ctx.lineTo(x2, y2);
				ctx.stroke();
			}
		} else {
			// Soft eraser: gradual, feathered erasing with realistic falloff
			final softLayers = Math.ceil((1 - brushHardness) * 8)
				+ 3; // More layers for smoother gradients
			for (i in 0...Std.int(softLayers)) {
				final layerRatio = i / (softLayers - 1);
				final falloffCurve = Math.pow(1 - layerRatio, 1.8); // Natural falloff curve
				final layerIntensity = baseIntensity * falloffCurve / softLayers;
				final layerSize = effectiveSize * (1.0 + layerRatio * (1 - brushHardness) * 0.8);

				// Create sophisticated gradient for ultra-smooth edges
				final centerX = (x1 + x2) / 2;
				final centerY = (y1 + y2) / 2;
				final gradient = ctx.createRadialGradient(centerX, centerY, 0, centerX, centerY, layerSize / 2);
				gradient.addColorStop(0, 'rgba(0, 0, 0, ${layerIntensity})');
				gradient.addColorStop(0.6, 'rgba(0, 0, 0, ${layerIntensity * 0.7})');
				gradient.addColorStop(0.9, 'rgba(0, 0, 0, ${layerIntensity * 0.3})');
				gradient.addColorStop(1, 'rgba(0, 0, 0, 0)');

				ctx.strokeStyle = gradient;
				ctx.lineWidth = layerSize;
				ctx.lineCap = "round";
				ctx.lineJoin = "round";

				ctx.beginPath();
				ctx.moveTo(x1, y1);
				ctx.lineTo(x2, y2);
				ctx.stroke();
			}
		}

		// Advanced eraser crumb and rubber texture simulation
		if (brushTexture < 0.9 && pressure > 0.5) {
			final crumbSteps = Math.floor(distance / 2.5) + 2;
			for (i in 0...Std.int(crumbSteps)) {
				final t = i / crumbSteps;
				final crumbCenterX = x1 + t * (x2 - x1);
				final crumbCenterY = y1 + t * (y2 - y1);

				// Create realistic eraser crumb clusters with physics
				final crumbIntensity = (1 - brushTexture) * pressure;
				final crumbClusterCount = Math.floor(crumbIntensity * 4) + 1;

				for (cluster in 0...crumbClusterCount) { // Crumbs scatter based on eraser pressure and movement
					final scatterRadius = effectiveSize * 0.6 * crumbIntensity;
					final scatterAngle = syncRandom.next() * Math.PI * 2;
					final scatterDistance = syncRandom.next() * scatterRadius;

					final clusterX = crumbCenterX + Math.cos(scatterAngle) * scatterDistance;
					final clusterY = crumbCenterY
						+
						Math.sin(scatterAngle) * scatterDistance; // Individual crumbs in each cluster
					final crumbsPerCluster = Math.floor(syncRandom.next() * 4) + 2;
					for (crumb in 0...crumbsPerCluster) {
						final crumbOffsetX = (syncRandom.next() - 0.5) * 3;
						final crumbOffsetY = (syncRandom.next() - 0.5) * 3;
						final crumbX = clusterX + crumbOffsetX;
						final crumbY = clusterY + crumbOffsetY;

						// Realistic crumb size and shape variation
						final crumbSize = syncRandom.next() * 2.0 + 0.3;
						final crumbShape = syncRandom.next(); // 0-1 for shape variation
						final crumbOpacity = baseIntensity * 0.4 * crumbIntensity * syncRandom.next();

						if (crumbShape < 0.7) {
							// Round crumbs
							ctx.fillStyle = 'rgba(0, 0, 0, ${crumbOpacity})';
							ctx.beginPath();
							ctx.arc(crumbX, crumbY, crumbSize, 0, Math.PI * 2);
							ctx.fill();
						} else {
							// Irregular shaped crumbs
							ctx.strokeStyle = 'rgba(0, 0, 0, ${crumbOpacity})';
							ctx.lineWidth = crumbSize;
							ctx.lineCap = "round";
							ctx.beginPath();
							ctx.moveTo(crumbX - crumbSize * 0.5, crumbY);
							ctx.lineTo(crumbX + crumbSize * 0.5, crumbY);
							ctx.stroke();
						}
					}
				}
			}
		}

		// Advanced selective erasing - some materials erase differently
		if (brushTexture < 0.8) {
			final selectiveSteps = Math.floor(distance / 1.2) + 3;
			for (i in 0...Std.int(selectiveSteps)) {
				final t = i / selectiveSteps;
				final selX = x1 + t * (x2 - x1);
				final selY = y1
					+ t * (y2 - y1); // Simulate different paper textures and ink types
				final selectiveChance = (1 - brushTexture) * 0.8;
				if (syncRandom.next() < selectiveChance) {
					// Some areas resist erasing (like permanent ink or deep impressions)
					final resistanceType = syncRandom.next();

					if (resistanceType < 0.3) {
						// Stubborn spots that barely erase
						final stubborness = 0.1 + syncRandom.next() * 0.2;
						final selectiveSize = effectiveSize * (0.2 + syncRandom.next() * 0.3);
						final selectiveIntensity = baseIntensity * stubborness;

						ctx.fillStyle = 'rgba(0, 0, 0, ${selectiveIntensity})';
						ctx.beginPath();
						ctx.arc(selX, selY, selectiveSize, 0, Math.PI * 2);
						ctx.fill();
					} else if (resistanceType < 0.7) {
						// Areas that erase more easily (light pencil marks)
						final selectiveSize = effectiveSize * (0.4 + syncRandom.next() * 0.5);
						final selectiveIntensity = baseIntensity * (0.7 + syncRandom.next() * 0.4);

						ctx.fillStyle = 'rgba(0, 0, 0, ${selectiveIntensity})';
						ctx.beginPath();
						ctx.arc(selX, selY, selectiveSize, 0, Math.PI * 2);
						ctx.fill();
					} else {
						// Paper fiber texture - creates natural variation
						final fiberCount = Math.floor(syncRandom.next() * 3) + 1;
						for (fiber in 0...fiberCount) {
							final fiberAngle = syncRandom.next() * Math.PI * 2;
							final fiberLength = syncRandom.next() * effectiveSize * 0.3;
							final fiberX1 = selX + Math.cos(fiberAngle) * fiberLength * 0.5;
							final fiberY1 = selY + Math.sin(fiberAngle) * fiberLength * 0.5;
							final fiberX2 = selX - Math.cos(fiberAngle) * fiberLength * 0.5;
							final fiberY2 = selY - Math.sin(fiberAngle) * fiberLength * 0.5;

							final fiberIntensity = baseIntensity * 0.3 * syncRandom.next();
							final fiberThickness = syncRandom.next() * 1.5 + 0.3;

							ctx.strokeStyle = 'rgba(0, 0, 0, ${fiberIntensity})';
							ctx.lineWidth = fiberThickness;
							ctx.lineCap = "round";

							ctx.beginPath();
							ctx.moveTo(fiberX1, fiberY1);
							ctx.lineTo(fiberX2, fiberY2);
							ctx.stroke();
						}
					}
				}
			}
		}

		// Eraser heat effect - erasers get warmer with friction, affecting performance
		if (pressure > 0.8 && strokeVelocity > 0.15) {
			final heatSteps = Math.floor(distance / 3) + 1;
			for (i in 0...Std.int(heatSteps)) {
				final t = i / heatSteps;
				final heatX = x1 + t * (x2 - x1);
				final heatY = y1 + t * (y2 - y1);

				// Hot eraser creates slightly different erasing characteristics
				final heatEffect = pressure * strokeVelocity * 0.6;
				final heatRadius = effectiveSize * 0.8 * heatEffect;
				final heatIntensity = baseIntensity * 0.3 * heatEffect;

				// Create subtle heat gradient effect
				final heatGradient = ctx.createRadialGradient(heatX, heatY, 0, heatX, heatY, heatRadius);
				heatGradient.addColorStop(0, 'rgba(0, 0, 0, ${heatIntensity})');
				heatGradient.addColorStop(0.8, 'rgba(0, 0, 0, ${heatIntensity * 0.5})');
				heatGradient.addColorStop(1, 'rgba(0, 0, 0, 0)');

				ctx.fillStyle = heatGradient;
				ctx.beginPath();
				ctx.arc(heatX, heatY, heatRadius, 0, Math.PI * 2);
				ctx.fill();
			}
		}
		// Edge wear simulation - erasers develop uneven surfaces over time
		if (brushTexture < 0.6 && syncRandom.next() < 0.4) {
			final edgeWearCount = Math.floor(distance / 4) + 1;
			for (i in 0...Std.int(edgeWearCount)) {
				final t = i / edgeWearCount;
				final wearX = x1 + t * (x2 - x1);
				final wearY = y1 + t * (y2 - y1);

				// Create worn edge effects
				final wearRadius = effectiveSize * 0.3;
				final wearIntensity = baseIntensity * (1 - brushTexture) * 0.4;

				// Irregular wear pattern
				final wearPoints = Math.floor(syncRandom.next() * 5) + 3;
				for (point in 0...wearPoints) {
					final pointAngle = (point / wearPoints) * Math.PI * 2;
					final pointRadius = wearRadius * (0.7 + syncRandom.next() * 0.6);
					final pointX = wearX + Math.cos(pointAngle) * pointRadius;
					final pointY = wearY + Math.sin(pointAngle) * pointRadius;
					final pointSize = syncRandom.next() * 1.8 + 0.4;
					final pointIntensity = wearIntensity * syncRandom.next();

					ctx.fillStyle = 'rgba(0, 0, 0, ${pointIntensity})';
					ctx.beginPath();
					ctx.arc(pointX, pointY, pointSize, 0, Math.PI * 2);
					ctx.fill();
				}
			}
		}
	}
}
