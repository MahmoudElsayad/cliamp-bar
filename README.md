# CliampBar

A native macOS menu bar companion for [Cliamp](https://github.com/bjarneo/cliamp).
Cliamp plays the music, and CliampBar gives you a panel at the top of your screen.
No terminal window is required.

The default theme matches [VoxtypeOSD](https://github.com/MahmoudElsayad/voxtype-osd): Warm Charcoal surfaces, cream text, and orange controls.
The app uses system fonts and works without a browser or a web server.

## Install

CliampBar requires macOS 13 or later.
The app supports Apple Silicon and Intel Macs.
The installer uses an existing Cliamp installation, or installs Cliamp through [Homebrew](https://brew.sh) when it is missing.
Cliamp 2.3.0 or later is required.

### Install a release

Download `CliampBar-macOS.zip` from [Releases](https://github.com/MahmoudElsayad/cliamp-bar/releases/latest).
Extract the archive.
In Terminal, open the extracted `CliampBar` folder and run:

```sh
./install.sh
```

The installer copies the app to `~/Applications/CliampBar.app` and opens it.
Click the speaker icon in the menu bar.

The public build uses an ad-hoc signature and is not notarized by Apple.
macOS can block a downloaded build.
If macOS blocks it, open System Settings > Privacy & Security and use Open Anyway for CliampBar.
You can also build from source.

### Build from source

Install Xcode Command Line Tools with `xcode-select --install` if they are missing.
Install Homebrew if Cliamp is missing.
Then run:

```sh
git clone https://github.com/MahmoudElsayad/cliamp-bar.git
cd cliamp-bar
./install.sh
```

If you use a custom Cliamp location, set `CLIAMP_BINARY` when you install:

```sh
CLIAMP_BINARY=/absolute/path/to/cliamp ./install.sh
```

The installer records that path in the installed app.
The app also searches the standard Homebrew paths and `~/.local/bin`.
It adds these folders to the child process search path so that Cliamp can find helpers such as `yt-dlp` and `ffmpeg`.

## Use the player

The panel includes these controls:

- Play, pause, previous track, and next track.
- Playback position for tracks that support seeking.
- Volume from -30 to +6 dB, shuffle, and repeat.
- A scrollable queue with a control to play each track.
- A library with playlists from Cliamp radio, local files, and configured providers.
- Files and URL buttons to add music.

Mac media keys control playback while CliampBar is running, even when its panel is closed.
Quitting CliampBar removes its media key controls while Cliamp keeps playing.
The app uses macOS media controls without global keyboard access or extra permissions.

Ten cream spectrum bars show the current audio while the panel is open and Cliamp is playing.
Solid bar heights follow Cliamp's display levels from zero to one and round down to physical pixels.
The bars stop when playback pauses or macOS Reduce Motion is enabled.
LIVE pulses slowly in orange for a known live broadcast while the panel is open and playback runs.
Reduce Motion keeps LIVE static.
Unknown audio duration appears as `--:--`.

The Files button appends selected audio files to the current queue.
Click a queue row to play it.
The URL button loads a supported music link and starts playback.
Some services require helpers or account setup through `cliamp setup`.
The Library tab lists playlists from the selected source.
Click a playlist to load it in Cliamp.

Click outside the panel or press Escape to close it.
Right-click the menu bar icon, or click the gear, to open Settings.
Use Launch at Login to start CliampBar when you sign in.
If macOS requests approval, enable it in System Settings > General > Login Items.

CliampBar connects to an existing Cliamp player before it starts a background player with `cliamp --daemon`.
Quitting CliampBar leaves playback running.
Cliamp retains its playlists, account information, and playback preferences in its own configuration folder.
CliampBar does not copy account credentials or replace that configuration.

## Recover a connection

If the panel loses its connection, click the circular arrow to reconnect.
The app starts a background player only when Cliamp reports that no player is running.
If startup fails, read `~/Library/Logs/CliampBar/daemon.log`.
Cliamp also writes its own diagnostics under its configuration folder.

If an operation fails, the panel shows its diagnostic above the queue.
Hover over a shortened diagnostic to read the full text.
After a command times out, reconnect before retrying a queue change because Cliamp can still finish the original request.

## Development

Run `./build.sh` to create `build/CliampBar.app` for both Mac architectures.
Set `SIGN_IDENTITY` to sign with your own certificate.
The default signature is ad-hoc.

Run the tests:

```sh
./tests/run.sh
CLIAMPBAR_INTEGRATION=1 ./tests/run.sh
```

AppKit tests cover queue hover, the native LIVE animation, and MediaPlayer command handlers through a fake system interface.
These tests do not send system media keys or publish a test player to Now Playing.

The integration test needs Cliamp and an available audio output device.
It uses a temporary configuration folder and a silent WAV file.
It exercises actual playback, pause, seek, volume, playback modes, stale queue rejection, provider discovery, and real spectrum frames.
It also tests hidden playback updates and recovery after the disposable daemon restarts.
It does not change your Cliamp configuration.

The app sends argument arrays to the installed Cliamp executable.
It uses `remote state`, `remote capabilities`, `remote call --wait`, and one persistent `remote events runtime.state` stream.
The stream keeps system media controls and Now Playing metadata current while the panel is closed.
A fresh state read establishes the playback position when the stream connects or reconnects.
macOS advances elapsed time using the published playback rate between state changes.
Playback position refreshes once per second while the panel is open.
Polling stops when the panel closes.
A separate `cliamp visstream --fps 20` process updates only the spectrum bars.
The app stops this display process when the panel closes or the app exits.
Unit tests cover both streams, input limits, quiet playback, retries, command ordering, stale responses, and process cleanup with fake executables.
Read [the architecture](docs/architecture.md) for the ownership and failure rules.

## Uninstall

Turn off Launch at Login in CliampBar Settings.
Run `./uninstall.sh` from the source checkout to move the app to Trash.
Cliamp and its configuration remain installed.

## License

[MIT](LICENSE).
Cliamp is a separate project with its own license.
