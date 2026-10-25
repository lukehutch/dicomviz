// Compares the Dart decoder with reference decodes made by pydicom +
// pylibjpeg. Set DICOMVIZ_DATA (DICOM folder) and DICOMVIZ_REF (folder with
// ref*.bin files: raw little-endian 16-bit pixel values) to run it.
import 'dart:io';
import 'dart:typed_data';

import 'package:dicomviz/dicom/dicom_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final data = Platform.environment['DICOMVIZ_DATA'];
  final ref = Platform.environment['DICOMVIZ_REF'];
  final skip = data == null || ref == null ? 'DICOMVIZ_DATA/REF not set' : null;

  void check(String file, String refName, int frame, bool signed) {
    final bytes = File('$data/$file').readAsBytesSync();
    final f = DicomFile.parse(file, bytes);
    final px = f.decodeFrame(frame);
    final rb = File('$ref/$refName').readAsBytesSync();
    final bd = ByteData.sublistView(rb);
    expect(px.length * 2, rb.length);
    var mismatches = 0;
    for (var i = 0; i < px.length; i++) {
      final want = signed
          ? bd.getInt16(i * 2, Endian.little)
          : bd.getUint16(i * 2, Endian.little);
      if (px[i] != want) mismatches++;
    }
    expect(mismatches, 0);
  }

  const ct = '2.16.840.114421.1.1.3.492766376.3432.1792510746.239';
  test('CT slice 0 matches reference', () => check('$ct/0000.dcm', 'ref0000.bin', 0, true), skip: skip);
  test('CT slice 220 matches reference', () => check('$ct/0220.dcm', 'ref0220.bin', 0, true), skip: skip);
  test('RAW multi-frame frame 5 matches reference', () {
    final name = Directory(data!).listSync().map((e) => e.path.split('/').last).firstWhere((n) => n.startsWith('RAW_'));
    check(name, 'refraw5.bin', 5, false);
  }, skip: skip);
}
