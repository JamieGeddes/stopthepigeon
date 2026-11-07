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
| ⇧⌘G | Toggle green screen |

## Green screen

**Effects > Green Screen** replaces a green or blue background with a backdrop image of your choice.

1. Put a green (or blue) screen behind the set and light it evenly. Avoid that colour on your characters.
2. **Effects > Choose Backdrop…** and pick a JPEG, PNG or HEIC. It's copied into the project folder.
3. Adjust **Tolerance**, **Edge softness** and **Spill removal** in the sidebar while watching the live view.

The effect is non-destructive: captured frames are stored unaltered and the key is applied when frames are displayed and exported, so you can change the settings or backdrop at any time.

Projects are folders under `~/Movies/Stop the Pigeon/`. Each holds the captured JPEGs and a `project.json` with the frame order and frame rate.
