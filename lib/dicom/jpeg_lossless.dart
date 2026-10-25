import 'dart:typed_data';

/// Decoder for JPEG Lossless (ITU-T T.81 process 14, Huffman coded),
/// as used by DICOM transfer syntaxes 1.2.840.10008.1.2.4.57 and .70.
/// Supports one or more components, all seven predictors, point transform
/// and restart intervals. Returns samples as unsigned 16-bit values
/// (interleaved if there are several components).
class JpegLosslessDecoder {
  JpegLosslessDecoder(this._d);

  final Uint8List _d;
  int _pos = 0;

  int width = 0;
  int height = 0;
  int precision = 0;
  int numComponents = 0;

  final List<_Huffman?> _tables = List<_Huffman?>.filled(4, null);
  int _restartInterval = 0;

  // Bit reader state.
  int _bitBuf = 0;
  int _bitCount = 0;
  bool _hitMarker = false;

  Uint16List decode() {
    if (_u8() != 0xFF || _u8() != 0xD8) {
      throw const FormatException('JPEG: missing SOI');
    }
    List<int> compIds = const [];
    Uint16List? out;
    while (_pos < _d.length) {
      int m = _u8();
      if (m != 0xFF) continue;
      int marker = _u8();
      while (marker == 0xFF) {
        marker = _u8();
      }
      switch (marker) {
        case 0xD9: // EOI
          if (out == null) throw const FormatException('JPEG: no scan');
          return out;
        case 0xC3: // SOF3 lossless, Huffman
        case 0xC7: // SOF7 differential lossless, treated as SOF3
          final len = _u16();
          final end = _pos + len - 2;
          precision = _u8();
          height = _u16();
          width = _u16();
          numComponents = _u8();
          compIds = [];
          for (var i = 0; i < numComponents; i++) {
            compIds.add(_u8());
            _u8(); // sampling factors (must be 1x1 for lossless here)
            _u8(); // quantization table (unused)
          }
          _pos = end;
          out = Uint16List(width * height * numComponents);
        case 0xC4: // DHT
          _readHuffmanTables();
        case 0xDD: // DRI
          _u16();
          _restartInterval = _u16();
        case 0xDA: // SOS
          if (out == null) throw const FormatException('JPEG: SOS before SOF');
          _readScan(out, compIds);
        case 0xC0 || 0xC1 || 0xC2:
          throw const FormatException('JPEG: lossy JPEG is not supported');
        default:
          // APPn, COM, DQT etc.: skip.
          if (marker >= 0xD0 && marker <= 0xD7) break; // stray RST
          final len = _u16();
          _pos += len - 2;
      }
    }
    if (out == null) throw const FormatException('JPEG: truncated');
    return out;
  }

  int _u8() => _d[_pos++];
  int _u16() {
    final v = (_d[_pos] << 8) | _d[_pos + 1];
    _pos += 2;
    return v;
  }

  void _readHuffmanTables() {
    final len = _u16();
    final end = _pos + len - 2;
    while (_pos < end) {
      final tcth = _u8();
      final th = tcth & 0x0F;
      final counts = Uint8List(16);
      var total = 0;
      for (var i = 0; i < 16; i++) {
        counts[i] = _u8();
        total += counts[i];
      }
      final symbols = Uint8List.fromList(_d.sublist(_pos, _pos + total));
      _pos += total;
      _tables[th] = _Huffman(counts, symbols);
    }
  }

  void _readScan(Uint16List out, List<int> compIds) {
    final len = _u16();
    final end = _pos + len - 2;
    final ns = _u8();
    final tables = <_Huffman>[];
    final compIndex = <int>[];
    for (var i = 0; i < ns; i++) {
      final cid = _u8();
      final td = _u8() >> 4;
      final t = _tables[td];
      if (t == null) throw const FormatException('JPEG: missing Huffman table');
      tables.add(t);
      compIndex.add(compIds.indexOf(cid));
    }
    final predictor = _u8(); // Ss
    _u8(); // Se
    final pt = _u8() & 0x0F; // Al = point transform
    _pos = end;

    final nc = numComponents;
    final w = width;
    final h = height;
    final mask = (1 << precision) - 1;
    final initial = 1 << (precision - pt - 1);
    // Reconstructed values before the point transform is undone.
    final rec = Int32List(w * h * nc);

    _bitBuf = 0;
    _bitCount = 0;
    _hitMarker = false;
    // T.81 H.1.1: in lossless mode a restart interval is a whole number of
    // rows, so restarts only happen at the start of a row.
    var mcu = 0;
    for (var y = 0; y < h; y++) {
      var firstRow = y == 0;
      if (_restartInterval != 0 && mcu != 0 && mcu % _restartInterval == 0) {
        _processRestart();
        firstRow = true;
      }
      for (var x = 0; x < w; x++) {
        for (var s = 0; s < ns; s++) {
          final idx = (y * w + x) * nc + compIndex[s];
          int pred;
          if (firstRow) {
            pred = x == 0 ? initial : rec[idx - nc]; // Ra
          } else if (x == 0) {
            pred = rec[idx - w * nc]; // Rb
          } else {
            final ra = rec[idx - nc];
            final rb = rec[idx - w * nc];
            final rc = rec[idx - w * nc - nc];
            pred = switch (predictor) {
              1 => ra,
              2 => rb,
              3 => rc,
              4 => ra + rb - rc,
              5 => ra + ((rb - rc) >> 1),
              6 => rb + ((ra - rc) >> 1),
              7 => (ra + rb) >> 1,
              _ => ra,
            };
          }
          rec[idx] = (pred + _decodeDiff(tables[s])) & mask;
        }
        mcu++;
      }
    }
    for (var i = 0; i < rec.length; i++) {
      out[i] = (rec[i] << pt) & 0xFFFF;
    }
    _pos = _markerPos();
  }

