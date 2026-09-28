-- Usage:
--   osascript fortitray.applescript items          -> titles of the items in FortiClient's menu bar menu, one per line
--   osascript fortitray.applescript click <title>  -> clicks that item, e.g. "Connect to Office"
--   osascript fortitray.applescript click-first <prefix>  -> clicks the first item whose title starts with it, e.g. "Disconnect "
-- FortiClient has no command line for SSL VPN connections, so connecting and
-- disconnecting go through its own menu bar menu (process FortiTray), the menu
-- the user would click. It opens for a moment and closes again.

on trayMenu()
	-- clicking a menu bar icon through Accessibility does not return until the
	-- menu closes, so do not wait for the answer; poll for the open menu instead
	tell application "System Events" to tell process "FortiTray"
		ignoring application responses
			click menu bar item 1 of menu bar 1
		end ignoring
	end tell
	repeat 30 times
		delay 0.1
		try
			with timeout of 5 seconds
				tell application "System Events" to tell process "FortiTray"
					set m to menu 1 of menu bar item 1 of menu bar 1
					if (count of menu items of m) > 0 then return m
				end tell
			end timeout
		end try
	end repeat
	error "FortiClient menu did not open"
end trayMenu

on closeMenu(m)
	with timeout of 5 seconds
		tell application "System Events"
			try
				perform action "AXCancel" of m
			on error
				key code 53 -- Escape
			end try
		end tell
	end timeout
end closeMenu

-- item titles; separators have no name and are left out
on itemNames(m)
	with timeout of 5 seconds
		tell application "System Events" to set names to name of every menu item of m
	end timeout
	set out to {}
	repeat with n in names
		set v to contents of n
		if v is not missing value then set end of out to (v as text)
	end repeat
	return out
end itemNames

on run argv
	set mode to item 1 of argv
	tell application "System Events"
		if not (exists process "FortiTray") then error "FortiClient is not running."
	end tell
	set m to my trayMenu()
	if mode is "items" then
		set names to my itemNames(m)
		my closeMenu(m)
		set AppleScript's text item delimiters to linefeed
		return names as text
	else if mode is "click" or mode is "click-first" then
		set wanted to item 2 of argv
		try
			with timeout of 5 seconds
				tell application "System Events"
					if mode is "click" then
						click menu item wanted of m
					else
						click (first menu item of m whose name starts with wanted)
					end if
				end tell
			end timeout
		on error
			set names to {}
			try
				set names to my itemNames(m)
			end try
			my closeMenu(m)
			set AppleScript's text item delimiters to ", "
			error "FortiClient's menu has no \"" & wanted & "\" right now (it shows: " & (names as text) & "). It may still be busy with an earlier connection."
		end try
		return "ok"
	end if
	my closeMenu(m)
	error "unknown mode " & mode
end run
