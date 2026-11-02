// Separate from platform.dart because the desktop dialog needs Flutter, which
// the command-line tools cannot link.
export 'pick_folder_io.dart' if (dart.library.js_interop) 'platform_web.dart' show pickFolder;
