#!/bin/zsh
# Build FluidSynth Player.app and install it to ~/Applications as the .mid handler.
set -e
cd "${0:A:h}"
FS=/opt/homebrew/opt/fluid-synth
APP="build/FluidSynth Player.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -I CFluidSynth -I $FS/include -L $FS/lib -lfluidsynth \
  -framework AppKit main.swift -o "$APP/Contents/MacOS/FluidSynthPlayer"
cp Info.plist "$APP/Contents/"
codesign --force --deep -s - "$APP"
if [[ "$1" == "install" ]]; then
  pkill -x FluidSynthPlayer || true
  rm -rf ~/Applications/"FluidSynth Player.app"
  cp -R "$APP" ~/Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"FluidSynth Player.app"
  duti -s com.allen.fluidsynth-player public.midi-audio all
  echo "installed"
fi
