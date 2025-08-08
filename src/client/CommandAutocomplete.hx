package client;

import js.html.Element;
import js.html.DivElement;
import js.html.InputElement;
import js.html.KeyboardEvent;
import js.html.Document;

class CommandAutocomplete {
	private var inputElement:InputElement;
	private var menuElement:DivElement;
	private var commands:Array<Commands.Command>;
	private var filteredCommands:Array<Commands.Command>;
	private var selectedIndex:Int = -1;
	private var isVisible:Bool = false;
	private var isLeader:Bool;
	private var onCommandSelect:String -> Void;

	public function new(inputElement:InputElement, isLeader:Bool = false, onCommandSelect:String -> Void = null) {
		this.inputElement = inputElement;
		this.isLeader = isLeader;
		this.onCommandSelect = onCommandSelect;
		this.commands = Commands.COMMANDS;
		this.filteredCommands = [];
		
		createMenuElement();
		attachEventListeners();
	}

	private function createMenuElement():Void {
		menuElement = js.Browser.document.createDivElement();
		menuElement.className = "command-autocomplete-menu";
		menuElement.style.display = "none";
		menuElement.style.position = "absolute";
		menuElement.style.backgroundColor = "#2d2d2d";
		menuElement.style.border = "1px solid #555";
		menuElement.style.borderRadius = "4px";
		menuElement.style.boxShadow = "0 2px 8px rgba(0, 0, 0, 0.3)";
		menuElement.style.maxHeight = "200px";
		menuElement.style.overflowY = "auto";
		menuElement.style.zIndex = "1000";
		menuElement.style.minWidth = "300px";
		
		// Insert after input element
		inputElement.parentElement.insertBefore(menuElement, inputElement.nextSibling);
	}

	private function attachEventListeners():Void {
		inputElement.addEventListener("input", onInputChange);
		inputElement.addEventListener("keydown", onKeyDown);
		
		// Hide menu when clicking outside
		js.Browser.document.addEventListener("click", function(e) {
			if (!menuElement.contains(cast e.target) && e.target != inputElement) {
				hideMenu();
			}
		});
	}

	private function onInputChange(e):Void {
		final value = inputElement.value;
		
		if (value.startsWith("/")) {
			final query = value.substring(1);
			showMenu(query);
		} else {
			hideMenu();
		}
	}

	private function onKeyDown(e:KeyboardEvent):Void {
		if (!isVisible) return;
		
		final keyCode = e.keyCode;
		if (keyCode == KeyCode.Up) {
			e.preventDefault();
			navigateUp();
		} else if (keyCode == KeyCode.Down) {
			e.preventDefault();
			navigateDown();
		} else if (keyCode == KeyCode.Return) {
			if (selectedIndex >= 0 && selectedIndex < filteredCommands.length) {
				e.preventDefault();
				selectCommand(filteredCommands[selectedIndex]);
			}
		} else if (keyCode == KeyCode.Escape) {
			e.preventDefault();
			hideMenu();
		}
	}

	private function showMenu(query:String):Void {
		filteredCommands = Commands.getFilteredCommands(query, isLeader);
		
		if (filteredCommands.length == 0) {
			hideMenu();
			return;
		}
		
		renderMenu();
		positionMenu();
		selectedIndex = -1;
		isVisible = true;
		menuElement.style.display = "block";
	}

	private function hideMenu():Void {
		isVisible = false;
		selectedIndex = -1;
		menuElement.style.display = "none";
	}

	private function renderMenu():Void {
		menuElement.innerHTML = "";
		
		for (i in 0...filteredCommands.length) {
			final command = filteredCommands[i];
			final item = js.Browser.document.createDivElement();
			item.className = "command-autocomplete-item";
			item.style.padding = "8px 12px";
			item.style.cursor = "pointer";
			item.style.borderBottom = "1px solid #404040";
			item.style.color = "#ffffff";
			
			// Command name
			final nameDiv = js.Browser.document.createDivElement();
			nameDiv.style.fontWeight = "bold";
			nameDiv.style.color = command.requiresLeader ? "#ffb800" : "#ffffff";
			nameDiv.textContent = command.usage;
			
			// Description
			final descDiv = js.Browser.document.createDivElement();
			descDiv.style.fontSize = "12px";
			descDiv.style.color = "#bbb";
			descDiv.style.marginTop = "2px";
			descDiv.textContent = command.description;
			
			item.appendChild(nameDiv);
			item.appendChild(descDiv);
			
			// Add leader requirement indicator
			if (command.requiresLeader && !isLeader) {
				final leaderIndicator = js.Browser.document.createSpanElement();
				leaderIndicator.style.color = "#ff6666";
				leaderIndicator.style.fontSize = "11px";
				leaderIndicator.style.fontStyle = "italic";
				leaderIndicator.style.marginTop = "2px";
				leaderIndicator.style.display = "block";
				leaderIndicator.textContent = "Requires leader permission";
				item.appendChild(leaderIndicator);
			}
			
			// Add click handler
			final commandIndex = i;
			item.addEventListener("click", function(e) {
				selectCommand(filteredCommands[commandIndex]);
			});
			
			// Add hover effects
			item.addEventListener("mouseenter", function(e) {
				selectedIndex = commandIndex;
				updateSelection(false); // Don't scroll on mouse hover
			});
			
			menuElement.appendChild(item);
		}
		
		updateSelection();
	}

