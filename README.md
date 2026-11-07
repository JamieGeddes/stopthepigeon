# Stop the Pigeon

A macOS stop-motion app that captures stills from an iPhone (via Continuity Camera) and exports them as an MP4.

## iPhone setup

1. iPhone and Mac signed in to the same Apple ID, with Wi-Fi and Bluetooth on.
2. On the iPhone: **Settings > General > AirPlay & Continuity > Continuity Camera** on.
3. Mount the iPhone on a tripod and plug it in.
4. On the Mac: **Control Centre > Video Effects**, turn off Portrait and Studio Light. The app turns off Centre Stage itself.

## Build and run

Open `StopThePigeon.xcodeproj` in Xcode and press **Run** (⌘R). No developer account is needed; the app is signed to run locally.

Run the tests with ⌘U, or:

```sh
xcodebuild test -project StopThePigeon.xcodeproj -scheme StopThePigeon -destination 'platform=macOS'
```

## Using it

| Key | Action |
|---|---|
| Space | Capture a frame |
| ← / → | Step through frames (→ past the last frame returns to live) |
| Esc | Back to the live camera |
| P | Play / stop |
| ⌥← / ⌥→ | Move the selected frame |
| ⌘⌫ | Delete the selected frame (moved to the project's "Deleted Frames" folder) |
| ⌘E | Export movie |

Projects are folders under `~/Movies/Stop the Pigeon/`. Each holds the captured JPEGs and a `project.json` with the frame order and frame rate.
