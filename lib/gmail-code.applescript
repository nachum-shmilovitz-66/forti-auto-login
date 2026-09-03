-- Usage: osascript gmail-code.applescript <sinceISO> <email> <domain> <afterISO>
-- Prints "<code>|<issued>" for the newest unread "AuthCode: NNNNNN" mail in
-- the wanted inbox issued at or after <since> and after <afterISO> (the mail
-- whose code was used last), "none" if there is none yet, or "ERR:..." on failure.
-- Wanted inbox: <email> if given, else any mailbox on <domain>.
-- Scans every Gmail tab in every Chrome window (each profile has its own
-- cookies) and every account index /u/0..5. Tabs whose page title names the
-- wanted account are tried first, so the usual case takes a couple of seconds.
-- If no tab is signed in as wanted, opens Gmail in the right Chrome profile
-- (lib/open-gmail.sh) and scans again. Nothing needs to be focused.
-- FC_DEBUG=1 in the environment traces every tab tried on stderr.
-- FC_MAY_OPEN=1 allows opening a Gmail tab when no signed-in tab exists.

on readFile(p)
	set f to open for access (POSIX file p)
	set t to read f as «class utf8»
	close access f
	return t
end readFile

on dbg(msg)
	if (system attribute "FC_DEBUG") is "1" then log (do shell script "date +%H:%M:%S") & " " & msg
end dbg

-- Gmail tabs, the ones whose title names the wanted account first
on gmailTabs(email, domain)
	set preferred to {}
	set others to {}
	tell application "Google Chrome"
		repeat with w in windows
			repeat with t in tabs of w
				if (URL of t) starts with "https://mail.google.com/" then
					set ti to ""
					try
						set ti to execute t javascript "document.title"
					end try
					if ti is missing value then set ti to ""
					if email is not "" then
						set hit to (ti contains email)
					else
						set hit to (ti contains ("@" & domain))
					end if
					if hit then
						set end of preferred to t
					else
						set end of others to t
					end if
				end if
			end repeat
		end repeat
	end tell
	return preferred & others
end gmailTabs

-- run start+parse JS in one tab; returns result text or "ERR:..."
on fetchFromTab(t, startJS, parseJS)
	tell application "Google Chrome"
		repeat with attempt from 1 to 2
			try
				set r to execute t javascript startJS
			on error m
				-- e.g. "Executing JavaScript through AppleScript is turned off" in this profile
				return "ERR:" & m
			end try
			if r is missing value then
				-- discarded (Memory Saver) or sleeping tab: wake it up once
				if attempt is 2 then return "ERR:tab not scriptable"
				reload t
				delay 5
			else
				repeat 20 times
					delay 0.5
					try
						set res to execute t javascript parseJS
					on error m
						return "ERR:" & m
					end try
					if res is missing value then return "ERR:parse failed"
					if res is not "pending" then return res
				end repeat
				return "ERR:timeout waiting for feed"
			end if
		end repeat
	end tell
end fetchFromTab

on tryTabs(tabList, startJS, parseJS)
	set lastErr to "ERR:no Gmail tab"
	repeat with t in tabList
		tell application "Google Chrome" to set u to URL of t
		my dbg("tab " & u)
		set res to my fetchFromTab(t, startJS, parseJS)
		my dbg("  -> " & res)
		if res does not start with "ERR:" then return res
		-- "no login" is the most useful error to surface
		if lastErr does not contain "no login" then set lastErr to res
	end repeat
	return lastErr
end tryTabs

on run argv
	set sinceISO to item 1 of argv
	set email to item 2 of argv
	set domain to item 3 of argv
	set afterISO to ""
	if (count of argv) > 3 then set afterISO to item 4 of argv
	set libDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set startJS to "window.__fcEmail='" & email & "';window.__fcDomain='" & domain & "';window.__fcSince='" & sinceISO & "';window.__fcAfter='" & afterISO & "';" & readFile(libDir & "/gmail-start.js")
	set parseJS to readFile(libDir & "/gmail-parse.js")

	set res to my tryTabs(my gmailTabs(email, domain), startJS, parseJS)
	if res does not start with "ERR:" then return res

	-- no tab is signed in as wanted: open Gmail in the right Chrome profile,
	-- but only when the caller allows it (once per dialog)
	if (system attribute "FC_MAY_OPEN") is not "1" then return res
	do shell script quoted form of (libDir & "/open-gmail.sh") & " " & quoted form of email & " " & quoted form of domain
	delay 8
	return my tryTabs(my gmailTabs(email, domain), startJS, parseJS)
end run
