# Changelog

All notable changes to OhMyShot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
No releases or version tags have been published, so changes remain under Unreleased.
This initial backfill groups notable app changes from the first commit through [42c6bfa]; documentation-only work, internal refactors, and unmerged proposals are omitted.
Each entry links its implementation commits or merged pull request and credits verified contributors. Named coauthors follow explicit commit trailers.

## [Unreleased]

### Added

- Area, window, and full-display screenshots, Quick Access cards, and Capture History with configurable retention; selections can cross displays and use a self-timer. ([c999cc0], [47460d9], [4fba5e2]; by [@fzlzjerry])
- An annotation editor with drawing, shapes, text, blur, pixelation, and counters; backgrounds, combined images, and editable project files. ([82a1188], [72d434f]; by [@fzlzjerry])
- Annotation directly on the frozen selection, plus image resizing, rotation, flipping, highlight boxes, ratio crops, and saved colors in the editor. ([3301d5f], [6945ecb]; by [@fzlzjerry])
- Always-on-top pins for pictures, clipboard text, and colors, with Live Text in picture pins. ([c74adf4], [f8ecfb2], [fea8757]; by [@fzlzjerry])
- A screen color picker and pixel ruler for measuring distances and areas. ([f973024]; by [@fzlzjerry])
- OCR-based redaction suggestions and a highlighter that snaps to recognized text. ([e69955f], [b2c60ff]; by [@fzlzjerry])
- Capture Text copies recognized text from a selection; the Recognized Text window shows the image beside editable text, line-break controls, tables, and detected links and codes. ([c6b6b58], [8df4f3f]; by [@fzlzjerry])
- Translation in the OCR window and an in-place Translate Area overlay. ([0d924fd]; by [@fzlzjerry])
- Text search across Capture History, with recognition performed by a background helper. ([b9474f8]; by [@fzlzjerry])
- Optional downloadable on-device OCR model packs, with a second reading alongside Vision in the OCR window and History search. ([18059d3], [70711ac]; by [@fzlzjerry])
- Capture Formula and an optional formula pack; recognized formulas are inserted as LaTeX in Capture Text, the OCR window, and image-recognition automation. ([0897744], [cfbe3ac]; by [@fzlzjerry])
- Optional cloud OCR using a configured model and the user's own API key, including Read with in the OCR window and fallback to the Mac's reading. ([34f042b], [0f80678]; by [@fzlzjerry])
- Optional text supplied by the source app to refine recognized characters in Capture Text and the OCR window. ([9b5aa53]; by [@fzlzjerry])
- An optional VLM model pack for reading tables and charts within recognized text. ([1971598]; by [@fzlzjerry])
- Screen and window recording, GIF export, microphone and system audio, camera overlays, and displayed keystrokes. ([3e37cd6], [8ddb274]; by [@fzlzjerry])
- Studio editing for recordings, including automatic zooms, camera layout, motion blur, cursor and click effects, and adding keystrokes after recording. ([dd88b79], [195f1df], [131e96f]; by [@fzlzjerry])
- Scrolling Capture with manual scrolling and Auto-scroll to assemble a long image. ([fcdb351]; by [@fzlzjerry])
- All-In-One area setup with adjustable selection bounds, pixel-by-pixel arrow-key control, typed dimensions, and optional cursor capture. ([c174fbe], [d3f931c]; by [@fzlzjerry])
- Optional capture-selection snapping to text blocks, lists, code, and tables on a frozen screen. ([a941ced]; by [@fzlzjerry])
- PNG, JPEG, and HEIC output options, 1× scaling, sRGB, borders, and filename patterns; window screenshots can omit shadows or use the desktop wallpaper. ([4199e2c], [ce5cf5b]; by [@fzlzjerry])
- Printing from cards, History, pins, and the editor, including multi-page long captures; Share-menu import, Finder Open With, and Send by Email. ([b17e518], [528bbea]; by [@fzlzjerry])
- Uploads to user-owned storage with copied links, saved upload records, automatic upload options, and multipart transfers for large files. ([a1602ec], [c11532a]; by [@fzlzjerry])
- CleanShot-compatible URL commands, Apple Shortcuts capture actions, desktop-icon hiding, and dedicated copy, save, and annotate shortcuts. ([5b5abf6], [fb86ac4]; by [@fzlzjerry])
- Simplified and Traditional Chinese, Japanese, Spanish, and French interface translations. ([1c86bc4]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Per-window OCR text wrapping, a saved default for new windows, and horizontal scrolling when wrapping is off. ([#6]; by [@BenjaminD2023], [@fzlzjerry])
- Measurement snapping preferences and edge tolerance, with keyboard adjustments during measurement. ([#3]; by [@BenjaminD2023], [@fzlzjerry])
- A three-second Quick Access auto-close option; Never remains the default and saved delays are preserved. ([#5]; by [@BenjaminD2023], [@fzlzjerry])
- One- and two-second Quick Access auto-close options; Never remains the default and saved delays are preserved. ([#12]; by [@BenjaminD2023], [@fzlzjerry])
- A saved default for whether Capture Text and new Recognized Text windows keep or join the image's line breaks (Settings › Text › Image line breaks); Keep Line Breaks remains the default. ([#8]; by [@BenjaminD2023], [@fzlzjerry])
- Settings for where the Capture Text result card stands (below the selection, or in the bottom-left corner, above Quick Access's cards when they are there) and how long a card the user asked for stays; four seconds remains the default, and cards that report a problem keep at least their own time. ([#11]; by [@BenjaminD2023], [@fzlzjerry])
- An onboarding step, after Screen Recording, for turning off the macOS screenshot keys that answer OhMyShot's shortcuts first. ([b3ee8ce]; by [@fzlzjerry])
- Updates for release builds with Sparkle: about once a day (Settings › General › Updates, on by default), from signed appcasts on this repository's GitHub releases; a version found in the background waits in the menu bar menu and in Settings rather than in a window, and nothing is downloaded before it is chosen. ([d69ff9c]; by [@fzlzjerry])
- Settings › About › Acknowledgments…, with the licenses of OhMyShot and of the software it is built with. ([42c6bfa]; by [@fzlzjerry])
- Capture History selects several captures as Finder does (⌘-click, ⇧-click, ⌘A) to copy, save, restore, or move them to the Trash together, and ⌘O (File › Open in Editor) opens the selection in the editor. ([6523646]; by [@fzlzjerry])
- A right-click on the editor's tool rail lists every tool with its key. ([656bbcb]; by [@fzlzjerry])

### Changed

- Screenshot selection freezes the screen by default and retains the frozen image for the capture. ([1a44474]; by [@fzlzjerry])
- Quick Access supports automatic closing, either screen corner, three card sizes, keyboard operation, and picture transformations. ([d65a655]; by [@fzlzjerry])
- Settings split capture and tool options out of General, then gained a searchable sidebar, dedicated panes, and Back and Forward navigation. ([#1], [af0aa70], [d43258a]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Screenshot and annotation capture offer an optional centered, translucent actual-size picker with adjustable size and an adaptive target border. The centered picker and color reading clear when area selection begins; the crosshair remains, and the magnified loupe stays the default. ([#4]; by [@BenjaminD2023], [@fzlzjerry])
- Large measurement selections are analyzed in the background to keep the overlay responsive. ([#3]; by [@BenjaminD2023], [@fzlzjerry])
- Recording and Studio expose quality controls and estimated movie size; recording areas can be dimmed or framed, and automatic zooms better follow sustained activity. ([8cf6555], [202dc77], [a2f2527]; by [@fzlzjerry])
- Large and tall OCR images are read in bands, then assembled in image order to limit memory use. ([a8b2131], [14fdf15]; by [@fzlzjerry])
- Model-pack updates download only changed files instead of fetching the whole pack again. ([5a1dcd2]; by [@fzlzjerry])
- Quick Access: Delete alone no longer moves a card to the Trash (⌘Delete does); a card moved to the Trash waits five seconds under Undo (also ⌘Z and Restore Recently Closed) before its capture goes; side buttons keep fixed places; and a copy made from the keyboard says Copied on the card. ([4000b7c]; by [@fzlzjerry])
- Recording's Delete and Restart, and Scrolling Capture's Cancel once something is stitched, ask for a second click before throwing the recording or picture away. ([b67e465]; by [@fzlzjerry])
- Return in the annotation editor copies the picture and closes the window; Background has a rail symbol of its own; Marker Yellow leads the highlighter's colors in place of Yellow; size chips name their sizes. ([656bbcb], [733fd08]; by [@fzlzjerry])
- All-In-One leaves out its Copy chip while every capture is copied anyway, and Annotate has one symbol everywhere. ([e43c395]; by [@fzlzjerry])
- Settings search finds more rows and opens a pane on the row it found, its title lit for a moment. ([6523646], [78c83f6]; by [@fzlzjerry])
- Studio shows the chosen zoom's controls first in the inspector, says how to choose a stretch to cut, and dims Add Zoom where it has no room. ([97f9d2c]; by [@fzlzjerry])
- Simplified Chinese tells the Capture pane from Screenshots and counts captures as items. ([77b18cb]; by [@fzlzjerry])
- Settings has a Text pane for Capture Text's card, line breaks, text from apps, translation, model packs, and cloud reading, leaving Tools to colors, Measure, and pins; a search lists a pane it names first. ([892e562]; by [@fzlzjerry])
- Settings explains each group of rows behind one help button, its popover taking the rows in order, in place of a help button or a long tooltip beside every control. ([6481709], [53de98a]; by [@fzlzjerry])
- The recording bar's microphone and camera chips name the device they record in their tooltip and to VoiceOver. ([1d31f21]; by [@fzlzjerry])
- A paused recording shows a pause symbol for the red dot, pulses its time, and lights Resume. ([55956a4]; by [@fzlzjerry])
- The recording bar no longer opens in Studio after a Studio take; it opens with the last of Video and GIF. ([22e8288]; by [@fzlzjerry])

### Fixed

- OCR warmups no longer queue ahead of repeated Capture Text requests. Recognition has a complete-run deadline, cancelled captures leave newer results alone, and stalled model-reader helpers terminate on cancellation or timeout. (by [@BenjaminD2023])
- The native arrow appears over capture toolbar controls, and cursor visibility is restored correctly when returning to the canvas, cancelling, or entering another capture setup. ([#7]; by [@BenjaminD2023], [@fzlzjerry])
- Shortcut recorders support Use Anyway for menu conflicts, including Command-Shift-S; assigning a shortcut to another OhMyShot action clears the previous assignment. ([#2]; by [@BenjaminD2023], [@fzlzjerry])
- Measurement snapping better handles faint outlines and thin details, retaining the drawn rectangle when no credible boundary is found. ([#3]; by [@BenjaminD2023], [@fzlzjerry])
- Editor copies keep the annotation document that produced the copied image, and failed saves or drags no longer silently discard unkept edits. Quick Access holds captures while their editor loads and tracks hover after cards move. ([#5]; by [@BenjaminD2023], [@fzlzjerry])
- Unwrapped OCR windows no longer open with the first characters scrolled out of view. ([33cd6bf]; by [@fzlzjerry])
- Editor Undo and styled counter numbering behave consistently. ([4558f10]; by [@fzlzjerry])
- Pin zooming preserves the picture's proportions, and text pins allow selecting part of their text. ([b9c8e30], [9d53b01]; by [@fzlzjerry])
- VoiceOver names the Save buttons in the editor, recording window, and Studio, and presses History's cards. ([745e2f4]; by [@fzlzjerry])
- Onboarding avoids duplicate Screen Recording permission prompts and actually reopens the app after Quit & Reopen. ([6ec2f1d]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Launch at login toggles the login item on and off again. ([3c49e89]; by [@fzlzjerry])
- Quick Access repositions cards when displays are disconnected; cards and pins place their More menus beside them where they fit. ([bb75542], [460c047], [3750631]; by [@bobbyhuang-dev]; coauthored by Claude Opus 5.5)
- Scrolling captures reduce repeated fixed buttons, sticky-sidebar seams, and gaps around rounded window corners. ([e3e5215], [c7ea72a], [e895346], [2ebd715]; by [@fzlzjerry])
- Scrolling captures incorporate images that load after scrolling starts and keep continuously changing content together as a frame instead of a patchwork. ([6c56a00], [c319bdb], [309c84b]; by [@fzlzjerry])
- Scrolling and Auto-scroll continue through long blank stretches, and repeated table cells retain the correct row numbers. ([0d32c35], [b65fad1], [35c03e9]; by [@fzlzjerry])
- Recording warns when a microphone stops delivering audio instead of leaving a disconnected microphone silently recording. ([450f4a6]; by [@fzlzjerry])
- Closing History and editors releases more memory, clipboard TIFFs use compression, and GIF frame buffers return their memory when freed. ([cff3ddb], [0182817], [6d3b0af]; by [@fzlzjerry])
- Capture History's Move All to Trash acts on what the window shows, states the count, and no longer says captures can be put back from the Trash. ([6523646]; by [@fzlzjerry])
- Recording shows when the microphone was left out because access to it is off, the microphone chip shows that before recording, and a recording that can't start says so on screen. ([b67e465]; by [@fzlzjerry])
- A scrolling capture whose Auto-scroll needs Accessibility keeps its framed area for the next try, and its warnings stand apart from its progress. ([b67e465]; by [@fzlzjerry])
- The editor's style capsule no longer covers the next line of text under a highlight drawn freely. ([656bbcb]; by [@fzlzjerry])
- VoiceOver names the app a History card was taken in and the action of each shortcut recorder in Settings. ([e45b631]; by [@fzlzjerry])
- The Settings window opened on General is titled General, not "Untitled". ([8ea9c06]; by [@fzlzjerry])
- The capture overlay shows one pointer at a time: the system's pointer no longer stays beside the drawn crosshair (two crosshairs after Capture Text), and Capture Text's crosshair shows from the start. ([43a1529], [7fc5a39], [1134e64]; by [@fzlzjerry])

[Unreleased]: https://github.com/fzlzjerry/OhMyShot/commits/main/
[c999cc0]: https://github.com/fzlzjerry/OhMyShot/commit/c999cc03ce4ca38c5596a17b13265ddebd1cc54d
[47460d9]: https://github.com/fzlzjerry/OhMyShot/commit/47460d9161fd9a2526b7964ce00a5727a34b688d
[4fba5e2]: https://github.com/fzlzjerry/OhMyShot/commit/4fba5e228a53a7d7bf18be4495663cd7c89c4287
[82a1188]: https://github.com/fzlzjerry/OhMyShot/commit/82a11888819ad0d40fb218aa36d131aa68adc58d
[72d434f]: https://github.com/fzlzjerry/OhMyShot/commit/72d434f62e04cd4b33fadf846b962b1bac3e1ca0
[3301d5f]: https://github.com/fzlzjerry/OhMyShot/commit/3301d5f1b386f9fa69ab6075c44bf2c8940a2da9
[6945ecb]: https://github.com/fzlzjerry/OhMyShot/commit/6945ecbac64adce3019999530804d00407c290fb
[c74adf4]: https://github.com/fzlzjerry/OhMyShot/commit/c74adf4e724c95c7dbf888afa45a542142b4d209
[f8ecfb2]: https://github.com/fzlzjerry/OhMyShot/commit/f8ecfb256574cc5552fbb8e61ced67d6c02db0da
[fea8757]: https://github.com/fzlzjerry/OhMyShot/commit/fea875732b2595616c5b7d16545bce2e2c496e36
[f973024]: https://github.com/fzlzjerry/OhMyShot/commit/f973024fcb9bf539d9cf28dd803250222f5be2aa
[e69955f]: https://github.com/fzlzjerry/OhMyShot/commit/e69955f2031770af0abb78d3464eff3e95966dd5
[b2c60ff]: https://github.com/fzlzjerry/OhMyShot/commit/b2c60ff12b4fc33cbc2fa0aad013ddb73c279402
[c6b6b58]: https://github.com/fzlzjerry/OhMyShot/commit/c6b6b58d9feb626a5c935e339a04c77f588503e7
[8df4f3f]: https://github.com/fzlzjerry/OhMyShot/commit/8df4f3f8d2aad82dd5a05456ba5d8370f5ba0421
[0d924fd]: https://github.com/fzlzjerry/OhMyShot/commit/0d924fd533ac5d9dc7d2d9e11307f597d883a9e2
[b9474f8]: https://github.com/fzlzjerry/OhMyShot/commit/b9474f842e72f1728c9d2f442f77c8d626ee9901
[18059d3]: https://github.com/fzlzjerry/OhMyShot/commit/18059d3891ba14edc1ec4a8522ea910edcee3fb9
[70711ac]: https://github.com/fzlzjerry/OhMyShot/commit/70711acddc0091474e5f1571bff0df77fe8116c0
[0897744]: https://github.com/fzlzjerry/OhMyShot/commit/0897744a2786821f516641d646e7989f78d5f0b2
[cfbe3ac]: https://github.com/fzlzjerry/OhMyShot/commit/cfbe3ac01fe669db99e6192732f6e6d0a71d5471
[34f042b]: https://github.com/fzlzjerry/OhMyShot/commit/34f042b51c3dac788b8fdfcd48772b5e2dc56ea8
[0f80678]: https://github.com/fzlzjerry/OhMyShot/commit/0f806785933230e3a409195b9d654d2ded7a6aeb
[9b5aa53]: https://github.com/fzlzjerry/OhMyShot/commit/9b5aa530a82bc7c0477183980f206de80d86bdb1
[1971598]: https://github.com/fzlzjerry/OhMyShot/commit/19715982bdbc99afadb76beca65135f0449aab57
[3e37cd6]: https://github.com/fzlzjerry/OhMyShot/commit/3e37cd6e1d7c58679695b09abef607f55b9f4fc8
[8ddb274]: https://github.com/fzlzjerry/OhMyShot/commit/8ddb274d5db440bb2100d028b61e5460d0ab2917
[dd88b79]: https://github.com/fzlzjerry/OhMyShot/commit/dd88b79ccf00c521232ef02415fcea3f1c92525b
[195f1df]: https://github.com/fzlzjerry/OhMyShot/commit/195f1df86d253790bcf108089082b333cff2c035
[131e96f]: https://github.com/fzlzjerry/OhMyShot/commit/131e96fa5a3f9f4c9076a6c4d260112e0a33381f
[fcdb351]: https://github.com/fzlzjerry/OhMyShot/commit/fcdb351c46f9fea7dce8dd2d6ae7c62771bbb59e
[c174fbe]: https://github.com/fzlzjerry/OhMyShot/commit/c174fbe4fc0e4b3410ab708953c84fae67e80e78
[d3f931c]: https://github.com/fzlzjerry/OhMyShot/commit/d3f931ccb2083822e154b57ae34e2a22c96a4df9
[a941ced]: https://github.com/fzlzjerry/OhMyShot/commit/a941cedfeea506b39642bf2b29d09c530deb192b
[4199e2c]: https://github.com/fzlzjerry/OhMyShot/commit/4199e2c517bedf30925318b44cd5fee24512df84
[ce5cf5b]: https://github.com/fzlzjerry/OhMyShot/commit/ce5cf5bdd0c9ba422de3fb37305b99cd52b196d9
[b17e518]: https://github.com/fzlzjerry/OhMyShot/commit/b17e518fae244c2b4e3a78d84cccb1bb478ca230
[528bbea]: https://github.com/fzlzjerry/OhMyShot/commit/528bbeaeefe3af7122e3065fe33812f6fea66b24
[a1602ec]: https://github.com/fzlzjerry/OhMyShot/commit/a1602ec028369cad8f6cc9310ab0747f2d1b745d
[c11532a]: https://github.com/fzlzjerry/OhMyShot/commit/c11532a4a679d86660bb43913b6b830133eb3234
[5b5abf6]: https://github.com/fzlzjerry/OhMyShot/commit/5b5abf6c41df6b7fb30802ff6ad4b28f04f72722
[fb86ac4]: https://github.com/fzlzjerry/OhMyShot/commit/fb86ac4001e980ed2f34a06ff7662a7a2ccea256
[1c86bc4]: https://github.com/fzlzjerry/OhMyShot/commit/1c86bc4768690cfb88c5ca805cffb7e800b60128
[#6]: https://github.com/fzlzjerry/OhMyShot/pull/6
[#3]: https://github.com/fzlzjerry/OhMyShot/pull/3
[#5]: https://github.com/fzlzjerry/OhMyShot/pull/5
[1a44474]: https://github.com/fzlzjerry/OhMyShot/commit/1a444742c501ebab637a097fa38b13d3ef4905f6
[d65a655]: https://github.com/fzlzjerry/OhMyShot/commit/d65a655463baf3b3494f76e7d9fcdc1f54db5b76
[#1]: https://github.com/fzlzjerry/OhMyShot/pull/1
[af0aa70]: https://github.com/fzlzjerry/OhMyShot/commit/af0aa70b6ac1466d1cc704d586854c48dfc8fbc8
[d43258a]: https://github.com/fzlzjerry/OhMyShot/commit/d43258a2f8e382e07537e54f5a946b89fa2f19f9
[#4]: https://github.com/fzlzjerry/OhMyShot/pull/4
[8cf6555]: https://github.com/fzlzjerry/OhMyShot/commit/8cf6555894ed714a157a5bd0a26ca080f340ce58
[202dc77]: https://github.com/fzlzjerry/OhMyShot/commit/202dc77659b133db41357fc3fec47001100970f2
[a2f2527]: https://github.com/fzlzjerry/OhMyShot/commit/a2f25279207fdc5673f9abbef7f369fd849817b1
[a8b2131]: https://github.com/fzlzjerry/OhMyShot/commit/a8b2131897ec0d0306825f11b01c2488fa2b8de8
[14fdf15]: https://github.com/fzlzjerry/OhMyShot/commit/14fdf152fbc4a8cd3350422f13678026562e83a5
[5a1dcd2]: https://github.com/fzlzjerry/OhMyShot/commit/5a1dcd217dafe7daa2f6b1ae3e3a4d6fa5c933fc
[#7]: https://github.com/fzlzjerry/OhMyShot/pull/7
[#2]: https://github.com/fzlzjerry/OhMyShot/pull/2
[33cd6bf]: https://github.com/fzlzjerry/OhMyShot/commit/33cd6bf3b697c6cad2acebb474b847577cf1634c
[4558f10]: https://github.com/fzlzjerry/OhMyShot/commit/4558f101adaede630f73711178dbca08e5f45208
[b9c8e30]: https://github.com/fzlzjerry/OhMyShot/commit/b9c8e307af33415680b785a27a092d53af506a60
[9d53b01]: https://github.com/fzlzjerry/OhMyShot/commit/9d53b0155c23bca79440eeac136df4d7bccefc09
[6ec2f1d]: https://github.com/fzlzjerry/OhMyShot/commit/6ec2f1d81545ea65b6e599544dd1ae1fc8a29ccb
[3c49e89]: https://github.com/fzlzjerry/OhMyShot/commit/3c49e89eac218d01d1b97df2392d4e86e79808dc
[bb75542]: https://github.com/fzlzjerry/OhMyShot/commit/bb75542e8236a7ecee19a393fd4c891e3c1ea49c
[460c047]: https://github.com/fzlzjerry/OhMyShot/commit/460c047f5e3c314186779bb6a54bac9314bcb260
[3750631]: https://github.com/fzlzjerry/OhMyShot/commit/37506310b3704d145008e84a7abe6c7c9391d8b9
[e3e5215]: https://github.com/fzlzjerry/OhMyShot/commit/e3e5215b31f9aafe6fd5ed0a1b0c6c3fa890e2cd
[c7ea72a]: https://github.com/fzlzjerry/OhMyShot/commit/c7ea72a7cfe9a4a579672ca0f793867372f8fa0b
[e895346]: https://github.com/fzlzjerry/OhMyShot/commit/e895346ace94a9891a54877883ab7911daf51bd0
[2ebd715]: https://github.com/fzlzjerry/OhMyShot/commit/2ebd715ba48e2c558f7007219e0c18d05d13ec25
[6c56a00]: https://github.com/fzlzjerry/OhMyShot/commit/6c56a0024f0ca74696aabf71ee3b6f7c384445db
[c319bdb]: https://github.com/fzlzjerry/OhMyShot/commit/c319bdbc7803dd7da371d6e9c60588dc247943e6
[309c84b]: https://github.com/fzlzjerry/OhMyShot/commit/309c84ba8543170b6b07e0a2416482813e03ab84
[0d32c35]: https://github.com/fzlzjerry/OhMyShot/commit/0d32c35d4540741598eedff0c9e2afe023a1fcd4
[b65fad1]: https://github.com/fzlzjerry/OhMyShot/commit/b65fad1cf114765b718daa53c904b5f1744231ee
[35c03e9]: https://github.com/fzlzjerry/OhMyShot/commit/35c03e9f0a13696c466250f48b477c226fd568dd
[450f4a6]: https://github.com/fzlzjerry/OhMyShot/commit/450f4a6c60a5247daf0028ead3b7c58128018980
[cff3ddb]: https://github.com/fzlzjerry/OhMyShot/commit/cff3ddb3ca3bd762ed203a21b32a04443e27eaec
[0182817]: https://github.com/fzlzjerry/OhMyShot/commit/01828172073f4816c9dba6054957f27d631abee8
[6d3b0af]: https://github.com/fzlzjerry/OhMyShot/commit/6d3b0af34efe0b65102e02e829c53f5f31f5b203
[#12]: https://github.com/fzlzjerry/OhMyShot/pull/12
[#8]: https://github.com/fzlzjerry/OhMyShot/pull/8
[#11]: https://github.com/fzlzjerry/OhMyShot/pull/11
[42c6bfa]: https://github.com/fzlzjerry/OhMyShot/commit/42c6bfada8d898892676d32b2b0daa0bdcc878b6
[b3ee8ce]: https://github.com/fzlzjerry/OhMyShot/commit/b3ee8ce17153c308b1247a9eb28f487af92dca85
[745e2f4]: https://github.com/fzlzjerry/OhMyShot/commit/745e2f4e76a8be01f02ca25c84a8e4dc6d08ffef
[d69ff9c]: https://github.com/fzlzjerry/OhMyShot/commit/d69ff9c7a0c3b71e9eb6a7146d831af4fcb36f6c
[77b18cb]: https://github.com/fzlzjerry/OhMyShot/commit/77b18cbdac714a39f5338e7cbafde8a72ff22454
[4000b7c]: https://github.com/fzlzjerry/OhMyShot/commit/4000b7cc3febbcddda7133414a339d38457342dc
[6523646]: https://github.com/fzlzjerry/OhMyShot/commit/6523646dc6302412d56d33eafa1c8bc070f638b1
[b67e465]: https://github.com/fzlzjerry/OhMyShot/commit/b67e465792577aff675d28115c1089db4be74eba
[e43c395]: https://github.com/fzlzjerry/OhMyShot/commit/e43c3955b5bf52e841f9786d0caeafca3ca3c9cf
[656bbcb]: https://github.com/fzlzjerry/OhMyShot/commit/656bbcba7b3bf9cfe0764069f8f37bbbfdd204be
[97f9d2c]: https://github.com/fzlzjerry/OhMyShot/commit/97f9d2cdc702585b8aa3710c7d5207ba07ff9f69
[733fd08]: https://github.com/fzlzjerry/OhMyShot/commit/733fd0888bc8ca99ce1e47779f825d0ceaf65a74
[78c83f6]: https://github.com/fzlzjerry/OhMyShot/commit/78c83f6af6e5f4430afc4cd31a48a6fd8d3659e1
[892e562]: https://github.com/fzlzjerry/OhMyShot/commit/892e56289c3bd28239e252f4b281990d0c53c297
[6481709]: https://github.com/fzlzjerry/OhMyShot/commit/648170986ddcf368b463765beebbe7e2da24beeb
[1d31f21]: https://github.com/fzlzjerry/OhMyShot/commit/1d31f2128dc52cca7858222220a64170840128f7
[55956a4]: https://github.com/fzlzjerry/OhMyShot/commit/55956a475a12b5a240a724e0b883c37f6349dd05
[22e8288]: https://github.com/fzlzjerry/OhMyShot/commit/22e82886573cf4f32ba53e585bc2ee721005cd6f
[e45b631]: https://github.com/fzlzjerry/OhMyShot/commit/e45b631339ca0660b6a8ebdf72df23c1266282c3
[53de98a]: https://github.com/fzlzjerry/OhMyShot/commit/53de98a3004745d40add007ab82b620de21365ba
[8ea9c06]: https://github.com/fzlzjerry/OhMyShot/commit/8ea9c0654dce1dc928ceafeed629c892178219de
[43a1529]: https://github.com/fzlzjerry/OhMyShot/commit/43a15294271a0090ffb0da5f84a4cedf97301019
[7fc5a39]: https://github.com/fzlzjerry/OhMyShot/commit/7fc5a392938eb0df2f07ee4e2c238fd569a4070d
[1134e64]: https://github.com/fzlzjerry/OhMyShot/commit/1134e6464c53f5dae261be1fa041c64098684c69
[@BenjaminD2023]: https://github.com/BenjaminD2023
[@bobbyhuang-dev]: https://github.com/bobbyhuang-dev
[@fzlzjerry]: https://github.com/fzlzjerry
