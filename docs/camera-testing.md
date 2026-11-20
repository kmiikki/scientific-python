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

The CMD launcher also forwards these arguments. Use the Home or Safe mode that contains Science if both are installed. OpenCV's DirectShow enumeration supplies the index and any friendly name reported by the same backend. If it returns an empty list, is unavailable, or times out and its worker is stopped, discovery tries indexes 0 through 15 by default. `-ProbeLimit 2` restricts this fallback to indexes 0 and 1. It does not restrict a populated native list or an explicit `-CameraIndex`. Discovery shares one 30-second time budget, with at most half used for native enumeration. A fallback probe checks whether the device opens; it neither reads frames nor shows a preview. An absent index and one that rejects opening can look alike during fallback. Selecting that index directly reports `OPEN_FAILED`. [OpenCV DirectShow enumeration](https://github.com/opencv/opencv/blob/5.1.0/modules/videoio/src/cap_dshow.cpp#L3406)

Use `-Frames`, `-OpenTimeout`, `-CaptureTimeout` and `-PreviewSeconds` to adjust the checks. On Windows, Python/OpenCV/backend startup has a separate limit of up to 12 seconds. The default 4-second `-OpenTimeout` starts when the worker reaches the camera open or enumeration phase; the discovery budget can shorten either phase. The launcher uses Windows PowerShell 5.1 conventions and a process-local PATH.

On Windows, preview has a separate 12-second initialization limit (adjustable with `-PreviewInitTimeout`). This allows for a slow first HighGUI initialization without reducing the active `-PreviewSeconds` interval. The active interval starts after the window is created, the first valid frame is sent to HighGUI, and the first event-pump call returns. This is software readiness, not proof that a physical display painted the image. The worker has one second of grace beyond the active interval, two seconds for window shutdown and one second for camera release. Native calls still run in an isolated worker. [OpenCV HighGUI event processing](https://docs.opencv.org/4.13.0/d7/dfc/group__highgui.html#gad139b76c454510f190d72ac3bbd21bb2)

When preview is requested on Windows, the combined test passes only if capture, preview and cleanup succeed. A failed preview retains the validated resolution and frame count and reports `capture_status: "PASS"` in JSON. `preview_timing` contains elapsed seconds for completed GUI initialization steps and the active display interval (where available). `PREVIEW_INIT_TIMEOUT` includes the last initialization call reached; `PREVIEW_TIMEOUT` applies to active display, `PREVIEW_SHUTDOWN_TIMEOUT` to closing the window, and `SHUTDOWN_TIMEOUT` to camera release or worker shutdown. `PREVIEW_WORKER_EXITED` means no complete worker result arrived after capture. A cleanup exception is reported as `PREVIEW_CLEANUP_FAILED` or `CAMERA_CLEANUP_FAILED`.

## Results and troubleshooting

| Result | Meaning |
|---|---|
| `PASS` | The device returned the required valid frames and the capture was released. Preview has its own result. |
| `FAIL` | The device could not be accessed or did not pass initialization, frame validation or cleanup. Other devices can still pass. |
| `UNSUPPORTED` | The detected node lacks a supported conventional video-capture interface. |
| `SKIP` | No available camera was discovered, testing was cancelled or only the candidate list was requested. |

Commands exit **0** if capture passes, **1** if any attempted test fails, and **2** if no capture was performed or the command was cancelled before a capture passed. Argument errors also use exit 2. The preview is off by default when a device or all devices are selected on the command line. Structured JSON goes to standard output. It omits friendly device names, persistent IDs and user paths. The test saves no images or video.

- `PERMISSION_DENIED` or `DEVICE_BUSY` means the operating system reported the condition. Close any other camera app before retrying. Some drivers and DirectShow expose only a generic open or read failure.
- `STARTUP_TIMEOUT` means the Windows worker did not finish Python/OpenCV/backend initialization. `ENUMERATE_TIMEOUT`, `OPEN_TIMEOUT`, `CAPTURE_TIMEOUT`, `PREVIEW_TIMEOUT` and `SHUTDOWN_TIMEOUT` identify later stages. The result records whether the worker terminated. Forced termination does not verify a graceful release.
- `NO_VALID_FRAMES` means the device opened but no valid frames arrived. `STREAM_INTERRUPTED` means valid frames arrived but the required consecutive sequence never completed.
- `NO_CAMERA` means discovery found no usable candidates in its search range. Connect a device and refresh, or select a known node or index directly. A discovery budget hit is reported separately.
- `PREVIEW_UNAVAILABLE` can accompany a successful capture when there is no graphical desktop or HighGUI cannot initialize. Windows reports a failed combined test when preview was requested. A headless V4L2 capture can still pass. Check that an image actually appeared during graphical acceptance.

See the [current Ubuntu 24.04 LTS acceptance](testing.md#v092-ubuntu-2404-lts-acceptance) and [earlier physical camera records](testing.md#v091-camera-hardware-acceptance).
