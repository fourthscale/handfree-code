-- Shortcut "Press Return" — action "Run AppleScript".
-- AppleScript rather than shell: the form whose key press was validated by voice.
tell application "System Events" to key code 36
do shell script "osascript -l JavaScript \"$HOME/Library/Application Support/handfree-code/handfree.js\" --done"
