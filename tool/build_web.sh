#!/bin/sh
# Builds the web app into build/web. flutter build compiles only the app, so
# the reconstruction worker is compiled here, into the same folder.
set -e
flutter build web --wasm --no-web-resources-cdn "$@"
dart compile js -O4 --no-source-maps tool/reconstruct_worker.dart -o build/web/reconstruct_worker.js
