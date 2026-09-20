import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'receive_framer.dart';

enum ProtocolFieldKind { header, length, payload, checksum, trailer, integer }

extension ProtocolFieldKindDetails on ProtocolFieldKind {
  String get label => switch (this) {
        ProtocolFieldKind.header => '帧头',
        ProtocolFieldKind.length => '长度',
        ProtocolFieldKind.payload => '数据域',
        ProtocolFieldKind.checksum => '校验',
        ProtocolFieldKind.trailer => '帧尾',
        ProtocolFieldKind.integer => '数值字段',
      };
}

enum ByteOrder { bigEndian, littleEndian }

extension ByteOrderDetails on ByteOrder {
  String get label => this == ByteOrder.bigEndian ? '大端' : '小端';
}

enum ChecksumAlgorithm { sum8, crc16Modbus }

/// Common CRC variants exposed by the calculator.  The parser intentionally
/// keeps its template checksum selection smaller for Phase 3 compatibility.
enum CrcAlgorithm {
  crc8,
  crc8Maxim,
  crc16Ibm,
  crc16Modbus,
  crc16CcittFalse,
  crc16X25,
  crc32IsoHdlc,
}

extension CrcAlgorithmDetails on CrcAlgorithm {
  String get label => switch (this) {
        CrcAlgorithm.crc8 => 'CRC-8',
        CrcAlgorithm.crc8Maxim => 'CRC-8/MAXIM',
        CrcAlgorithm.crc16Ibm => 'CRC-16/IBM',
        CrcAlgorithm.crc16Modbus => 'CRC-16/MODBUS',
        CrcAlgorithm.crc16CcittFalse => 'CRC-16/CCITT-FALSE',
        CrcAlgorithm.crc16X25 => 'CRC-16/X25',
        CrcAlgorithm.crc32IsoHdlc => 'CRC-32/ISO-HDLC',
      };

  String get parameters => switch (this) {
        CrcAlgorithm.crc8 => 'Width 8 · Poly 07 · Init 00',
        CrcAlgorithm.crc8Maxim => 'Width 8 · Poly 31 · Init 00',
        CrcAlgorithm.crc16Ibm => 'Width 16 · Poly 8005 · Init 0000',
        CrcAlgorithm.crc16Modbus => 'Width 16 · Poly 8005 · Init FFFF',
        CrcAlgorithm.crc16CcittFalse => 'Width 16 · Poly 1021 · Init FFFF',
        CrcAlgorithm.crc16X25 =>
          'Width 16 · Poly 1021 · Init FFFF · XorOut FFFF',
        CrcAlgorithm.crc32IsoHdlc => 'Width 32 · Poly 04C11DB7 · Init FFFFFFFF',
      };

  int get bitWidth => switch (this) {
        CrcAlgorithm.crc8 || CrcAlgorithm.crc8Maxim => 8,
        CrcAlgorithm.crc32IsoHdlc => 32,
        _ => 16,
      };

  ByteOrder get defaultByteOrder => switch (this) {
        CrcAlgorithm.crc16CcittFalse => ByteOrder.bigEndian,
        _ => ByteOrder.littleEndian,
      };

  int calculate(List<int> bytes) => switch (this) {
        CrcAlgorithm.crc8 => _crc8(bytes),
        CrcAlgorithm.crc8Maxim => _crc8Maxim(bytes),
        CrcAlgorithm.crc16Ibm => _crc16Reflected(bytes, initial: 0x0000),
        CrcAlgorithm.crc16Modbus => crc16Modbus(bytes),
        CrcAlgorithm.crc16CcittFalse => _crc16CcittFalse(bytes),
        CrcAlgorithm.crc16X25 => _crc16X25(bytes),
        CrcAlgorithm.crc32IsoHdlc => _crc32IsoHdlc(bytes),
      };
}

/// User-configurable CRC parameters. The polynomial is supplied without the
/// implicit top bit (for example 0x1021 for CRC-16/CCITT).
class CustomCrcConfig {
  const CustomCrcConfig({
    required this.width,
    required this.polynomial,
    required this.initial,
    required this.xorOut,
    required this.reflectInput,
    required this.reflectOutput,
  });

  final int width;
  final int polynomial;
  final int initial;
  final int xorOut;
  final bool reflectInput;
  final bool reflectOutput;

  factory CustomCrcConfig.modbus() => const CustomCrcConfig(
        width: 16,
        polynomial: 0x8005,
        initial: 0xFFFF,
        xorOut: 0x0000,
        reflectInput: true,
        reflectOutput: true,
      );
}

