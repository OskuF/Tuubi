package client;

import js.html.Event;
import js.html.InputElement;
import js.html.KeyboardEvent;

class InputWithHistory {
	var element:InputElement;
	var history:Array<String>;
	var historyId = -1;
	var maxItems = 100;
	var onEnterCallback:(value:String) -> Bool;

	public function new(
		element:InputElement,
		history:Null<Array<String>>,
		maxItems:Int,
		onEnter:(value:String) -> Bool
	) {
		this.element = element;
		if (history != null) {
			this.history = history;
		} else {
			this.history = [];
		}
		this.maxItems = maxItems;
		this.onEnterCallback = onEnter;
		init();
	}

	public function init():Void {
		element.onkeydown = onKeyDown;
	}

	function onKeyDown(e:KeyboardEvent):Void {
		switch (e.keyCode) {
			case KeyCode.Up:
				prevItem();
			case KeyCode.Down:
				nextItem();
			case KeyCode.Return:
				var value = StringTools.trim(element.value);
				if (value.length == 0) {
					return;
				}
				if (history.length == 0 || history[0] != value) {
					pushIfNotLast(history, value);
					while (history.length > maxItems) {
						history.pop();
					}
				}
				historyId = -1;
				
				// Check if the danmaku checkbox is checked
				var sendAsDanmaku = false;
				final danmakuCheckbox:InputElement = Main.getEl("#send-as-danmaku");
				if (danmakuCheckbox != null) {
					sendAsDanmaku = danmakuCheckbox.checked;
				}
				
				element.value = "";
				
				// If sending as danmaku and danmaku is enabled, process it
				if (sendAsDanmaku && Main.instance.isDanmakuEnabled) {
					Main.instance.sendDanmakuComment(value);
					e.preventDefault();
					return; // Skip sending to regular chat
				}
				
				// Otherwise process as normal chat message
				if (onEnterCallback(value)) {
					e.preventDefault();
				}
		}
	}

	function prevItem():Void {
		if (history.length == 0) {
			return;
		}
		if (historyId == -1) {
			historyId = 0;
		} else if (historyId < history.length - 1) {
			historyId++;
		} else {
			return;
		}
		element.value = history[historyId];
	}

	function nextItem():Void {
		if (historyId <= 0) {
			historyId = -1;
			element.value = "";
		} else if (historyId > 0) {
			historyId--;
			element.value = history[historyId];
		}
	}

	public static function pushIfNotLast<T>(a:Array<T>, v:T):Void {
		if (a.length == 0 || a[0] != v) {
			a.unshift(v);
		}
	}
}
