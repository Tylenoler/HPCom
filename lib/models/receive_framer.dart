// Transport reads are not protocol frames. This module keeps that boundary
// explicit: every byte is a frame candidate, an orphan, or an incomplete
// candidate released by a defined bound.

enum ReceiveFramingMode {
  automatic,
  idle,
  fixedLength,
  delimiters,
  templateLength
}

extension ReceiveFramingModeDetails on ReceiveFramingMode {
  String get label => switch (this) {
        ReceiveFramingMode.automatic => '模板长度（兼容）',
        ReceiveFramingMode.idle => '模板长度（兼容）',
        ReceiveFramingMode.fixedLength => '固定长度',
        ReceiveFramingMode.delimiters => '帧头 + 帧尾',
        ReceiveFramingMode.templateLength => '模板长度字段',
      };
}

enum FramedReceiveKind { frame, orphan, incomplete }

extension FramedReceiveKindDetails on FramedReceiveKind {
  String get label => switch (this) {
        FramedReceiveKind.frame => '协议帧',
        FramedReceiveKind.orphan => '孤儿字节',
        FramedReceiveKind.incomplete => '未完成帧',
      };
}

/// [lengthAdjustment] is added to the field value. A payload-length field
/// therefore uses header + length-field + checksum + trailer as adjustment;
/// a whole-frame length field uses zero.
class LengthFieldFramingConfig {
  const LengthFieldFramingConfig({
    this.headerHex = 'AA 55',
    this.headerOffset = 0,
    this.lengthOffset = 2,
    this.lengthBytes = 1,
    this.littleEndian = false,
    this.lengthAdjustment = 5,
    this.maximumFrameBytes = 64 * 1024,
    this.trailerHex = '0D',
  });

  final String headerHex;
  final int headerOffset;
  final int lengthOffset;
  final int lengthBytes;
  final bool littleEndian;
  final int lengthAdjustment;
  final int maximumFrameBytes;
  final String trailerHex;
}

class ReceiveFramingConfig {
  const ReceiveFramingConfig({
    this.mode = ReceiveFramingMode.templateLength,
    this.fixedLength = 4,
    this.headerHex = 'AA 55',
    this.trailerHex = '55 AA',
    this.lengthField = const LengthFieldFramingConfig(),
    this.maximumPendingBytes = 64 * 1024,
  });

  final ReceiveFramingMode mode;
  final int fixedLength;
  final String headerHex;
  final String trailerHex;
  final LengthFieldFramingConfig lengthField;
  final int maximumPendingBytes;
}

class FramedReceiveData {
  const FramedReceiveData(this.bytes, this.timestamp,
      {this.kind = FramedReceiveKind.frame, this.note});

  final List<int> bytes;
  final DateTime timestamp;
  final FramedReceiveKind kind;
  final String? note;

  String get hex => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

class HexParseResult {
  const HexParseResult._(this.bytes, this.error);
  final List<int> bytes;
  final String? error;
  bool get isValid => error == null;
}

/// Parses input without silently turning malformed HEX into an empty stream.
HexParseResult tryParseHexBytes(String hex) {
  final compact = hex.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return const HexParseResult._([], 'HEX 输入为空。');
  if (compact.length.isOdd) {
    return HexParseResult._([], 'HEX 输入长度必须为偶数，当前为 ${compact.length} 个字符。');
  }
  final bytes = <int>[];
  for (var index = 0; index < compact.length; index += 2) {
    final token = compact.substring(index, index + 2);
    final byte = int.tryParse(token, radix: 16);
    if (byte == null) {
      return HexParseResult._([], 'HEX 输入在第 ${index + 1} 个字符附近无效：$token。');
    }
    bytes.add(byte);
  }
  return HexParseResult._(List.unmodifiable(bytes), null);
}

/// Use [tryParseHexBytes] when interactive validation must stay in-band. This
/// convenience form fails loudly instead of discarding invalid data.
List<int> parseHexBytes(String hex) {
  final result = tryParseHexBytes(hex);
  if (!result.isValid) throw FormatException(result.error ?? 'HEX 输入无效。');
  return result.bytes;
}

/// Deterministically turns arbitrary UART reads into display items. A read
/// offset avoids repeated head removal from a potentially large list.
class ReceiveFramer {
  ReceiveFramer([this.config = const ReceiveFramingConfig()]);

  ReceiveFramingConfig config;
  final List<int> _pending = [];
  int _pendingStart = 0;
  DateTime? _pendingTimestamp;

  int get pendingByteCount => _pending.length - _pendingStart;

  void configure(ReceiveFramingConfig value) {
    config = value;
    reset();
  }

  void reset() {
    _pending.clear();
    _pendingStart = 0;
    _pendingTimestamp = null;
  }

  List<FramedReceiveData> addHex(String hex, DateTime timestamp) =>
      add(parseHexBytes(hex), timestamp);

