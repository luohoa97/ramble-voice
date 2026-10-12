# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub private vulnerability
reporting: open the **Security** tab of
[luohoa97/ramble-voice](https://github.com/luohoa97/ramble-voice) and choose
**Report a vulnerability**. Please do not open a public issue for security
problems.

Include the affected version, platform (Android or Linux, desktop and
compositor), steps to reproduce, and the impact you expect. You will get an
acknowledgement within a few days. This is a volunteer project, so fix times
vary with severity.

## Supported versions

Only the latest release receives security fixes while the project is pre-1.0.

## Scope

In scope:

- **Prompt injection.** Ramble Voice is text-only. Whatever you say is
  transcribed and cleaned up; it must never be executed, obeyed, or turned into
  an action (no shell commands, no tool calls, no opening apps, no changing
  settings). Any input, spoken or pasted, that makes the app do something other
  than output cleaned text is a vulnerability.
- **API key storage.** The Gemini key is stored in the platform secret store
  (libsecret on Linux, Android Keystore-backed storage on Android). Bugs that
  leak it to logs, files, the clipboard, crash reports, or the network (other
  than requests to the Gemini API) are in scope. Note that the optional
  `GEMINI_API_KEY` environment variable and `flatpak override --env` store the
  key in plain text by design; that is documented, not a vulnerability.
- **Model download integrity.** Bypassing the SHA-256 verification of model
  files, or downloading from an unexpected origin.
- **Privacy.** Any network traffic other than Gemini requests (cloud mode,
  opt-in) and model downloads, or any form of telemetry.
- **Text insertion and portals.** Inserting text into the wrong window, or
  abusing the RemoteDesktop portal session or the optional ydotool socket
  beyond typing dictated text.
- **Build and release pipeline.** Unpinned or tampered engine binaries,
  workflow injection, leaked signing secrets.

Out of scope:

- Content quality or accuracy of the model output.
- Problems in Google's Gemini service, Gemma weights, Flutter, or other
  upstream projects (report those upstream; tell us if we can mitigate).
- Attacks that need an already compromised device or desktop session.
- Free-tier data use by Google, which is disclosed in the app and README.
