AlwaysUp
========

Keeps your Mac, and the AI agents running on it, awake with the lid closed.

Install
-------
1. Drag AlwaysUp onto the Applications folder in this window.
2. Open AlwaysUp from Applications. Its icon appears in the menu bar.

If macOS says it can't open AlwaysUp
------------------------------------
This copy is not notarized by Apple (that needs a paid developer account), so
macOS blocks it the first time. To allow it:

  - Open System Settings > Privacy & Security, scroll down to the message about
    AlwaysUp, click "Open Anyway", then open the app again.

  - Or, in Terminal:
      xattr -dr com.apple.quarantine /Applications/AlwaysUp.app

If you'd rather not do that, build it yourself from the source code instead;
a copy you build is never blocked. The instructions are in the project README.

Uninstall
---------
Quit AlwaysUp from its menu, then delete it from Applications. If you turned on
"Passwordless mode", turn it off in the app first, or run:
  sudo rm /etc/sudoers.d/alwaysup

Disclaimer
----------
AlwaysUp is free, open-source software under the MIT License (see LICENSE.txt),
provided "as is" with no warranty. You use it at your own risk.

It stops your Mac sleeping with the lid closed. A laptop kept awake in a bag
can get very hot and damage itself or its battery; don't leave it running
where it can't cool down, and leave the battery and overheating guards on.
Saver Mode pauses and can quit other apps, which may lose unsaved work.

The authors are not liable for any damage, data loss or cost. AlwaysUp is not
affiliated with Apple or with any company whose products it detects.
Full text: https://github.com/SahejAgarwal05/AlwaysUp/blob/main/DISCLAIMER.md
