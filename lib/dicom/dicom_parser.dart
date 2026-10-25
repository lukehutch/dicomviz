import 'dart:convert';
import 'dart:typed_data';

import 'jpeg_lossless.dart';

/// Tags used by the viewer, as (group << 16) | element.
abstract final class Tag {
  static const transferSyntaxUid = 0x00020010;
  static const sopClassUid = 0x00080016;
  static const modality = 0x00080060;
  static const seriesDescription = 0x0008103E;
  static const studyDescription = 0x00081030;
  static const patientName = 0x00100010;
  static const sliceThickness = 0x00180050;
  static const studyInstanceUid = 0x0020000D;
  static const seriesInstanceUid = 0x0020000E;
  static const seriesNumber = 0x00200011;
  static const instanceNumber = 0x00200013;
  static const imagePositionPatient = 0x00200032;
  static const imageOrientationPatient = 0x00200037;
  static const samplesPerPixel = 0x00280002;
  static const photometricInterpretation = 0x00280004;
  static const numberOfFrames = 0x00280008;
  static const rows = 0x00280010;
  static const columns = 0x00280011;
  static const pixelSpacing = 0x00280030;
  static const bitsAllocated = 0x00280100;
  static const bitsStored = 0x00280101;
  static const pixelRepresentation = 0x00280103;
  static const windowCenter = 0x00281050;
  static const windowWidth = 0x00281051;
  static const rescaleIntercept = 0x00281052;
  static const rescaleSlope = 0x00281053;
  static const pixelData = 0x7FE00010;
}

const _tsImplicitLE = '1.2.840.10008.1.2';
const _tsExplicitLE = '1.2.840.10008.1.2.1';
const _tsExplicitBE = '1.2.840.10008.1.2.2';
const _tsDeflate = '1.2.840.10008.1.2.1.99';
const _tsJpegLossless = {'1.2.840.10008.1.2.4.57', '1.2.840.10008.1.2.4.70'};

/// VRs whose explicit-VR header has 2 reserved bytes and a 32-bit length.
const _longVrs = {
  'OB', 'OD', 'OF', 'OL', 'OV', 'OW', 'SQ', 'SV', 'UC', 'UN', 'UR', 'UT', 'UV'
};

/// VRs that hold binary numbers rather than text.
const _binaryVrs = {
  'OB', 'OD', 'OF', 'OL', 'OV', 'OW', 'SQ', 'SV', 'UN', 'UV',
  'US', 'SS', 'UL', 'SL', 'FL', 'FD', 'AT'
};

/// VRs for implicit-VR data (only for the tags we read as numbers).
const _implicitVr = {
  Tag.samplesPerPixel: 'US',
  Tag.numberOfFrames: 'IS',
  Tag.rows: 'US',
  Tag.columns: 'US',
  Tag.bitsAllocated: 'US',
  Tag.bitsStored: 'US',
  Tag.pixelRepresentation: 'US',
};

class DicomElement {
  DicomElement(this.vr, this.bytes);
  final String vr;
  final Uint8List bytes;
}

/// A parsed DICOM file: top-level elements (sequences are skipped) and
/// pixel data, kept as one buffer (native) or a list of frames (encapsulated).
class DicomFile {
  DicomFile._(this.path, this.transferSyntax, this.elements);

  final String path;
  final String transferSyntax;
  final Map<int, DicomElement> elements;
  Uint8List? nativePixels;
  List<Uint8List>? encapsulatedFrames;

  bool get hasPixels => nativePixels != null || encapsulatedFrames != null;

  String? string(int tag) {
    final e = elements[tag];
    if (e == null) return null;
    var s = latin1.decode(e.bytes);
    // Strip padding (space or NUL).
    s = s.replaceAll(RegExp(r'[\x00 ]+$'), '').trim();
    return s;
  }

  List<double>? doubles(int tag) {
    final s = string(tag);
    if (s == null || s.isEmpty) return null;
    final parts = s.split('\\').map((p) => double.tryParse(p.trim()));
    if (parts.any((p) => p == null)) return null;
    return parts.cast<double>().toList();
  }

  double? number(int tag) {
    final e = elements[tag];
    if (e == null) return null;
    final bd = ByteData.sublistView(e.bytes);
    switch (e.vr) {
      case 'US':
        return e.bytes.length >= 2 ? bd.getUint16(0, Endian.little).toDouble() : null;
      case 'SS':
        return e.bytes.length >= 2 ? bd.getInt16(0, Endian.little).toDouble() : null;
      case 'UL':
        return e.bytes.length >= 4 ? bd.getUint32(0, Endian.little).toDouble() : null;
      case 'SL':
        return e.bytes.length >= 4 ? bd.getInt32(0, Endian.little).toDouble() : null;
      case 'FL':
        return e.bytes.length >= 4 ? bd.getFloat32(0, Endian.little) : null;
      case 'FD':
        return e.bytes.length >= 8 ? bd.getFloat64(0, Endian.little) : null;
      default:
        return doubles(tag)?.first;
    }
  }