int calculateCustomCrc(List<int> bytes, CustomCrcConfig config) {
  if (config.width < 8 || config.width > 32) {
    throw ArgumentError.value(config.width, 'width', '必须在 8–32 位之间。');
  }
  final mask = config.width == 32 ? 0xFFFFFFFF : (1 << config.width) - 1;
  final topBit = 1 << (config.width - 1);
  var crc = config.initial & mask;
  for (final input in bytes) {
    final byte = config.reflectInput ? _reflectBits(input, 8) : input;
    crc ^= byte << (config.width - 8);
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & topBit) != 0
          ? ((crc << 1) ^ config.polynomial) & mask
          : (crc << 1) & mask;
    }
  }
  if (config.reflectOutput) crc = _reflectBits(crc, config.width);
  return (crc ^ config.xorOut) & mask;
}

int _reflectBits(int value, int width) {
  var reflected = 0;
  for (var bit = 0; bit < width; bit++) {
    if ((value & (1 << bit)) != 0) reflected |= 1 << (width - bit - 1);
  }
  return reflected;
}

/// Frequently used byte checksums, CRCs and cryptographic digests for the
/// verification calculator. MD5/SHA are hashes, not reversible encryption.
enum IntegrityAlgorithm {
  sum8,
  xor8,
  lrc,
  crc8,
  crc8Maxim,
  crc16Ibm,
  crc16Modbus,
  crc16CcittFalse,
  crc16X25,
  crc32IsoHdlc,
  customCrc,
  md5,
  sha1,
  sha256,
}

extension IntegrityAlgorithmDetails on IntegrityAlgorithm {
  String get label => switch (this) {
        IntegrityAlgorithm.sum8 => 'SUM-8',
        IntegrityAlgorithm.xor8 => 'XOR-8',
        IntegrityAlgorithm.lrc => 'LRC',
        IntegrityAlgorithm.crc8 => 'CRC-8',
        IntegrityAlgorithm.crc8Maxim => 'CRC-8/MAXIM',
        IntegrityAlgorithm.crc16Ibm => 'CRC-16/IBM',
        IntegrityAlgorithm.crc16Modbus => 'CRC-16/MODBUS',
        IntegrityAlgorithm.crc16CcittFalse => 'CRC-16/CCITT-FALSE',
        IntegrityAlgorithm.crc16X25 => 'CRC-16/X25',
        IntegrityAlgorithm.crc32IsoHdlc => 'CRC-32/ISO-HDLC',
        IntegrityAlgorithm.customCrc => 'CRC-自定义',
        IntegrityAlgorithm.md5 => 'MD5',
        IntegrityAlgorithm.sha1 => 'SHA-1',
        IntegrityAlgorithm.sha256 => 'SHA-256',
      };

  bool get isCrc => switch (this) {
        IntegrityAlgorithm.crc8 ||
        IntegrityAlgorithm.crc8Maxim ||
        IntegrityAlgorithm.crc16Ibm ||
        IntegrityAlgorithm.crc16Modbus ||
        IntegrityAlgorithm.crc16CcittFalse ||
        IntegrityAlgorithm.crc16X25 ||
        IntegrityAlgorithm.crc32IsoHdlc ||
        IntegrityAlgorithm.customCrc =>
          true,
        _ => false,
      };

  bool get isDigest =>
      this == IntegrityAlgorithm.md5 ||
      this == IntegrityAlgorithm.sha1 ||
      this == IntegrityAlgorithm.sha256;

  int get bitWidth => switch (this) {
        IntegrityAlgorithm.sum8 ||
        IntegrityAlgorithm.xor8 ||
        IntegrityAlgorithm.lrc ||
        IntegrityAlgorithm.crc8 ||
        IntegrityAlgorithm.crc8Maxim =>
          8,
        IntegrityAlgorithm.crc32IsoHdlc => 32,
        IntegrityAlgorithm.md5 => 128,
        IntegrityAlgorithm.sha1 => 160,
        IntegrityAlgorithm.sha256 => 256,
        _ => 16,
      };

