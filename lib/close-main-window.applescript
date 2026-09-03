-- Closes the FortiClient main window (app keeps running in the menu bar).
tell application "System Events"
	if not (exists process "FortiClient") then return "no process"
	tell process "FortiClient"
		repeat with w in windows
			if (name of w as text) is "FortiClient" then
				click (first button of w whose description is "close button")
				return "closed"
			end if
		end repeat
	end tell
end tell
return "no window"
