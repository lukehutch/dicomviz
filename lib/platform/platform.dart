// What differs between the desktop and web builds: file access, background
// work and memory shared between workers.
export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
