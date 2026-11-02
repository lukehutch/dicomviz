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

## Layout

Windows at least 1000 px wide show the controls in side panels. In narrower
windows the view fills the window, and the button in the top right corner
opens the controls in a floating panel. On touch screens, one finger rotates,
two fingers pan and pinching zooms.

## Tests

    flutter test

    dart compile exe tool/check_reconstruction.dart -o build/check_reconstruction
    build/check_reconstruction <folder>
