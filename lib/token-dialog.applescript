-- Usage:
--   osascript token-dialog.applescript find          -> prints "found:<process>" or ""
--   osascript token-dialog.applescript fill <code>   -> types code into the dialog, clicks OK
-- The token dialog is a small window of a Forti* process containing the text
-- "Token Code" and one text field.

on findDialog()
	set prefix to "Forti"
	try
		set prefix to system attribute "FORTI_PROC_PREFIX"
		if prefix is "" then set prefix to "Forti"
	end try
	tell application "System Events"
		set procs to every process whose name begins with prefix
		repeat with p in procs
			repeat with w in windows of p
				try
					set hasText to false
					set fieldRef to missing value
					set els to entire contents of w
					repeat with e in els
						set r to role of e
						if r is "AXStaticText" then
							try
								if (value of e as text) contains "Token Code" then set hasText to true
							end try
						else if r is "AXTextField" then
							set fieldRef to e
						end if
					end repeat
					if hasText and fieldRef is not missing value then
						return {name of p, w, fieldRef}
					end if
				end try
			end repeat
		end repeat
	end tell
	return missing value
end findDialog

on run argv
	set mode to item 1 of argv
	set hit to findDialog()
	if mode is "find" then
		if hit is missing value then return ""
		return "found:" & (item 1 of hit)
	end if
	if mode is "fill" then
		if hit is missing value then error "token dialog not found"
		set code to item 2 of argv
		set procName to item 1 of hit
		set w to item 2 of hit
		set tf to item 3 of hit
		tell application "System Events"
			tell process procName
				set frontmost to true
			end tell
			try
				perform action "AXRaise" of w
			end try
			delay 0.3
			set typed to false
			try
				set focused of tf to true
				set value of tf to code
				set typed to true
			end try
			if not typed then
				-- fallback: type it
				set focused of tf to true
				keystroke "a" using command down
				keystroke code
			end if
			delay 0.3
			try
				click button "OK" of w
			on error
				keystroke return
			end try
		end tell
		return "ok"
	end if
	error "unknown mode " & mode
end run
