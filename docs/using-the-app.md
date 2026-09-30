# Using CoupleDraw

[Back to README](../README.md)

## Choose a canvas and draw

The **Canvas** picker chooses the drawing you are looking at:

| Canvas | Who edits it | When your partner sees it |
| --- | --- | --- |
| My art | You | After you tap Apply |
| Partner's art | Your partner; view-only here | After your partner taps Apply |
| Our art | Both of you | Completed stroke edits appear while both apps are open; either person can Apply a saved wallpaper |

Tap the preview or **Draw** to open the full-screen editor. PencilKit tools include pen, eraser, and lasso. Two fingers pan or zoom; **Fit** shows the complete canvas, and the miniature canvas shows where you are when zoomed in. Tap **Done** to close the editor and keep the draft. **Apply** on the main screen saves a version, publishes it when paired, and shows a small confirmation banner. A draft and an applied wallpaper are separate: your partner's My art and the wallpaper Shortcut use the latest applied version.

In Our art, both phones can add, move, erase, and clear strokes. Finished gestures sync after a short batching window while the app is active; unfinished pen movement and partner cursors do not stream. Incoming edits wait for your current gesture to finish. **Clear all** asks for confirmation and removes the visible shared strokes; background and History remain. Concurrent strokes added by the other phone are preserved. Undo and redo affect your edits rather than erasing unrelated partner strokes. If both edit the same stroke at once, the rejected version is kept in **History → Recovered draft** on that phone.

## Add a background

In the drawing editor tap **Photo**, then **Camera**, **Photos**, or **Files**. Frame the image with drag, pinch, and rotation gestures; the zoom and rotation sliders allow finer control. The visible frame is the part behind your drawing. Tap **Save** to use it; you can reframe or remove the photo later without deleting strokes. A camera capture stays in the draft and is not automatically saved to Photos. Camera access is requested when you use Camera, and Camera is unavailable in the iOS Simulator.

Artwork is rendered at the receiving phone's portrait pixel dimensions for the Shortcut. iOS's wallpaper composer may still zoom or reframe the result.

## Choose what this phone displays

**My Lock Screen shows** is separate from the **Canvas** picker. Select **My art**, **Partner's art**, or **Our art**; this affects only what the Shortcut returns on *this phone*. Each person can make a different choice. Apply the selected canvas at least once before running the Shortcut. For Partner's art, pair first and have your partner apply My art.

Read [wallpaper and automations](wallpaper-and-automations.md) to create the Shortcut and optionally respond to a partner Apply while the app is closed.

## History and local data

**History** shows applied revisions. Use the share icon to export a PNG manually. **History → Delete all** removes saved revisions and exported PNGs for the open canvas *on this phone*, after confirmation. The editable drawing and paired server copy remain; Apply again to give the Shortcut a current version. Recovered drafts are also in History, but do not replace the applied wallpaper.

Keep the same app bundle ID and signing Team when installing an update to preserve local documents. Deleting the app removes its local data unless you have a backup. When moving from the earlier fixed 390 × 844 build, open the updated app and Apply again so its wallpaper uses the phone's dimensions.

## Lock Screen widget

The **CoupleDrawWidget** extension offers circular, rectangular, and inline Lock Screen styles. Long-press the Lock Screen, choose **Customize → Lock Screen → Add Widgets**, find **CoupleDraw**, add **Open CoupleDraw**, and tap **Done**. Tapping it launches the app with My art selected; iOS may require you to unlock. The widget is a launcher and does not set the wallpaper or display the current drawing. If missing, check that the widget was signed with its own compatible bundle ID and embedded in the installed app.
