package client;

typedef Command = {
	name: String,
	description: String,
	usage: String,
	requiresLeader: Bool
}

class Commands {
	public static final COMMANDS:Array<Command> = [
		{
			name: "help",
			description: "Show list of available commands",
			usage: "/help",
			requiresLeader: false
		},
		{
			name: "ban",
			description: "Ban a user for specified time",
			usage: "/ban <username> <time>",
			requiresLeader: true
		},
		{
			name: "unban",
			description: "Remove ban from a user",
			usage: "/unban <username>",
			requiresLeader: true
		},
		{
			name: "removeBan",
			description: "Remove ban from a user (alias for unban)",
			usage: "/removeBan <username>",
			requiresLeader: true
		},
		{
			name: "kick",
			description: "Kick a user from the room",
			usage: "/kick <username>",
			requiresLeader: true
		},
		{
			name: "clear",
			description: "Clear chat messages",
			usage: "/clear",
			requiresLeader: true
		},
		{
			name: "flashback",
			description: "Show flashback (alias: fb)",
			usage: "/flashback",
			requiresLeader: false
		},
		{
			name: "fb",
			description: "Show flashback (short for flashback)",
			usage: "/fb",
			requiresLeader: false
		},
		{
			name: "ad",
			description: "Skip current ad",
			usage: "/ad",
			requiresLeader: false
		},
		{
			name: "random",
			description: "Get random FrankerFaceZ emote",
			usage: "/random",
			requiresLeader: false
		},
		{
			name: "random7tv",
			description: "Get random 7TV emote",
			usage: "/random7tv",
			requiresLeader: false
		},
		{
			name: "volume",
			description: "Set volume level (0.0 to 3.0)",
			usage: "/volume <level>",
			requiresLeader: false
		},
		{
			name: "dump",
			description: "Dump current state information",
			usage: "/dump",
			requiresLeader: true
		},
		{
			name: "skip",
			description: "Skip forward by seconds",
			usage: "/skip [seconds]",
			requiresLeader: false
		}
	];

	/**
	 * Get all commands that match the given filter text
	 */
	public static function getFilteredCommands(filter:String, isLeader:Bool = false):Array<Command> {
		var filtered = COMMANDS.copy();
		
		// Filter by leader permission if not leader
		if (!isLeader) {
			filtered = filtered.filter(cmd -> !cmd.requiresLeader);
		}
		
		// Filter by name match
		if (filter.length > 0) {
			final filterLower = filter.toLowerCase();
			filtered = filtered.filter(cmd -> cmd.name.toLowerCase().indexOf(filterLower) >= 0);
		}
		
		return filtered;
	}

	/**
	 * Get command by exact name match
	 */
	public static function getCommand(name:String):Null<Command> {
		for (cmd in COMMANDS) {
			if (cmd.name == name) {
				return cmd;
			}
		}
		return null;
	}

	/**
	 * Check if a string is a valid command
	 */
	public static function isCommand(text:String):Bool {
		if (!text.startsWith("/")) return false;
		final parts = text.trim().split(" ");
		final command = parts[0].substr(1);
		return getCommand(command) != null;
	}

	/**
	 * Extract command name from a command string
	 */
	public static function getCommandName(text:String):String {
		if (!text.startsWith("/")) return "";
		final parts = text.trim().split(" ");
		return parts[0].substr(1);
	}

	/**
	 * Check if command matches time format for rewind
	 */
	public static function isTimeCommand(command:String):Bool {
		// Simple regex to match time formats like "12:34" or "1:23:45"
		final timePattern = ~/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/;
		return timePattern.match(command);
	}
}