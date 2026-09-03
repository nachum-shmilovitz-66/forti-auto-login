on run argv
  set procName to item 1 of argv
  set out to ""
  tell application "System Events" to tell process procName
    repeat with w in windows
      set out to out & "WINDOW: " & (name of w as text) & " | " & (subrole of w as text) & linefeed
      set els to entire contents of w
      repeat with e in els
        try
          set r to role of e
          set n to ""
          try
            set n to name of e as text
          end try
          set v to ""
          try
            set v to value of e as text
          end try
          set d to ""
          try
            set d to description of e as text
          end try
          set out to out & "  " & r & " | name=" & n & " | value=" & v & " | desc=" & d & linefeed
        end try
      end repeat
    end repeat
  end tell
  return out
end run
