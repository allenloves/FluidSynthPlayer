# FluidSynth Player

A tiny macOS menu bar MIDI player built on [libfluidsynth](https://www.fluidsynth.org/).
Double-click a `.mid` file and it plays through FluidSynth with a GM SoundFont;
a menu bar icon shows the file name, elapsed/total time, a seek bar, and
play/pause and stop buttons. Playback end or Stop quits the app.

Elapsed/total time is computed from the file's own tempo map, so it stays
accurate across tempo changes.

## Requirements

- macOS 13+, Apple Silicon Homebrew (`/opt/homebrew`)
- `brew install fluid-synth duti`
- Xcode Command Line Tools (`swiftc`)
- A GM SoundFont at `~/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2`
  ([GeneralUser GS](https://github.com/mrbumpy409/GeneralUser-GS)); change
  `soundFontPath` in `main.swift` to use another

## Build & install

```sh
./build.sh            # builds build/FluidSynth Player.app
./build.sh install    # also installs to ~/Applications and sets it as the .mid handler
```

Revert the file association with e.g. `duti -s com.apple.logic10 public.midi-audio all`.

## License

MIT — see [LICENSE](LICENSE). FluidSynth is LGPL-2.1-or-later and is linked dynamically;
GeneralUser GS is not included and has its own license.