  int intOr(int tag, int fallback) => number(tag)?.round() ?? fallback;

  int get rows => intOr(Tag.rows, 0);
  int get columns => intOr(Tag.columns, 0);
  int get numberOfFrames => intOr(Tag.numberOfFrames, 1);
  int get samplesPerPixel => intOr(Tag.samplesPerPixel, 1);
  int get bitsAllocated => intOr(Tag.bitsAllocated, 16);
  bool get signed => intOr(Tag.pixelRepresentation, 0) == 1;
  double get rescaleSlope => number(Tag.rescaleSlope) ?? 1.0;
  double get rescaleIntercept => number(Tag.rescaleIntercept) ?? 0.0;

  /// Decodes frame [index] to rescaled values (modality units, e.g. HU).
  /// Only single-sample (grayscale) images are supported.
  Float32List decodeFrame(int index) {
    final n = rows * columns;
    if (samplesPerPixel != 1) {
      throw UnsupportedError('Only grayscale images are supported');
    }
    final out = Float32List(n);
    final slope = rescaleSlope;
    final intercept = rescaleIntercept;
    final bits = bitsAllocated;
    final isSigned = signed;
    if (encapsulatedFrames != null) {
      if (!_tsJpegLossless.contains(transferSyntax)) {
        throw UnsupportedError('Unsupported transfer syntax $transferSyntax');
      }
      final raw = JpegLosslessDecoder(encapsulatedFrames![index]).decode();
      final stored = intOr(Tag.bitsStored, 16);
      final signBit = 1 << (stored - 1);
      final full = 1 << stored;
      for (var i = 0; i < n; i++) {
        var v = raw[i];
        if (isSigned && (v & signBit) != 0) v -= full;
        out[i] = v * slope + intercept;
      }
      return out;
    }
    final px = nativePixels;
    if (px == null) throw StateError('No pixel data');
    final bd = ByteData.sublistView(px);
    if (bits == 16) {
      final off = index * n * 2;
      for (var i = 0; i < n; i++) {
        final v = isSigned
            ? bd.getInt16(off + i * 2, Endian.little)
            : bd.getUint16(off + i * 2, Endian.little);
        out[i] = v * slope + intercept;
      }
    } else if (bits == 8) {
      final off = index * n;
      for (var i = 0; i < n; i++) {
        final v = isSigned ? bd.getInt8(off + i) : px[off + i];
        out[i] = v * slope + intercept;
      }
    } else if (bits == 32) {
      final off = index * n * 4;
      for (var i = 0; i < n; i++) {
        final v = isSigned
            ? bd.getInt32(off + i * 4, Endian.little)
            : bd.getUint32(off + i * 4, Endian.little);
        out[i] = v * slope + intercept;
      }
    } else {
      throw UnsupportedError('Unsupported BitsAllocated $bits');
    }
    return out;
  }

  /// Parses a DICOM Part 10 file. With [readPixels] false, parsing stops at
  /// the pixel data element.
  static DicomFile parse(String path, Uint8List data, {bool readPixels = true}) {
    if (data.length < 132 ||
        latin1.decode(data.sublist(128, 132)) != 'DICM') {
      throw FormatException('Not a DICOM Part 10 file: $path');
    }
    final r = _Reader(data, 132);
    final elements = <int, DicomElement>{};
    // File meta group is always explicit VR little endian.
    while (r.pos < data.length && r.peekGroup() == 0x0002) {
      final e = r.readElement(explicit: true);
      if (e == null) break;
      elements[e.$1] = e.$2;
    }
    final ts = elements[Tag.transferSyntaxUid] == null
        ? _tsExplicitLE
        : latin1
            .decode(elements[Tag.transferSyntaxUid]!.bytes)
            .replaceAll(RegExp(r'[\x00 ]+$'), '');
    if (ts == _tsExplicitBE || ts == _tsDeflate) {
      throw UnsupportedError('Unsupported transfer syntax $ts');
    }
    final explicit = ts != _tsImplicitLE;
    final f = DicomFile._(path, ts, elements);
    while (r.pos + 8 <= data.length) {
      final tag = r.peekTag();
      if (tag == Tag.pixelData) {
        if (!readPixels) break;
        r.readPixelData(f, explicit: explicit);
        break;
      }
      final e = r.readElement(explicit: explicit);
      if (e == null) break;
      elements[e.$1] = e.$2;
    }
    return f;
  }
}

class _Reader {
  _Reader(this.d, this.pos) : bd = ByteData.sublistView(d);
  final Uint8List d;
  final ByteData bd;
  int pos;

  int u16(int p) => bd.getUint16(p, Endian.little);
  int u32(int p) => bd.getUint32(p, Endian.little);

  int peekGroup() => u16(pos);
  int peekTag() => (u16(pos) << 16) | u16(pos + 2);

