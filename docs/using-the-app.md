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

## Paste images and use stickers

Tap **Stickers** in the drawing editor. **Paste** imports an image you copied; **Photos** and **Files** import images directly. You can also drop an image onto this canvas. Tap a sticker (or its thumbnail) to select it, drag to pan, pinch to shrink or enlarge, and twist to tilt. **Size** gives precise control, **Center** brings it back into the frame, **Reset tilt** straightens it, and **Delete** removes it. Transparent images retain transparency. Stickers sit above the drawing and remain separate editable objects.

For keyboard stickers, tap **Keyboard**, switch to your emoji/sticker keyboard, and choose a sticker. The app accepts image attachments and, on iOS 18 or later, adaptive image glyphs such as supported custom emoji. **Add typed emoji** can turn typed emoji into an image. A third-party keyboard that provides only text or a link may need its image copied into **Paste** instead. Animated images become still stickers; keyboard availability depends on the keyboard and device and needs physical-device testing.

Stickers save locally with the draft and are shared on **Apply**, including in Our art; they do not stream live like stroke operations. Both phones and the Python server should use this version. A canvas supports up to 12 stickers within a 1.5 MB total image limit.

## History and local data

**History** shows applied revisions. Use the share icon to export a PNG manually. **History → Delete all** removes saved revisions and exported PNGs for the open canvas *on this phone*, after confirmation. The editable drawing and paired server copy remain; Apply again to give the Shortcut a current version. Recovered drafts are also in History, but do not replace the applied wallpaper.

Keep the same app bundle ID and signing Team when installing an update to preserve local documents. Deleting the app removes its local data unless you have a backup. When moving from the earlier fixed 390 × 844 build, open the updated app and Apply again so its wallpaper uses the phone's dimensions.

## Lock Screen widget

The **CoupleDrawWidget** extension offers circular, rectangular, and inline Lock Screen styles. Long-press the Lock Screen, choose **Customize → Lock Screen → Add Widgets**, find **CoupleDraw**, add **Open CoupleDraw**, and tap **Done**. Tapping it launches the app with My art selected; iOS may require you to unlock. The widget is a launcher and does not set the wallpaper or display the current drawing. If missing, check that the widget was signed with its own compatible bundle ID and embedded in the installed app.

## Clear cache

Open **Setup → Local storage → Clear cache** to remove rendered wallpaper PNGs and unused media files. The size shown is the removable cache on this phone. Editable drafts, pairing, applied History, and original photos/stickers still referenced by those documents are preserved. Missing PNGs regenerate from local artwork when needed; a paired Shortcut still checks the service for the latest revision. To remove old original images still referenced by History, use **History → Delete all** for that canvas, then Clear cache. Photos/stickers still used by the current draft remain.