	private function positionMenu():Void {
		final inputRect = inputElement.getBoundingClientRect();
		final parentRect = inputElement.parentElement.getBoundingClientRect();
		final viewportHeight = js.Browser.window.innerHeight;
		
		// Calculate available space
		final spaceBelow = viewportHeight - inputRect.bottom;
		final spaceAbove = inputRect.top;
		
		// More realistic menu height estimation: ~50px per item + padding, max 200px
		final itemHeight = 50; // More realistic item height including padding/borders
		final estimatedMenuHeight = Math.min(200, Math.max(60, filteredCommands.length * itemHeight + 16)); // +16 for container padding
		
		// Positioning logic: Position above if either:
		// 1. Not enough space below AND enough space above, OR
		// 2. Not enough space below AND more space above than below
		final enoughSpaceBelow = spaceBelow >= estimatedMenuHeight;
		final enoughSpaceAbove = spaceAbove >= estimatedMenuHeight;
		
		final shouldPositionAbove = !enoughSpaceBelow && (enoughSpaceAbove || spaceAbove > spaceBelow);
		
		if (shouldPositionAbove) {
			// Position above the input
			final topPosition = Math.max(5, inputRect.top - estimatedMenuHeight - 2); // Ensure at least 5px from viewport top
			menuElement.style.top = (topPosition - parentRect.top) + "px";
		} else {
			// Position below the input
			menuElement.style.top = (inputRect.bottom - parentRect.top + 2) + "px";
		}
		
		menuElement.style.left = (inputRect.left - parentRect.left) + "px";
	}

	private function navigateUp():Void {
		if (filteredCommands.length == 0) return;
		
		selectedIndex--;
		if (selectedIndex < 0) {
			selectedIndex = filteredCommands.length - 1;
		}
		updateSelection(true); // Scroll for keyboard navigation
	}

	private function navigateDown():Void {
		if (filteredCommands.length == 0) return;
		
		selectedIndex++;
		if (selectedIndex >= filteredCommands.length) {
			selectedIndex = 0;
		}
		updateSelection(true); // Scroll for keyboard navigation
	}

	private function updateSelection(shouldScroll:Bool = false):Void {
		final items = menuElement.querySelectorAll(".command-autocomplete-item");
		
		for (i in 0...items.length) {
			final item:Element = cast items[i];
			if (i == selectedIndex) {
				item.style.backgroundColor = "#404040";
			} else {
				item.style.backgroundColor = "transparent";
			}
		}
		
		// Only scroll when explicitly requested (keyboard navigation, not mouse hover)
		if (shouldScroll && selectedIndex >= 0 && selectedIndex < items.length) {
			final selectedItem:Element = cast items[selectedIndex];
			selectedItem.scrollIntoView();
		}
	}

	private function selectCommand(command:Commands.Command):Void {
		// Insert command into input
		inputElement.value = command.usage.split(" ")[0];
		
		// Position cursor at end
		inputElement.setSelectionRange(inputElement.value.length, inputElement.value.length);
		
		// Call callback if provided
		if (onCommandSelect != null) {
			onCommandSelect(command.name);
		}
		
		hideMenu();
		
		// Focus back on input
		inputElement.focus();
	}

	public function destroy():Void {
		if (menuElement != null && menuElement.parentElement != null) {
			menuElement.parentElement.removeChild(menuElement);
		}
		
		inputElement.removeEventListener("input", onInputChange);
		inputElement.removeEventListener("keydown", onKeyDown);
	}

	public function setLeaderStatus(isLeader:Bool):Void {
		this.isLeader = isLeader;
		
		// Refresh menu if currently visible
		if (isVisible) {
			final value = inputElement.value;
			if (value.startsWith("/")) {
				final query = value.substring(1);
				showMenu(query);
			}
		}
	}

	/**
	 * Check if the autocomplete menu is currently visible
	 */
	public function isMenuVisible():Bool {
		return isVisible;
	}

	/**
	 * Check if an item is currently selected in the menu
	 */
	public function hasSelection():Bool {
		return selectedIndex >= 0 && selectedIndex < filteredCommands.length;
	}
}