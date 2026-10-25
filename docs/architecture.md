# Architecture

CliampBar presents the state of an installed Cliamp player.
Cliamp owns audio, queue contents, providers, credentials, and playback preferences.

## Usage

The app delegate creates a `PlayerStore`, attaches a `PlayerPanel`, and calls `connect()`.
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
It attaches to a running player first.
It starts a daemon only after an explicit missing-player error, and retains its process handle to avoid duplicate startup attempts.
It never terminates a player when the GUI quits.
It does not restore a cached queue over an existing session.

`PlayerPanel` owns the menu bar item, the borderless panel, file dialogs, URL entry, and the login registration.
`PlayerCard` owns control layout and library rows.
The panel uses the same AppKit approach and exact palette as VoxtypeOSD.
The app discovers supported operations before it enables controls.

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

The implementation uses explicit Reconnect after a lost connection, rather than automatic background retries.
This keeps a disconnected GUI from repeatedly starting or probing the player.
The panel polls state because position-only playback changes do not produce Cliamp events.
It reloads queue rows only when the playlist revision changes.
The installer records a custom executable path in the app environment so that Finder launches use the same Cliamp installation.
