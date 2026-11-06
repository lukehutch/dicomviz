# dicomviz

A 3D DICOM viewer written in Dart and Flutter. It runs as a Linux desktop app
and in the browser. The volume is ray-cast in a fragment shader on the GPU.
Cone-beam projection series can also be reconstructed into a volume.

## Linux

    flutter build linux --release
    build/linux/x64/release/bundle/dicomviz [folder]

## Web

    tool/build_web.sh

This runs `flutter build web --wasm --no-web-resources-cdn`, then compiles the
reconstruction worker to JavaScript. Serve `build/web` with any static web
server. Multi-threaded rendering and reconstruction need these response
headers:

    Cross-Origin-Opener-Policy: same-origin
    Cross-Origin-Embedder-Policy: require-corp

The browser reads DICOM files from the chosen folder locally. Nothing is
uploaded. With `--no-web-resources-cdn`, the page loads no code from a CDN.

Rendering uses WebGL2 through Flutter's skwasm renderer. Limits on web:

- Reconstruction runs on 7 workers when the headers above are sent, and on
  one worker without them, which takes several times longer.
- Loading runs on one thread, so it takes longer than on desktop. It yields
  regularly to keep the page responsive.
- Folder selection uses `webkitdirectory`, which some mobile browsers lack.
- Volumes must fit in one texture, so the browser's maximum texture size
  limits their resolution.

## Other platforms

    flutter build macos
    flutter build windows
    flutter build apk
    flutter build ios

macOS and iOS must be built on a Mac with Xcode, and Windows on Windows with
Visual Studio. These three have not been built or run. Android builds on Linux,
but not with JDK 26; JDK 21 works.

Opening a folder does not work on iOS, because `file_selector` has no folder
picker there. On Android the app can read folders copied into its own storage,
`/sdcard/Android/data/com.lukehutch.dicomviz/files/`, for example with
`adb push`. The app must be installed and started once first, so that Android
creates that folder owned by the app. Picking a folder elsewhere has not been
tried and may need more storage permission than the app asks for. Android and
iOS devices may also have a smaller maximum texture size than the 16384 the
atlas assumes.

While the view moves, it is rendered at no more than 60,000 pixels and
500 ray steps across the volume, then at full quality 250 ms after it stops.
With fewer steps, thin bone and metal fall between samples and show as dark
bands.
The full-quality image is rendered offscreen in strips, so that no single GPU
job runs long, and is shown once all strips are done. A new change stops it.
On a Pixel 10 Pro XL a moving frame takes about 18 ms and a full-quality
full-screen frame 350 to 700 ms.
`--dart-define=DICOMVIZ_PERF=true` prints average frame times, as the
`DICOMVIZ_PERF` environment variable does on desktop.

The app has no built-in default folder. A demo build can set one, which is
opened when no folder is given on the command line and none was saved:

    flutter build apk --dart-define=DICOMVIZ_FOLDER=<path>

## Layout

Windows at least 1000 px wide show the controls in side panels. In narrower
windows the view fills the window, and the button in the top right corner
opens the controls in a floating panel. On touch screens, one finger rotates,
two fingers pan and pinching zooms.

## Tests

    flutter test

    dart compile exe tool/check_reconstruction.dart -o build/check_reconstruction
    build/check_reconstruction <folder>