  List<int> calculate(List<int> bytes, {CustomCrcConfig? customCrc}) =>
      switch (this) {
        IntegrityAlgorithm.sum8 => [
            bytes.fold(0, (sum, byte) => (sum + byte) & 0xFF)
          ],
        IntegrityAlgorithm.xor8 => [
            bytes.fold(0, (value, byte) => value ^ byte)
          ],
        IntegrityAlgorithm.lrc => [
            (-bytes.fold(0, (sum, byte) => (sum + byte) & 0xFF)) & 0xFF
          ],
        IntegrityAlgorithm.crc8 => [_crc8(bytes)],
        IntegrityAlgorithm.crc8Maxim => [_crc8Maxim(bytes)],
        IntegrityAlgorithm.crc16Ibm =>
          _integerToBytes(_crc16Reflected(bytes, initial: 0x0000), 16),
        IntegrityAlgorithm.crc16Modbus =>
          _integerToBytes(crc16Modbus(bytes), 16),
        IntegrityAlgorithm.crc16CcittFalse =>
          _integerToBytes(_crc16CcittFalse(bytes), 16),
        IntegrityAlgorithm.crc16X25 => _integerToBytes(_crc16X25(bytes), 16),
        IntegrityAlgorithm.crc32IsoHdlc =>
          _integerToBytes(_crc32IsoHdlc(bytes), 32),
        IntegrityAlgorithm.customCrc => _integerToBytes(
            calculateCustomCrc(bytes, customCrc ?? CustomCrcConfig.modbus()),
            (customCrc ?? CustomCrcConfig.modbus()).width),
        IntegrityAlgorithm.md5 => crypto.md5.convert(bytes).bytes,
        IntegrityAlgorithm.sha1 => crypto.sha1.convert(bytes).bytes,
        IntegrityAlgorithm.sha256 => crypto.sha256.convert(bytes).bytes,
      };
}

List<int> _integerToBytes(int value, int width) => List<int>.generate(
      (width + 7) ~/ 8,
      (index) => (value >> (8 * ((width + 7) ~/ 8 - index - 1))) & 0xFF,
    );

/// CRC-16/MODBUS: poly 0xA001, init 0xFFFF, xor-out 0x0000.
///
/// Kept public so protocol parsing and the CRC utility always use the exact
/// same implementation.
int crc16Modbus(List<int> bytes) {
  return _crc16Reflected(bytes, initial: 0xFFFF);
}

int _crc8(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

int _crc8Maxim(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1;
    }
  }
  return crc & 0xFF;
}

int _crc16Reflected(List<int> bytes, {required int initial}) {
  var crc = initial;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}

int _crc16CcittFalse(List<int> bytes) {
  var crc = 0xFFFF;
  for (final byte in bytes) {
    crc ^= byte << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : crc << 1;
      crc &= 0xFFFF;
    }
  }
  return crc;
}

int _crc16X25(List<int> bytes) {
  var crc = 0xFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFF) & 0xFFFF;
}

