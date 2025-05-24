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

// Structure to represent other users' cursors
typedef UserCursor = {
	name:String,
	x:Float,
	y:Float,
	lastUpdate:Float
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
	static var currentTool = "pen"; // Background variables
	static var currentBackgroundMode = "transparent"; // "transparent" or "color"
	static var currentBackgroundColor = "#FFFFFF";

	// Tablet/stylus support variables
	static var supportsPressure = false;
	static var currentPressure = 1.0;
	static var currentTiltX = 0.0;
	static var currentTiltY = 0.0;
	static var currentPointerType = "mouse"; // "mouse", "pen", "touch"
	static var pressureSensitivity = true; // Can be toggled by user
	static var palmRejection = true; // Reject touch when pen is being used
	static var isPenActive = false; // Track if pen is currently being used
	// Map to store other users' cursor positions
	static var userCursors:Map<String, UserCursor> = new Map<String, UserCursor>();
	static var cursorCheckTimer:Timer;
	static var lastCursorSendTime:Float = 0;
	static var cursorThrottleInterval:Float = 33; // ~30fps for cursor position updates
	static var animFrameId:Int;

	// Separate variables for rendering incoming strokes from other clients
	static var incomingColor = "#FF0000";
	static var incomingSize = 3.0;
	static var incomingTool = "pen"; // "pen" or "eraser"
	static var playerEl:Element;

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

		// Remove stale cursors
		for (key in keysToRemove) {
			userCursors.remove(key);
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

		// Send drawing start event to server
		main.send({
			type: DrawStart,
			drawStart: {
				x: x,
				y: y,
				color: currentColor,
				size: currentSize,
				tool: currentTool
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
				y: y
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
		// Using the same video-relative coordinate system for consistency
		final pixelX1 = x1 * canvas.width;
		final pixelY1 = y1 * canvas.height;
		final pixelX2 = x2 * canvas.width;
		final pixelY2 = y2 * canvas.height;

		// Calculate pressure-sensitive line width
		var effectiveSize = size;
		if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
			// Apply pressure curve: minimum 20% of size, maximum 150% of size
			final minSize = size * 0.2;
			final maxSize = size * 1.5;
			effectiveSize = minSize + (maxSize - minSize) * pressure;
		}

		// Set drawing mode based on tool
		if (tool == "eraser") {
			ctx.globalCompositeOperation = "destination-out";
			ctx.strokeStyle = "rgba(0,0,0,1)";
		} else {
			ctx.globalCompositeOperation = "source-over";
			ctx.strokeStyle = color;

			// Apply pressure-sensitive opacity for more natural pen feel
			if (pressureSensitivity && supportsPressure && currentPointerType == "pen") {
				final alpha = Math.max(0.3, Math.min(1.0, pressure + 0.3));
				final rgbColor = hexToRgb(color);
				ctx.strokeStyle = 'rgba(${rgbColor.r}, ${rgbColor.g}, ${rgbColor.b}, ${alpha})';
			}
		}

		ctx.lineWidth = effectiveSize;
		ctx.beginPath();
		ctx.moveTo(pixelX1, pixelY1);
		ctx.lineTo(pixelX2, pixelY2);
		ctx.stroke();
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

	public static function onDrawStart(x:Float, y:Float, color:String, size:Float, tool:String):Void {
		incomingColor = color;
		incomingSize = size;
		incomingTool = tool;
		lastX = x;
		lastY = y;

		// DO NOT update current user's settings - only store incoming values for rendering
		// The currentColor, currentSize, and currentTool should remain the user's own settings
	}

	public static function onDrawMove(x:Float, y:Float):Void {
		drawLine(lastX, lastY, x, y, incomingColor, incomingSize, incomingTool);
		lastX = x;
		lastY = y;
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
		final penButton = getEl("#drawing-tool-pen");
		final eraserButton = getEl("#drawing-tool-eraser");

		// Reset both buttons
		penButton.classList.remove("active");
		eraserButton.classList.remove("active");

		// Reset button colors
		penButton.style.background = "#555"; // Grey for inactive
		eraserButton.style.background = "#555"; // Grey for inactive

		// Set active tool with blue color
		if (currentTool == "eraser") {
			eraserButton.classList.add("active");
			eraserButton.style.background = "#2196F3"; // Blue for active
			// Update tool icon to show it's active
			final iconElement = eraserButton.querySelector("ion-icon");
			if (iconElement != null) {
				iconElement.setAttribute("style", "color: white; font-weight: bold;");
			}
			// Reset pen icon
			final penIconElement = penButton.querySelector("ion-icon");
			if (penIconElement != null) {
				penIconElement.setAttribute("style", "");
			}
		} else {
			penButton.classList.add("active");
			penButton.style.background = "#2196F3"; // Blue for active
			// Update tool icon to show it's active
			final iconElement = penButton.querySelector("ion-icon");
			if (iconElement != null) {
				iconElement.setAttribute("style", "color: white; font-weight: bold;");
			}
			// Reset eraser icon
			final eraserIconElement = eraserButton.querySelector("ion-icon");
			if (eraserIconElement != null) {
				eraserIconElement.setAttribute("style", "");
			}
		}

		// Display current tool in the header
		final toolsHeader = getEl("#drawing-tools-header");
		if (toolsHeader != null) {
			toolsHeader.innerHTML = currentTool == "eraser" ? "📝 Drawing Tools (Eraser)" : "📝 Drawing Tools (Pen)";
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
}
