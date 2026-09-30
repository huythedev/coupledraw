# Wallpaper and automations

[Back to README](../README.md)

## Create the Shortcut on each phone

1. In CoupleDraw, choose a source under **My Lock Screen shows**. Apply My art or Our art first; for Partner's art, pair and wait for your partner to Apply My art.
2. In Shortcuts, make a new Shortcut with **Get My CoupleDraw Wallpaper**, followed by **Set Wallpaper** using the returned image. Choose the Lock Screen as the destination. If Set Wallpaper offers **Show Preview**, turn it off.
3. Run the Shortcut manually on that iPhone and verify the selected image and any Save or confirmation prompt. Give your partner their own Shortcut on their own phone.

Get My CoupleDraw Wallpaper checks the paired service once when invoked, even if the main app is closed, and returns the latest applied image for *that phone's* choice and screen size. If the server cannot be reached, the action reports an error instead of silently applying an old paired image. The pairing token can be used after the phone has been unlocked once since reboot; open the updated app once while unlocked after upgrading to migrate existing credentials.

Apple controls the Set Wallpaper action. CoupleDraw cannot directly call a public iOS API to set the Lock Screen, launch the partner's Shortcut remotely, or bypass an iOS Save screen. An automation does not remove a prompt if the action itself asks for one.

## Respond to a partner Apply

While the app is open, it waits on the server for changes and may show a local alert after a partner Apply. A suspended or closed app does not keep this connection. For an alert while it is closed:

- **Personal Team:** Configure ntfy on the [server](server.md#optional-ntfy-alerts-with-a-personal-team), subscribe to *your own* private topic in the ntfy iPhone app, and allow ntfy notifications.
- **Push-capable team:** Configure [direct APNs](server.md#optional-direct-apns), sign the app with Push, and enable partner alerts in Pair.

Where supported on the installed iOS version, create a personal Shortcuts **Notification** automation filtered by app **ntfy** (or **CoupleDraw** for direct APNs) and title **CoupleDraw wallpaper ready**. Have it run your tested wallpaper Shortcut. Check the options for running without asking and, if offered, while locked. Test with the screen unlocked and locked. Notification delivery, an automation running while locked, and wallpaper confirmation are under iOS control and are not guaranteed by this app.

If you do not want an alert, you can run the Shortcut yourself or use a scheduled automation. A scheduled run checks the latest state only at its scheduled time and may apply the same image again. Turning off banners or Lock Screen display for ntfy is an iOS notification preference; verify on your phone whether your Notification automation still triggers.

Neither ntfy nor APNs sets the wallpaper by itself. Alerts say that a partner applied a revision; the receiving phone fetches its own chosen source when the Shortcut runs. Our art's live stroke edits do not themselves publish a new wallpaper until someone taps Apply.

## What to expect while locked

The App Intent is configured to run without opening CoupleDraw, and the pairing token is available after the first unlock since reboot. iOS still decides whether the automation and Set Wallpaper action may complete while locked. If the shortcut asks for confirmation in a manual run, test a notification automation on the actual device rather than assuming it can dismiss that screen. Unlock and run the Shortcut manually if needed.

Apple's guides: [personal automations](https://support.apple.com/guide/shortcuts/intro-to-personal-automation-apd690170742/ios), [notification trigger](https://support.apple.com/guide/shortcuts/apd932ff833f/ios), and [App Intents](https://developer.apple.com/documentation/appintents/appintent). Apple also says [background push delivery is not guaranteed](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).
