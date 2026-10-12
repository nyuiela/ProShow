# ProShow Virtual Camera (CMIO DAL)

The main app publishes BGRA program frames on `127.0.0.1:39217` using the `VirtualCameraFrameQueue` header (`PSVC` magic + width/height/PTS + payload).

## Build the extension

1. Create a **System Extension** target in Xcode using Apple’s CoreMediaIO DAL template (or duplicate OBS Virtual Camera structure).
2. Link the extension to read from `VirtualCameraFrameQueue.defaultPort` and expose a device named **ProShow Virtual Camera**.
3. Sign with the same Team ID as ProShow and embed via **System Extensions** capability.

When the extension connects, `VirtualCameraSink.extensionAvailable` becomes true and Zoom / Meet can select the camera.

## Virtual audio

Set `PROSHOW_VIRTUAL_AUDIO_DRIVER=1` in the environment once the CoreAudio driver is installed, or route **ProShow Virtual Audio** manually via BlackHole until the driver ships.
