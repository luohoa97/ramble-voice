# Privacy

Ramble Voice has no backend, no telemetry, no analytics and no accounts. This
page lists everything that can leave your device.

## What stays on the device

- Recorded audio, transcripts, cleaned text, history, style profile and
  settings are stored locally. In on-device mode nothing is sent anywhere.
- Your Gemini API key is stored in the platform secret store (libsecret on
  Linux, Android Keystore-backed storage on Android). On Linux you may instead
  supply it through the `GEMINI_API_KEY` environment variable, which takes
  precedence. With a Flatpak override the key is stored in plain text in the
  override file.

## Network traffic

| Traffic | When | Where |
|---|---|---|
| Model download | You tap Download in Settings, Engine | Hugging Face (litert-community), verified by SHA-256 |
| Gemini requests | Only in cloud mode, with your own key | Google Generative Language API (`generativelanguage.googleapis.com`), including `GET /v1beta/models` to list models |

Nothing else. If you see other traffic, please report it as a security issue.

## Gemini cloud mode

You bring your own key from Google AI Studio. Audio of your recordings is sent
to Google for processing. On Google's free tier, Google may use content to
improve its products, and human reviewers may read it. Users in the EEA, UK and
Switzerland get paid-tier terms. The app shows: "Free-tier requests may be used
by Google to improve its products." Use on-device mode for anything sensitive.

## Text-only

The output is text. Spoken or pasted instructions are transcribed, not obeyed,
and the app never executes commands.

## Permissions

- Microphone, to record while you dictate.
- Android: the keyboard (input method) permission you grant by enabling it.
- Linux: portal prompts for global shortcuts and for input injection
  (RemoteDesktop). The Flatpak requests network, Wayland/X11, GPU, audio,
  the secret service and tray D-Bus names.