  int _markerPos() {
    // After decoding, _pos may be past bytes consumed into the bit buffer.
    // Search backward-safe: scan forward from a little before for 0xFF xx
    // where xx != 0 and not RST.
    var p = _pos - 2 < 0 ? 0 : _pos - 2;
    while (p < _d.length - 1) {
      if (_d[p] == 0xFF) {
        final n = _d[p + 1];
        if (n != 0 && n != 0xFF && !(n >= 0xD0 && n <= 0xD7)) return p;
      }
      p++;
    }
    return _d.length;
  }

  void _processRestart() {
    _bitBuf = 0;
    _bitCount = 0;
    _hitMarker = false;
    // Find RSTn marker.
    while (_pos < _d.length - 1) {
      if (_d[_pos] == 0xFF && _d[_pos + 1] >= 0xD0 && _d[_pos + 1] <= 0xD7) {
        _pos += 2;
        return;
      }
      _pos++;
    }
  }

  void _fill() {
    while (_bitCount <= 24) {
      int b = 0;
      if (!_hitMarker && _pos < _d.length) {
        b = _d[_pos];
        if (b == 0xFF) {
          final n = _pos + 1 < _d.length ? _d[_pos + 1] : 0;
          if (n == 0x00) {
            _pos += 2;
          } else {
            _hitMarker = true;
            b = 0;
          }
        } else {
          _pos++;
        }
      }
      _bitBuf = ((_bitBuf << 8) | b) & 0xFFFFFFFF;
      _bitCount += 8;
    }
  }

  int _bits(int n) {
    if (n == 0) return 0;
    if (_bitCount < n) _fill();
    final v = (_bitBuf >> (_bitCount - n)) & ((1 << n) - 1);
    _bitCount -= n;
    return v;
  }

  int _decodeDiff(_Huffman t) {
    if (_bitCount < 16) _fill();
    // Fast path: 9-bit lookup.
    final peek = (_bitBuf >> (_bitCount - _Huffman.fastBits)) &
        ((1 << _Huffman.fastBits) - 1);
    var entry = t.fast[peek];
    int ssss;
    if (entry != 0) {
      _bitCount -= entry >> 8;
      ssss = entry & 0xFF;
    } else {
      ssss = t.decodeSlow(this);
    }
    if (ssss == 0) return 0;
    if (ssss == 16) return 32768;
    final v = _bits(ssss);
    // EXTEND
    return v < (1 << (ssss - 1)) ? v - (1 << ssss) + 1 : v;
  }
}

class _Huffman {
  _Huffman(Uint8List counts, this.symbols) {
    var code = 0;
    var k = 0;
    for (var len = 1; len <= 16; len++) {
      valPtr[len] = k;
      minCode[len] = code;
      code += counts[len - 1];
      k += counts[len - 1];
      maxCode[len] = counts[len - 1] == 0 ? -1 : code - 1;
      code <<= 1;
    }
    // Build fast table for codes of length <= fastBits.
    code = 0;
    k = 0;
    for (var len = 1; len <= 16; len++) {
      for (var i = 0; i < counts[len - 1]; i++) {
        if (len <= fastBits) {
          final shift = fastBits - len;
          final base = code << shift;
          for (var j = 0; j < (1 << shift); j++) {
            fast[base + j] = (len << 8) | symbols[k];
          }
        }
        code++;
        k++;
      }
      code <<= 1;
    }
  }

  static const fastBits = 9;
  final Uint8List symbols;
  final Int32List minCode = Int32List(17);
  final Int32List maxCode = Int32List(17);
  final Int32List valPtr = Int32List(17);
  final Uint16List fast = Uint16List(1 << fastBits);

  int decodeSlow(JpegLosslessDecoder r) {
    var code = 0;
    for (var len = 1; len <= 16; len++) {
      code = (code << 1) | r._bits(1);
      if (maxCode[len] >= 0 && code <= maxCode[len]) {
        return symbols[valPtr[len] + code - minCode[len]];
      }
    }
    throw const FormatException('JPEG: bad Huffman code');
  }
}
