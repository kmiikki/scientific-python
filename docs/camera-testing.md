# USB Camera Test

USB cameras are optional. Scientific Python can be installed and used without any camera hardware. Installation, updates, removal and ordinary validation keep their regular checks, including synthetic OpenCV video and FFmpeg processing.

In either installer menu, choose **U — USB Camera Test (optional)**. The test runs with the selected Science environment's Python and OpenCV. Integrated webcams and USB video cameras use the same workflow. Select a numbered item, **A** to test all devices, **R** to refresh after reconnecting hardware or **Q** to quit. Each tested device gets its own result. Testing all devices runs the checks one at a time.

The test requires three consecutive valid frames by default and reports the measured frame size. A dark or stationary image can pass. With a graphical desktop, the menu displays the camera's live output after capture validation. Press **Esc** or **Q** in the preview window to close it. A headless capture can pass with preview unavailable. Check the preview result separately during graphical acceptance. Use **Ctrl+C** to interrupt the test, including when a device stops responding.

## Ubuntu 24.04 and 26.04

The V4L2 backend lists `/dev/videoN` nodes and checks the capabilities of each node. A camera can have several nodes, including a metadata-only node reported as `UNSUPPORTED`. The numbers are allocated by Linux and may change on reconnect. A corresponding `/dev/v4l/by-id/` link can select the same node by a persistent path when the system supplies it. Local lists show the driver-reported name if available.

From the extracted project directory:

```bash
bash linux/07-test-usb-camera.sh --list
bash linux/07-test-usb-camera.sh --device /dev/video2 --preview
bash linux/07-test-usb-camera.sh --all --no-preview --json
```

Use `--root /path/to/micromamba` to select a detected Science installation when several exist. See `--help` for capture, preview and device-open timing options and the number of required frames.

## Windows 11

Run `windows/07-TEST-USB-CAMERA.cmd` for the interactive test, or run the PowerShell script from the extracted project directory:

```powershell
.\windows\07-usb-camera-test.ps1 -ListDevices
.\windows\07-usb-camera-test.ps1 -Mode Home -CameraIndex 2 -Preview
.\windows\07-usb-camera-test.ps1 -Mode Safe -All -NoPreview -Json
```

The CMD launcher also forwards these arguments. Use the Home or Safe mode that contains Science if both are installed. OpenCV's DirectShow enumeration supplies the index and any friendly name reported by the same backend. When that API is unavailable, discovery probes indexes 0 through 15 by default within a 30-second budget and displays confirmed indexes without names. Use `-ProbeLimit` to change the fallback range, or `-CameraIndex` to test an explicit index from 0 to 99. During fallback probing, an index that rejects opening and an absent index can look alike. A directly selected index that fails to open is reported as `FAIL`. [OpenCV DirectShow enumeration](https://github.com/opencv/opencv/blob/5.1.0/modules/videoio/src/cap_dshow.cpp#L3406)

Use `-Frames`, `-OpenTimeout`, `-CaptureTimeout` and `-PreviewSeconds` to adjust the checks. The launcher uses Windows PowerShell 5.1 conventions and a process-local PATH.

## Results and troubleshooting

| Result | Meaning |
|---|---|
| `PASS` | The device returned the required valid frames and the capture was released. Preview has its own result. |
| `FAIL` | The device could not be accessed or did not pass initialization, frame validation or cleanup. Other devices can still pass. |
| `UNSUPPORTED` | The detected node lacks a supported conventional video-capture interface. |
| `SKIP` | No available camera was discovered, testing was cancelled or only the candidate list was requested. |

Commands exit **0** if capture passes, **1** if any attempted test fails, and **2** if no capture was performed or the command was cancelled before a capture passed. Argument errors also use exit 2. The preview is off by default when a device or all devices are selected on the command line. Structured JSON goes to standard output. It omits friendly device names, persistent IDs and user paths. The test saves no images or video.

- `PERMISSION_DENIED` or `DEVICE_BUSY` means the operating system reported the condition. Close any other camera app before retrying. Some drivers and DirectShow expose only a generic open or read failure.
- `OPEN_TIMEOUT`, `CAPTURE_TIMEOUT`, `PREVIEW_TIMEOUT` and `SHUTDOWN_TIMEOUT` identify the blocked stage. The result records whether the worker terminated. Forced termination does not verify a graceful release.
- `NO_VALID_FRAMES` means the device opened but no valid frames arrived. `STREAM_INTERRUPTED` means valid frames arrived but the required consecutive sequence never completed.
- `NO_CAMERA` means discovery found no usable candidates in its search range. Connect a device and refresh, or select a known node or index directly. A discovery budget hit is reported separately.
- `PREVIEW_UNAVAILABLE` can accompany a successful capture when there is no graphical desktop or HighGUI cannot initialize. Use the reported preview status to verify the graphical part.

See [physical acceptance status](testing.md#v091-camera-hardware-acceptance) for the machines and test cases still pending.