  /// Reads one element header. Returns (tag, vr, length, valueOffset).
  (int, String, int, int) _header({required bool explicit}) {
    final tag = (u16(pos) << 16) | u16(pos + 2);
    final group = tag >> 16;
    // Item and delimiter tags never carry a VR.
    if (group == 0xFFFE) {
      final len = u32(pos + 4);
      return (tag, '', len, pos + 8);
    }
    if (explicit) {
      final vr = String.fromCharCodes(d, pos + 4, pos + 6);
      if (_longVrs.contains(vr)) {
        return (tag, vr, u32(pos + 8), pos + 12);
      }
      return (tag, vr, u16(pos + 6), pos + 8);
    }
    final len = u32(pos + 4);
    return (tag, _implicitVr[tag] ?? (len == 0xFFFFFFFF ? 'SQ' : 'UN'), len, pos + 8);
  }

  (int, DicomElement)? readElement({required bool explicit}) {
    if (pos + 8 > d.length) return null;
    final (tag, vr, len, valueOff) = _header(explicit: explicit);
    if (len == 0xFFFFFFFF) {
      // Undefined length: a sequence (or UN sequence). Skip it.
      pos = valueOff;
      _skipUndefined(explicit: explicit);
      return (tag, DicomElement(vr, Uint8List(0)));
    }
    final end = valueOff + len;
    if (end > d.length) {
      pos = d.length;
      return null;
    }
    final bytes = Uint8List.sublistView(d, valueOff, end);
    pos = end;
    // Only keep values a viewer reads, including private (odd group)
    // vendor data; sequences with defined length are skipped as a whole.
    if (vr == 'SQ') return (tag, DicomElement(vr, Uint8List(0)));
    if (!_binaryVrs.contains(vr) || bytes.length <= 64 || (tag >> 16).isOdd) {
      return (tag, DicomElement(vr, bytes));
    }
    return (tag, DicomElement(vr, Uint8List(0)));
  }

  /// Skips items until the matching sequence delimiter (FFFE,E0DD).
  void _skipUndefined({required bool explicit}) {
    while (pos + 8 <= d.length) {
      final tag = peekTag();
      final len = u32(pos + 4);
      if (tag == 0xFFFEE0DD) {
        pos += 8;
        return;
      }
      if (tag == 0xFFFEE000) {
        pos += 8;
        if (len == 0xFFFFFFFF) {
          // Item of undefined length: read elements until item delimiter.
          while (pos + 8 <= d.length && peekTag() != 0xFFFEE00D) {
            if (readElement(explicit: explicit) == null) return;
          }
          pos += 8;
        } else {
          pos += len;
        }
        continue;
      }
      // Unexpected: treat as an element.
      if (readElement(explicit: explicit) == null) return;
    }
  }

  void readPixelData(DicomFile f, {required bool explicit}) {
    final (_, _, len, valueOff) = _header(explicit: explicit);
    if (len != 0xFFFFFFFF) {
      final end = (valueOff + len).clamp(0, d.length);
      f.nativePixels = Uint8List.sublistView(d, valueOff, end);
      pos = end;
      return;
    }
    // Encapsulated: items, first is the basic offset table.
    pos = valueOff;
    final fragments = <Uint8List>[];
    final fragmentOffsets = <int>[]; // relative to first fragment item
    List<int> bot = const [];
    var first = true;
    var firstFragmentItemPos = 0;
    while (pos + 8 <= d.length) {
      final tag = peekTag();
      final itemLen = u32(pos + 4);
      if (tag == 0xFFFEE0DD) break;
      if (tag != 0xFFFEE000) break;
      final start = pos + 8;
      final end = (start + itemLen).clamp(0, d.length);
      if (first) {
        bot = [for (var p = start; p + 4 <= end; p += 4) u32(p)];
        first = false;
        firstFragmentItemPos = end;
      } else {
        fragmentOffsets.add(pos - firstFragmentItemPos);
        fragments.add(Uint8List.sublistView(d, start, end));
      }
      pos = end;
    }
    final nFrames = f.numberOfFrames;
    if (fragments.length == nFrames) {
      f.encapsulatedFrames = fragments;
      return;
    }
    // Several fragments per frame: group them using the offset table, or
    // concatenate everything if there is a single frame.
    final starts = bot.isNotEmpty && bot.length == nFrames ? bot : [0];
    final frames = <Uint8List>[];
    for (var fi = 0; fi < starts.length; fi++) {
      final lo = starts[fi];
      final hi = fi + 1 < starts.length ? starts[fi + 1] : 1 << 62;
      final b = BytesBuilder(copy: false);
      for (var k = 0; k < fragments.length; k++) {
        if (fragmentOffsets[k] >= lo && fragmentOffsets[k] < hi) b.add(fragments[k]);
      }
      frames.add(b.takeBytes());
    }
    f.encapsulatedFrames = frames;
  }
}
