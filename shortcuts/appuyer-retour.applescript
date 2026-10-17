-- Raccourci « Appuyer Retour » — action « Exécuter un script AppleScript ».
-- AppleScript plutôt que shell : c'est la forme dont l'envoi de la touche a été validé à la voix.
tell application "System Events" to key code 36
do shell script "osascript -l JavaScript \"$HOME/Library/Application Support/handfree-code/handfree.js\" --done"
