# MeetingNotes

MeetingNotes is a macOS 14+ Apple-silicon menu-bar recorder that captures microphone and system audio, transcribes locally with WhisperKit, optionally creates a structured summary, and exports an Obsidian note.

## First launch

1. Open **Settings**, choose an Obsidian folder, and grant the requested security-scoped access.
2. Enter the default Whisper model (`openai_whisper-base`). Its initial preparation downloads the model; Start remains unavailable until folder access and privacy permissions are ready.
3. Grant **Microphone** and **Screen & System Audio Recording** access when macOS requests them. Their privacy indicators remain visible while recording.
4. Optionally choose Gemma and enter its API key (stored only in Keychain), or choose Ollama, set its endpoint, and install the selected Ollama model (for example, `ollama pull gemma3`).

Press Start, then Stop. Final transcription begins immediately; confirm the prefilled “Meeting” title to export. The provisional text is replaced by the final file transcription.

## Summary providers

- **No Summary** never makes a network request.
- **Gemma** calls the Gemini Developer API with structured JSON output, uses temperature zero, and retries bounded temporary/429 errors while respecting `Retry-After`.
- **Ollama** posts a non-streaming structured-output request to `<endpoint>/api/generate` at temperature zero.

## Recovery and files

Each recording has a manifest under `Application Support/MeetingNotes/Recordings/<UUID>`. Audio and manifest data are retained through transcription, summary, or export failures and can be retried after relaunch. Source and mixed files are removed only after a successful export and only when the settings permit it. If **Keep Original Audio** is enabled, the mixed WAV is copied before the Markdown note is written, so a completed note never points at missing media.

Folder access is a security-scoped bookmark. If it becomes stale, reselect the Obsidian folder in Settings. Notes use `YYYY-MM-DD HHmm - Title.md` in local time and collision-safe numbered suffixes.

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -resolvePackageDependencies -project MeetingNotes.xcodeproj -scheme MeetingNotes
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Debug build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Release build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes test
```

## v1 limitations

- Apple-silicon only; no speaker diarization.
- Provisional text may change after Stop.
- Protected or DRM audio may not be capturable.
- macOS privacy indicators remain visible.
- The first Whisper model download is required.
- Summary context and rate limits depend on the selected model and account.
