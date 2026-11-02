import 'package:file_selector/file_selector.dart';

import 'platform_io.dart';

Future<PickedFolder?> pickFolder(String? initial) async {
  final dir = await getDirectoryPath(initialDirectory: initial);
  return dir == null ? null : listFolder(dir);
}
