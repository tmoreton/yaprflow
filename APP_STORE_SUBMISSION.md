# Mac App Store Submission

This is the working App Store Connect copy and final submission checklist for
Yaprflow 4.0.14.

## Product page

- **Name:** Yaprflow
- **Subtitle:** Private voice dictation
- **Primary category:** Productivity
- **Secondary category:** Utilities
- **Price:** Free
- **Marketing URL:** https://yaprflow.com/
- **Support URL:** https://yaprflow.com/
- **Privacy policy URL:** https://yaprflow.com/privacy.html
- **Keywords:** dictation,voice,text,transcription,offline,private,speech,productivity

### Description

Yaprflow is private voice dictation for your Mac. Press Command-T, speak
naturally, press Command-T again, and paste clean text into any app.

Speech recognition runs locally with Core ML. The complete speech model is
included with Yaprflow, so your audio and transcripts do not need to leave your
Mac. There are no accounts, ads, analytics, or tracking.

Features:

- Start and stop dictation with a customizable global keyboard shortcut
- See a live transcript in a compact desktop overlay
- Automatically copy finished text to the clipboard
- Keep a searchable local Markdown history
- Correct names, acronyms, and preferred spellings with a local vocabulary
- Dictate in 25 automatically detected European languages
- Summarize or rewrite transcripts with Apple Intelligence on supported Macs
- Generate local titles and topics for transcript history on supported Macs

Yaprflow requires macOS 14 Sonoma or later. Apple Intelligence features require
a compatible Mac with Apple Intelligence enabled and macOS 26 or later.

## App privacy answers

- **Data collected:** No
- **Tracking:** No
- **Privacy manifest:** Included in the app bundle

The app processes microphone audio on-device, stores transcripts and settings
only in its sandboxed container, and does not transmit user data to the
developer. The optional Apple Intelligence features use Apple's on-device
Foundation Models framework.

## Content rights

Answer **Yes** when asked whether the app contains or accesses third-party
content. Yaprflow has distribution rights under the bundled licenses:

- FluidAudio and VBx: Apache License 2.0
- fastcluster: BSD license
- Silero VAD: MIT License
- Parakeet TDT 0.6B v3 Core ML model: CC BY 4.0

Attributions and license text are included in Settings > Acknowledgements.

## Review notes

Yaprflow is a menu-bar app, so it does not show a Dock icon during normal use.
No account or login is required.

To test the main flow:

1. Launch Yaprflow and grant microphone access during onboarding.
2. Click the waveform icon in the menu bar, or press Command-T.
3. Speak a sentence, then press Command-T again.
4. The finished text is copied to the clipboard and saved in local History.
5. Open the menu-bar item and choose History to view the saved transcript.

The complete speech model is bundled with the app; no model download is
required. The first dictation can take longer while Core ML prepares the model.

AI Summary is optional. It requires macOS 26, a supported Mac, and Apple
Intelligence enabled in System Settings. Reviewers can evaluate the core
dictation flow without it.

## Screenshots

The submitted set contains four 2560 × 1600 RGB PNGs in this order:

1. Private, offline dictation onboarding
2. Live dictation overlay with transcript text
3. Settings privacy overview
4. Copied-to-clipboard confirmation

Do not show private transcript content, another company's trademarks, or
placeholder UI.

## Before uploading

- [x] Deploy `docs/privacy.html` so https://yaprflow.com/privacy.html is live.
- [x] Register bundle ID `com.tmoreton.yaprflow`.
- [x] Create App Store Connect record `6810892725` for macOS.
- [x] Create the Apple Distribution certificate and Mac App Store provisioning
  profile for team `GVXC5FQ2RP`.
- [x] Export the signed installer to
  `AppStore/Builds/Yaprflow-4.0.14-build-1.pkg`.
- [x] Prepare four 2560 × 1600 screenshots in `AppStore/Screenshots`.
- [x] Set the app to free and available in all 175 countries or regions.
- [x] Supply the reviewer contact name, email, and phone number.
- [x] Save the product-page copy and reviewer notes in App Store Connect.
- [x] Publish App Privacy as Data Not Collected.
- [x] Complete the 4+ age-rating questionnaire.
- [x] Declare licensed third-party content rights.
- [x] Add the microphone sandbox entitlement usage explanation.
- Increment `CURRENT_PROJECT_VERSION` for every uploaded build.
- [x] Upload signed build 4.0.14 (1) through Xcode.
- [x] Select the processed build and upload the four screenshots.
- [x] Submit macOS 4.0.14 for App Review.

## Submission status

- **Submitted:** September 10, 2026 at 10:30 PM EDT
- **Submission ID:** `802b609b-16bf-404e-a39f-fd9b08f41e24`
- **Status:** Waiting for Review
- **Release:** Automatically after approval
