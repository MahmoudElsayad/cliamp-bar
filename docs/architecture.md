# Architecture

CliampBar presents the state of an installed Cliamp player.
Cliamp owns audio, queue contents, providers, credentials, and playback preferences.

## Usage

The app delegate creates a `PlayerStore`, a `PlayerPanel`, and `SystemMediaControls`, then calls `connect()`.
It composes the panel and system media updates in one store callback.
The panel sends typed `PlayerCommand` values to `perform(_:)`.
The store calls `onChange` on the main thread when state changes.
The panel reads the store and updates its existing controls.

```swift
store.connect()
store.perform(.seek(42))
store.perform(.playQueue(index: 0, revision: snapshot.playlist_revision))
```

## Shape

`PlayerSnapshot`, `Track`, and the library types describe the external data that the panel needs.
`PlayerConnection` separates startup, availability, and connection failure.
`PlayerCommand` maps supported user actions to Cliamp operations and their parameters.
Queue playback includes the displayed playlist revision so that Cliamp can reject a stale selection.

`CliampClient` owns executable calls, response decoding, and background startup.
`CommandRunner` passes arguments directly to `Process`, drains both pipes independently, and bounds each command with a deadline.
The runner retains at most two MiB from each output pipe.
Cliamp handles asynchronous jobs through `remote call --wait`.

`PlayerStore` serializes playback changes on one worker queue and reads library and player state on a separate concurrent queue.
Slow network sources therefore do not block playback controls.
The store dispatches presentation changes to the main thread.
System media commands enter the same serial worker with at most 16 outstanding operations.
Each accepted command gets one attempt, and admission fails when the connection is unavailable or the worker queue is full.
Play and pause dispatch separate idempotent operations, which remain safe when repeated.
Only the toggle handler dispatches toggle.
It attaches to a running player first.
It starts a daemon only after an explicit missing-player error, and retains its process handle to avoid duplicate startup attempts.
It never terminates a player when the GUI quits.
It does not restore a cached queue over an existing session.

`PlayerPanel` owns the menu bar item, the borderless panel, file dialogs, URL entry, and the login registration.
`PlayerCard` owns control layout and library rows.
The panel uses the same AppKit approach and exact palette as VoxtypeOSD.
The app discovers supported operations before it enables controls.

`PlayerPanel` also owns one display-only `SpectrumSession` and sends frames directly to `SpectrumView`.
The session runs `cliamp visstream --fps 20` with the connected client's executable and existing child environment.
It runs only while the panel is visible, connected, and playing, with Reduce Motion disabled.
Ten segmented cream bars use `Theme.text` on `Theme.surface` and leave orange for controls.
Frames never trigger a store update or redraw the queue.

`SpectrumFrame` decodes ten finite bands and clamps them to zero through one.
`SpectrumParser` accepts split newline-delimited JSON and limits each line to 64 KiB.
It discards an oversized line through its newline and ignores malformed frames.
The session owns nonblocking pipe reads and cancellation on the main queue to prevent close/read races.
Generations reject callbacks from older sessions, and restart waits for the previous child to exit.
Frames expire after one second, with at most three retries per eligible session.
Hiding, pausing, disconnecting, reconnecting, and Reduce Motion clear the bars and stop the stream.
App termination also kills the stream, including SIGTERM from the installer.
The Cliamp playback daemon remains independent.

`PlayerStore` owns one `RuntimeStateSession` while connected, independent of panel visibility.
The session runs `cliamp remote events runtime.state` and decodes newline-delimited event envelopes.
Absent `retained` fields mean false, as in ordinary Cliamp live events.
The parser limits each line to 64 KiB and discards malformed or oversized envelopes.
Nonblocking main-thread reads and generation numbers prevent stale callbacks and overlapping children.
A quiet paused stream remains open without a timeout.
Unexpected exit retries indefinitely with exponential delays from one to eight seconds.
Shutdown cancels retries and reaps the event child without stopping the playback daemon.

A retained position can be older than a fresh state read at the same snapshot revision.
The store ignores retained snapshot data and requests one fresh state read before enabling system media controls.
Live events and command replies advance snapshot revisions, while equal-revision command replies cannot rewind position.
Read generations reject replies that predate a newer observation or command.
Stream loss clears the snapshot and displayed queue because a replacement daemon can reuse revision numbers.
Queue and library replies also carry the stream epoch so that older replies cannot populate a replacement connection.
Hidden events update player state without fetching queue pages or library data.

`SystemMediaControls` owns public MediaPlayer registration on the app main thread.
It uses the shared command center and default Now Playing center.
It retains each registration token and removes that exact token during shutdown.
The bridge publishes title, artist, album, duration, elapsed time, actual playback speed, live status, and native playback state.
macOS advances elapsed time between updates using the published playback rate.
Paused tracks retain metadata and resume controls.
Stopped playback, missing tracks, and disconnects clear metadata and disable commands.
Identical metadata does not republish, and position updates do not reset native playback state.
The app does not intercept global keyboard events or request extra permissions.

## Design decision

Two sketches compared a direct Unix socket client with a command interface through `Process`.
An independent review selected the command interface because Cliamp already handles protocol framing and job completion.
The final design combines that interface with the pure AppKit panel from the socket proposal.
AppKit gives the app explicit control over the theme, panel borders, focus, and shadow.

A direct socket client avoids child process startup but makes the app own protocol connections, job correlation, event recovery, and frame limits.
A SwiftUI popover reduces layout code but adds native chrome that differs from the existing VoxtypeOSD panel.
The app accepts one state command per second while visible to keep the transport small and compatible.
It does not poll while hidden or maintain a second playback engine.

## Failure rules

Connection failure disables playback controls and exposes Reconnect.
An operation error stays visible in the panel until another action clears it.
A timed-out operation has an unknown outcome because Cliamp can continue the submitted job.
The store refreshes state after operations and does not retry mutations automatically.
Library and queue responses remain bounded through pages of 100 rows.

## Implementation reconciliation

A lost runtime stream reconnects automatically without starting a playback daemon.
Explicit Reconnect repeats executable discovery and can start a missing daemon.
Only visible panels poll position because position-only playback changes do not produce Cliamp events.
It reloads queue rows only when the playlist revision changes.
The installer records a custom executable path in the app environment so that Finder launches use the same Cliamp installation.