int _crc32IsoHdlc(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

extension ChecksumAlgorithmDetails on ChecksumAlgorithm {
  String get label => switch (this) {
        ChecksumAlgorithm.sum8 => 'SUM-8',
        ChecksumAlgorithm.crc16Modbus => 'CRC-16/MODBUS',
      };
}

class ProtocolField {
  const ProtocolField({
    required this.id,
    required this.kind,
    required this.name,
    this.byteLength = 1,
    this.byteOrder = ByteOrder.bigEndian,
    this.valueHex = '',
    this.checksumAlgorithm = ChecksumAlgorithm.sum8,
  });

  final String id;
  final ProtocolFieldKind kind;
  final String name;
  final int byteLength;
  final ByteOrder byteOrder;
  final String valueHex;
  final ChecksumAlgorithm checksumAlgorithm;

  ProtocolField copyWith({
    String? id,
    ProtocolFieldKind? kind,
    String? name,
    int? byteLength,
    ByteOrder? byteOrder,
    String? valueHex,
    ChecksumAlgorithm? checksumAlgorithm,
  }) =>
      ProtocolField(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        name: name ?? this.name,
        byteLength: byteLength ?? this.byteLength,
        byteOrder: byteOrder ?? this.byteOrder,
        valueHex: valueHex ?? this.valueHex,
        checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'byteLength': byteLength,
        'byteOrder': byteOrder.name,
        'valueHex': valueHex,
        'checksumAlgorithm': checksumAlgorithm.name,
      };

  factory ProtocolField.fromJson(Map<String, dynamic> json) => ProtocolField(
        id: json['id'] as String? ?? 'field',
        kind: ProtocolFieldKind.values.byName(json['kind'] as String),
        name: json['name'] as String? ?? '字段',
        byteLength: (json['byteLength'] as num?)?.toInt() ?? 1,
        byteOrder: ByteOrder.values
            .byName(json['byteOrder'] as String? ?? ByteOrder.bigEndian.name),
        valueHex: json['valueHex'] as String? ?? '',
        checksumAlgorithm: ChecksumAlgorithm.values.byName(
            json['checksumAlgorithm'] as String? ??
                ChecksumAlgorithm.sum8.name),
      );
}

class FrameTemplate {
  const FrameTemplate({
    required this.id,
    required this.name,
    required this.fields,
  });

  final String id;
  final String name;
  final List<ProtocolField> fields;

  factory FrameTemplate.standard() => const FrameTemplate(
        id: 'hcom-default',
        name: '默认 UART 帧',
        fields: [
          ProtocolField(
              id: 'header',
              kind: ProtocolFieldKind.header,
              name: '帧头',
              byteLength: 2,
              valueHex: 'AA 55'),
          ProtocolField(
              id: 'length', kind: ProtocolFieldKind.length, name: '长度'),
          ProtocolField(
              id: 'payload', kind: ProtocolFieldKind.payload, name: '数据域'),
          ProtocolField(
              id: 'checksum',
              kind: ProtocolFieldKind.checksum,
              name: '和校验',
              checksumAlgorithm: ChecksumAlgorithm.sum8),
          ProtocolField(
              id: 'trailer',
              kind: ProtocolFieldKind.trailer,
              name: '帧尾',
              byteLength: 1,
              valueHex: '0D'),
        ],
      );

  FrameTemplate copyWith(
          {String? id, String? name, List<ProtocolField>? fields}) =>
      FrameTemplate(
          id: id ?? this.id,
          name: name ?? this.name,
          fields: fields ?? this.fields);

  /// Derives deterministic stream framing from this editable template. The
  /// length field denotes the payload; every non-payload field is added back
  /// to obtain the whole-frame byte count.
  ReceiveFramingConfig receiveFramingConfig({
    ReceiveFramingMode mode = ReceiveFramingMode.templateLength,
  }) {
    ProtocolField? header;
    ProtocolField? length;
    ProtocolField? trailer;
    var fixedBytes = 0;
    var offset = 0;
    var headerOffset = 0;
    var lengthOffset = 0;
    for (final field in fields) {
      final size = field.byteLength.clamp(0, 4096);
      if (field.kind == ProtocolFieldKind.header && header == null) {
        header = field;
        headerOffset = offset;
      }
      if (field.kind == ProtocolFieldKind.length && length == null) {
        length = field;
        lengthOffset = offset;
      }
      if (field.kind == ProtocolFieldKind.trailer && trailer == null) {
        trailer = field;
      }
      if (field.kind != ProtocolFieldKind.payload) {
        fixedBytes += size;
        offset += size;
      }
    }
    if (header == null || length == null) {
      throw FormatException('模板“$name”缺少帧头或长度字段，无法用于长度字段分帧。');
    }
    final headerBytes = tryParseHexBytes(header.valueHex);
    if (!headerBytes.isValid || headerBytes.bytes.length != header.byteLength) {
      throw FormatException(
          '模板“$name”的帧头 HEX 无效或长度不匹配：${headerBytes.error ?? ''}');
    }
    final validatedTrailer = trailer;
    final trailerBytes = validatedTrailer == null
        ? null
        : tryParseHexBytes(validatedTrailer.valueHex);
    if (trailerBytes != null &&
        (!trailerBytes.isValid ||
            trailerBytes.bytes.length != validatedTrailer!.byteLength)) {
      throw FormatException(
          '模板“$name”的帧尾 HEX 无效或长度不匹配：${trailerBytes.error ?? ''}');
    }
    return ReceiveFramingConfig(
      mode: mode,
      headerHex: header.valueHex,
      trailerHex: trailer?.valueHex ?? '',
      lengthField: LengthFieldFramingConfig(
        headerHex: header.valueHex,
        headerOffset: headerOffset,
        lengthOffset: lengthOffset,
        lengthBytes: length.byteLength.clamp(1, 4),
        littleEndian: length.byteOrder == ByteOrder.littleEndian,
        lengthAdjustment: fixedBytes,
        trailerHex: trailer?.valueHex ?? '',
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'name': name,
        'fields': fields.map((field) => field.toJson()).toList()
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory FrameTemplate.decode(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic> || json['fields'] is! List) {
      throw const FormatException('不是有效的 HPCOM 帧模板 JSON。');
    }
    final fields = (json['fields'] as List)
        .whereType<Map>()
        .map(
            (value) => ProtocolField.fromJson(Map<String, dynamic>.from(value)))
        .toList();
    if (fields.isEmpty) throw const FormatException('帧模板至少需要一个字段。');
    return FrameTemplate(
        id: json['id'] as String? ?? 'imported',
        name: json['name'] as String? ?? '导入模板',
        fields: fields);
  }
}

class ParsedField {
  const ParsedField({required this.field, required this.bytes, this.value});
  final ProtocolField field;
  final List<int> bytes;
  final int? value;
  String get hex => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

class ParsedFrame {
  const ParsedFrame({required this.fields, required this.valid, this.error});
  final List<ParsedField> fields;
  final bool valid;
  final String? error;
}

/// Stateless parser for a single UI display frame. Transport framing stays in
/// [ReceiveFramer]; this validates and labels bytes without changing Core I/O.
class ProtocolFrameParser {
  const ProtocolFrameParser(this.template);
  final FrameTemplate template;

  ParsedFrame parseHex(String hex) {
    final input = tryParseHexBytes(hex);
    if (!input.isValid) {
      return const ParsedFrame(
          fields: [], valid: false, error: '没有可解析的 HEX 字节。');
    }
    final bytes = input.bytes;
    var offset = 0;
    int? payloadLength;
    final parsed = <ParsedField>[];
    for (final field in template.fields) {
      var length = field.byteLength.clamp(1, 4096);
      if (field.kind == ProtocolFieldKind.payload && payloadLength != null) {
        length = payloadLength;
      }
      if (offset + length > bytes.length) {
        return ParsedFrame(
            fields: parsed,
            valid: false,
            error: '${field.name} 字节不足：需要 $length B。');
      }
      final chunk = bytes.sublist(offset, offset + length);
      offset += length;
      final value = _readInteger(chunk, field.byteOrder);
      if ((field.kind == ProtocolFieldKind.header ||
              field.kind == ProtocolFieldKind.trailer) &&
          field.valueHex.isNotEmpty) {
        final expectedInput = tryParseHexBytes(field.valueHex);
        if (!expectedInput.isValid) {
          return ParsedFrame(
              fields: parsed,
              valid: false,
              error: '${field.name} 的模板 HEX 无效：${expectedInput.error}');
        }
        final expected = expectedInput.bytes;
        if (!_sameBytes(chunk, expected)) {
          return ParsedFrame(
              fields: parsed,
              valid: false,
              error: '${field.name} 不匹配（期望 ${field.valueHex}）。');
        }
      }
      if (field.kind == ProtocolFieldKind.length) {
        payloadLength = value;
      }
      if (field.kind == ProtocolFieldKind.checksum) {
        final checked = bytes.sublist(0, offset - length);
        final expected = field.checksumAlgorithm == ChecksumAlgorithm.sum8
            ? _sum8(checked)
            : crc16Modbus(checked);
        if (value != expected) {
          return ParsedFrame(
              fields: parsed,
              valid: false,
              error:
                  '${field.name} 失败：期望 ${_formatInteger(expected, length, field.byteOrder)}。');
        }
      }
      parsed.add(ParsedField(field: field, bytes: chunk, value: value));
    }
    if (offset != bytes.length) {
      return ParsedFrame(
          fields: parsed,
          valid: false,
          error: '存在 ${bytes.length - offset} B 未定义尾部数据。');
    }
    return ParsedFrame(fields: parsed, valid: true);
  }

  static int _readInteger(List<int> bytes, ByteOrder order) {
    final input = order == ByteOrder.bigEndian ? bytes : bytes.reversed;
    return input.fold(0, (value, byte) => (value << 8) | byte);
  }

  static int _sum8(List<int> bytes) =>
      bytes.fold(0, (sum, byte) => (sum + byte) & 0xFF);

  static String _formatInteger(int value, int length, ByteOrder order) {
    final bytes = List<int>.generate(
        length, (index) => (value >> (8 * (length - index - 1))) & 0xFF);
    return (order == ByteOrder.bigEndian ? bytes : bytes.reversed)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }

  static bool _sameBytes(List<int> left, List<int> right) =>
      left.length == right.length &&
      List.generate(left.length, (index) => left[index] == right[index])
          .every((matches) => matches);
}
