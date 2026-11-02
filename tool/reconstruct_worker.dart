// Web Worker for cone-beam reconstruction, compiled to JavaScript by
// tool/build_web.sh. See runWorkerTask in lib/platform/platform_web.dart.

import 'package:dicomviz/dicom/cbct.dart';
import 'package:dicomviz/platform/platform_web.dart';

void main() => serveWorker(reconstructionRequest);
