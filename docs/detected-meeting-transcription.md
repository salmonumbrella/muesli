# Auto-transcribe detected meetings

In Settings > Meetings > Recording, enable **Auto-transcribe detected meetings**
to start transcription without pressing Start Transcribing on a detection card.
The setting is saved and defaults to off. It works independently of detection
notifications and calendar auto-recording.

This uses Muesli's existing browser, camera, microphone and app audio detection.
It does not verify that another participant answered: transcription may start
while dialing or before anyone joins. Enable it only when that behavior is
appropriate, and make sure participants know you are transcribing. Existing
recording permissions and startup checks still apply.

Muted detection apps are excluded. Dismissing a detection card suppresses that
detection. Stopping transcription does not automatically restart it for the same
detected session; a later media session can start again. An open browser meeting
hint without a new media session stays suppressed until Muesli restarts, so a
parked tab cannot repeatedly start transcription. If automatic startup fails,
retry manually; Muesli does not repeatedly retry that detection.