  List<FramedReceiveData> add(List<int> bytes, DateTime timestamp) {
    if (bytes.isEmpty) return const [];
    return switch (config.mode) {
      ReceiveFramingMode.fixedLength => _addFixed(bytes, timestamp),
      ReceiveFramingMode.delimiters => _addDelimited(bytes, timestamp),
      // Saved legacy values now resolve to the deterministic template rule.
      ReceiveFramingMode.automatic ||
      ReceiveFramingMode.idle ||
      ReceiveFramingMode.templateLength =>
        _addLengthField(bytes, timestamp),
    };
  }

  /// Call at a visible boundary (mode switch, disconnect, export). Held data
  /// is not misrepresented as a completed frame.
  List<FramedReceiveData> flush() {
    if (pendingByteCount == 0) return const [];
    final header = switch (config.mode) {
      ReceiveFramingMode.delimiters => tryParseHexBytes(config.headerHex).bytes,
      _ => tryParseHexBytes(config.lengthField.headerHex).bytes,
    };
    final isHeaderPrefix = header.isNotEmpty &&
        pendingByteCount <= header.length &&
        _matchesHeaderPrefix(header);
    return [
      _takePrefix(
          pendingByteCount,
          isHeaderPrefix
              ? FramedReceiveKind.incomplete
              : FramedReceiveKind.orphan,
          isHeaderPrefix ? '输入结束前未满足完整帧条件' : '输入结束时仍未匹配任何完整帧')
    ];
  }

  List<FramedReceiveData> _addFixed(List<int> bytes, DateTime timestamp) {
    final length = config.fixedLength.clamp(1, config.maximumPendingBytes);
    _append(bytes, timestamp);
    final output = <FramedReceiveData>[];
    while (pendingByteCount >= length) {
      output.add(_takePrefix(length, FramedReceiveKind.frame));
    }
    _releaseOverLimit(output);
    return output;
  }

  List<FramedReceiveData> _addDelimited(List<int> bytes, DateTime timestamp) {
    final header = tryParseHexBytes(config.headerHex);
    final trailer = tryParseHexBytes(config.trailerHex);
    if (!header.isValid ||
        !trailer.isValid ||
        header.bytes.isEmpty ||
        trailer.bytes.isEmpty) {
      throw FormatException('帧头/帧尾配置无效：${header.error ?? trailer.error}');
    }
    _append(bytes, timestamp);
    final output = <FramedReceiveData>[];
    while (pendingByteCount > 0) {
      final headerAt = _indexOfPending(header.bytes);
      if (headerAt < 0) {
        _releaseSafeNonHeaderPrefix(output, header.bytes);
        break;
      }
      if (headerAt > 0) {
        output
            .add(_takePrefix(headerAt, FramedReceiveKind.orphan, '帧头前的未归属字节'));
        continue;
      }
      final trailerAt = _indexOfPending(trailer.bytes, header.bytes.length);
      if (trailerAt >= 0) {
        output.add(_takePrefix(
            trailerAt + trailer.bytes.length, FramedReceiveKind.frame));
        continue;
      }
      final nextHeader = _indexOfPending(header.bytes, header.bytes.length);
      if (nextHeader > 0) {
        output.add(_takePrefix(
            nextHeader, FramedReceiveKind.incomplete, '发现新的帧头前仍未找到帧尾，已重新同步'));
        continue;
      }
      break;
    }
    _releaseOverLimit(output);
    return output;
  }

