# Mac usage telemetry

The direct-download Mac app can send a small, fixed set of events to
[Aptabase](https://aptabase.com/) when a managed US or EU app key is included in
the build. The user controls this in Settings. It is on by default, and
turning it off cancels pending requests. There is no persistent user or device
identifier; a random session ID changes on each launch or after one hour of
inactivity. The app uses an ephemeral network session and does not queue
events on disk.

## Events

| Event | Properties |
| --- | --- |
| `app_opened` | None |
| `previous_run_interrupted` | None; may be a crash, forced quit, or power loss |
| `feature_opened` | Fixed feature name: Meeting Notes, Transcripts/History, Settings, Feedback |
| `dictation_started` | None |
| `dictation_completed` | Recording duration range |
| `dictation_failed` | Fixed reason category |
| `ai_summary_started`, `ai_summary_completed`, `ai_summary_failed` | AI provider used for meeting notes or transcript tools; failures also have a fixed reason category. Event names remain stable for dashboard continuity. |
| `archive_title_failed` | Provider |
| `feedback_draft_opened` | None |

Every event has the app version and build, macOS major and minor version, a
generic `Mac` device label, and the short-lived session ID. The event API does
not accept arbitrary transcript, prompt, feedback, error, app-name, or audio
fields. Recording duration is bucketed. The app never sends raw error messages.

The dashboard can show launches, anonymous sessions, feature counts, dictation
completion and failure rates, possible interrupted runs, and failures by app
or macOS version. It cannot show unique users, monthly active users, retention
by person, or crash stack traces. A separate crash reporter would be needed
for stack traces.

## Build configuration

Create a Mac app in Aptabase and obtain its `A-US-...` or `A-EU-...` app key.
Set `APTABASE_APP_KEY` in the local `.env` used by `scripts/release.sh`, or pass
it as an Xcode build setting. The app key is a public client identifier embedded
in the app, not a secret. Builds without a valid key show telemetry as
unavailable and send no events. Verify the key is bundled before any paid
binary is uploaded.

The managed service endpoint and event format follow Aptabase's
[SDK documentation](https://github.com/aptabase/aptabase-swift) and
[client API guide](https://github.com/aptabase/aptabase/wiki/How-to-build-your-own-SDK).
The app uses a small local client so that turning telemetry off can cancel
pending requests immediately. No third-party analytics SDK is linked.