  List<FramedReceiveData> _addLengthField(List<int> bytes, DateTime timestamp) {
    final rule = config.lengthField;
    final headerResult = tryParseHexBytes(rule.headerHex);
    if (!headerResult.isValid || headerResult.bytes.isEmpty) {
      throw FormatException('长度字段模式的帧头无效：${headerResult.error}');
    }
    final header = headerResult.bytes;
    final lengthWidth = rule.lengthBytes.clamp(1, 4);
    final trailerResult = tryParseHexBytes(rule.trailerHex);
    final trailer = trailerResult.isValid ? trailerResult.bytes : const <int>[];
    // The declared value counts payload bytes, so a zero-length payload is a
    // legitimate frame: the smallest possible frame is header + length field +
    // trailer, and a template whose fixed fields are wider than that (checksum
    // included) raises the floor. Deriving the floor from the adjustment
    // double-counts those fixed fields and splits valid short frames into
    // orphans.
    final structuralMinimum = header.length + lengthWidth + trailer.length;
    final minimum = (rule.lengthAdjustment > structuralMinimum
            ? rule.lengthAdjustment
            : structuralMinimum)
        .clamp(1, rule.maximumFrameBytes);
    _append(bytes, timestamp);
    final output = <FramedReceiveData>[];
    while (pendingByteCount > 0) {
      final headerAt = _indexOfPending(header);
      if (headerAt < 0) {
        _releaseSafeNonHeaderPrefix(output, header);
        break;
      }
      if (headerAt > 0) {
        output
            .add(_takePrefix(headerAt, FramedReceiveKind.orphan, '帧头前的未归属字节'));
        continue;
      }
      final requiredForLength = rule.lengthOffset + lengthWidth;
      if (pendingByteCount < requiredForLength) break;
      final declared =
          _readUnsigned(rule.lengthOffset, lengthWidth, rule.littleEndian);
      final total = declared + rule.lengthAdjustment;
      if (total < minimum || total > rule.maximumFrameBytes) {
        final nextHeader = _indexOfPending(header, header.length);
        output.add(_takePrefix(
            nextHeader > 0 ? nextHeader : 1,
            FramedReceiveKind.orphan,
            '长度字段声明 $declared B，超出允许的帧范围 $minimum–${rule.maximumFrameBytes} B'));
        continue;
      }
      if (pendingByteCount < total) {
        final nextHeader = _indexOfPending(header, header.length);
        if (nextHeader > 0) {
          output.add(_takePrefix(nextHeader, FramedReceiveKind.incomplete,
              '长度字段声明 $total B，但在完成前遇到新的帧头'));
          continue;
        }
        break;
      }
      final trailerMatches = trailer.isNotEmpty
          ? _matchesPending(total - trailer.length, trailer)
          : true;
      final nextHeader = _indexOfPending(header, header.length);
      // A second header only causes resynchronisation when the claimed frame
      // also fails its fixed trailer. Valid adversarial payloads may contain
      // header-looking bytes and must remain part of their declared frame.
      if (!trailerMatches && nextHeader > 0 && nextHeader < total) {
        output.add(_takePrefix(
            nextHeader, FramedReceiveKind.incomplete, '长度候选帧尾不匹配，已在后续帧头处重新同步'));
        continue;
      }
      output.add(_takePrefix(total, FramedReceiveKind.frame,
          trailerMatches ? null : '帧尾不匹配；保留为可检查的协议候选帧'));
    }
    _releaseOverLimit(output);
    return output;
  }

  void _append(List<int> bytes, DateTime timestamp) {
    if (pendingByteCount == 0) _pendingTimestamp = timestamp;
    _pending.addAll(bytes);
  }

  FramedReceiveData _takePrefix(int count, FramedReceiveKind kind,
      [String? note]) {
    final safeCount = count.clamp(0, pendingByteCount);
    final timestamp = _pendingTimestamp ?? DateTime.now().toUtc();
    final bytes = List<int>.unmodifiable(
        _pending.sublist(_pendingStart, _pendingStart + safeCount));
    _pendingStart += safeCount;
    if (_pendingStart == _pending.length) {
      _pending.clear();
      _pendingStart = 0;
      _pendingTimestamp = null;
    } else if (_pendingStart > 4096 && _pendingStart * 2 >= _pending.length) {
      _pending.removeRange(0, _pendingStart);
      _pendingStart = 0;
    }
    return FramedReceiveData(bytes, timestamp, kind: kind, note: note);
  }

  void _releaseOverLimit(List<FramedReceiveData> output) {
    final maximum = config.maximumPendingBytes.clamp(1, 4 * 1024 * 1024);
    if (pendingByteCount <= maximum) return;
    output.add(_takePrefix(pendingByteCount - maximum,
        FramedReceiveKind.incomplete, '缓冲超过 $maximum B 上限，已强制释放未完成数据'));
  }

  void _releaseSafeNonHeaderPrefix(
      List<FramedReceiveData> output, List<int> header) {
    final retain = (header.length - 1).clamp(0, pendingByteCount);
    final count = pendingByteCount - retain;
    if (count > 0) {
      output.add(_takePrefix(count, FramedReceiveKind.orphan, '未匹配任何帧头'));
    }
  }

  int _readUnsigned(int offset, int width, bool littleEndian) {
    var value = 0;
    for (var index = 0; index < width; index++) {
      final shiftIndex = littleEndian ? index : width - index - 1;
      value |= _pending[_pendingStart + offset + index] << (shiftIndex * 8);
    }
    return value;
  }

  int _indexOfPending(List<int> pattern, [int start = 0]) {
    final available = pendingByteCount;
    if (pattern.isEmpty || available < pattern.length) return -1;
    for (var index = start; index <= available - pattern.length; index++) {
      if (_matchesPending(index, pattern)) return index;
    }
    return -1;
  }

  bool _matchesPending(int offset, List<int> pattern) {
    if (offset < 0 || offset + pattern.length > pendingByteCount) return false;
    for (var index = 0; index < pattern.length; index++) {
      if (_pending[_pendingStart + offset + index] != pattern[index]) {
        return false;
      }
    }
    return true;
  }

  bool _matchesHeaderPrefix(List<int> header) {
    for (var index = 0; index < pendingByteCount; index++) {
      if (_pending[_pendingStart + index] != header[index]) return false;
    }
    return true;
  }
}
