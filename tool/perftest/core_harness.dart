// HCOM 性能测试台 · Core 驱动层
//
// 通过 NDJSON over stdio 驱动 hcom-core.exe（协议见 protocol/stdio-ndjson.md）。
// 本文件只依赖 dart:io / dart:convert，不引入任何第三方包，也不修改本体代码。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条来自 Core 的协议事件
class CoreEvent {
  CoreEvent(this.event, this.payload, this.recvMicros);

  final String event;
  final Map<String, dynamic> payload;

  /// 本进程解析到该事件的时刻（微秒）
  final int recvMicros;
}

/// 单个 hcom-core 进程的最小驱动
class CoreHarness {
  CoreHarness._(this._proc, this.exePath);

  final Process _proc;
  final String exePath;
  final StringBuffer _buf = StringBuffer();
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast();

  /// 人类可读诊断（Core 的 stderr）
  final List<String> stderrLog = <String>[];

  // ---- 累计统计（可由测试重置）----
  int rxBytes = 0;
  int txBytes = 0;
  int rxEvents = 0;
  int droppedBytes = 0;
  int backpressureCount = 0;
  int errorCount = 0;

  Stream<CoreEvent> get events => _events.stream;
  int get pid => _proc.pid;

  bool _exited = false;

  /// 进程是否仍在运行（修复：不能依赖 exitCode == null，新版 SDK 中它非空）
  bool get isAlive => !_exited;

  static Future<CoreHarness> start(String exePath) async {
    final proc = await Process.start(
      exePath,
      const <String>[],
      workingDirectory: File(exePath).parent.path,
    );
    final h = CoreHarness._(proc, exePath);
    unawaited(proc.exitCode.then((_) => h._exited = true));
    // stdin sink 在子进程退出后会抛 SocketException，必须吞掉，否则炸整个程序
    unawaited(proc.stdin.done.catchError((Object _) {}));
    proc.stdout.transform(utf8.decoder).listen(h._onStdout);
    proc.stderr.transform(utf8.decoder).listen((String s) {
      for (final line in s.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) h.stderrLog.add(t);
      }
    });
    return h;
  }

  void _onStdout(String chunk) {
    _buf.write(chunk);
    var text = _buf.toString();
    while (true) {
      final idx = text.indexOf('\n');
      if (idx < 0) break;
      final line = text.substring(0, idx).trim();
      text = text.substring(idx + 1);
      if (line.isEmpty) continue;
      final recv = DateTime.now().microsecondsSinceEpoch;
      Map<String, dynamic> map;
      try {
        map = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue; // 非协议行，忽略
      }
      final ev = CoreEvent(
        (map['event'] as String?) ?? '',
        (map['payload'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{},
        recv,
      );
      _accumulate(ev);
      _events.add(ev);
    }
    _buf.clear();
    _buf.write(text);
  }

  void _accumulate(CoreEvent ev) {
    switch (ev.event) {
      case 'serial_data':
        final dir = ev.payload['direction'];
        final n = hexByteCount(ev.payload['bytes']);
        if (dir == 'rx') {
          rxBytes += n;
          rxEvents++;
        } else {
          txBytes += n;
        }
        final dropped = ev.payload['droppedBytes'];
        // Core v2 reports a monotonic cumulative counter. Summing repeated
        // snapshots would turn one loss incident into many fictional losses.
        if (dropped is num && dropped >= droppedBytes) {
          droppedBytes = dropped.toInt();
        }
      case 'error':
        errorCount++;
        final code = ev.payload['code'];
        if (code == 'backpressure') backpressureCount++;
    }
  }

  void resetStats() {
    rxBytes = 0;
    txBytes = 0;
    rxEvents = 0;
    droppedBytes = 0;
    backpressureCount = 0;
    errorCount = 0;
  }

  void send(String command,
      [Map<String, dynamic> payload = const <String, dynamic>{}]) {
    if (_exited) return; // 进程已退出，静默丢弃，避免写已关闭管道
    try {
      _proc.stdin.writeln(jsonEncode(<String, dynamic>{
        'command': command,
        'payload': payload,
      }));
    } catch (_) {
      // 管道已关闭，忽略
    }
  }

  /// 订阅下一条满足条件的事件（务必先调用本方法，再 send）
  Future<CoreEvent> nextWhere(
    bool Function(CoreEvent) test, {
    Duration timeout = const Duration(seconds: 6),
  }) {
    return _events.stream.firstWhere(test).timeout(
          timeout,
          onTimeout: () => throw TimeoutException('等待 Core 事件超时'),
        );
  }

  /// 发送并等待某个事件
  Future<CoreEvent> sendAndWait(
    String command,
    Map<String, dynamic> payload,
    bool Function(CoreEvent) test, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final f = nextWhere(test, timeout: timeout);
    send(command, payload);
    return f;
  }

  /// 握手：hello -> ready
  Future<Map<String, dynamic>> handshake() async {
    final ev = await sendAndWait(
      'hello',
      <String, dynamic>{'client': 'perftest', 'protocolVersion': 2},
      (e) => e.event == 'ready',
    );
    return ev.payload;
  }

  Future<List<Map<String, dynamic>>> scanPorts() async {
    final ev = await sendAndWait(
      'scan_ports',
      const <String, dynamic>{},
      (e) => e.event == 'ports',
    );
    final list = ev.payload['ports'];
    if (list is List) {
      return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
    }
    return const <Map<String, dynamic>>[];
  }

  Future<int> openPort(
    String port, {
    int baudRate = 115200,
    int dataBits = 8,
    int stopBits = 1,
    String parity = 'none',
    String flowControl = 'none',
  }) async {
    final t0 = DateTime.now().microsecondsSinceEpoch;
    final ev = await sendAndWait(
      'open_port',
      <String, dynamic>{
        'port': port,
        'baudRate': baudRate,
        'dataBits': dataBits,
        'stopBits': stopBits,
        'parity': parity,
        'flowControl': flowControl,
      },
      (e) =>
          e.event == 'connection_state' &&
          (e.payload['state'] == 'connected' || e.payload['state'] == 'error'),
      timeout: const Duration(seconds: 8),
    );
    final t1 = DateTime.now().microsecondsSinceEpoch;
    if (ev.payload['state'] != 'connected') {
      throw StateError('打开 $port 失败: ${ev.payload}');
    }
    return t1 - t0;
  }

  Future<int> openMonitor(
    String port,
    String virtualPort, {
    int baudRate = 115200,
    int dataBits = 8,
    int stopBits = 1,
    String parity = 'none',
    String flowControl = 'none',
  }) async {
    final t0 = DateTime.now().microsecondsSinceEpoch;
    final ev = await sendAndWait(
      'open_monitor',
      <String, dynamic>{
        'port': port,
        'virtualPort': virtualPort,
        'baudRate': baudRate,
        'dataBits': dataBits,
        'stopBits': stopBits,
        'parity': parity,
        'flowControl': flowControl,
      },
      (e) =>
          e.event == 'connection_state' &&
          (e.payload['state'] == 'connected' || e.payload['state'] == 'error'),
      timeout: const Duration(seconds: 8),
    );
    final t1 = DateTime.now().microsecondsSinceEpoch;
    if (ev.payload['state'] != 'connected') {
      throw StateError('启动旁路监听 $port → $virtualPort 失败: ${ev.payload}');
    }
    return t1 - t0;
  }

  Future<int> closePort() async {
    final t0 = DateTime.now().microsecondsSinceEpoch;
    await sendAndWait(
      'close_port',
      const <String, dynamic>{},
      (e) =>
          e.event == 'connection_state' && e.payload['state'] == 'disconnected',
      timeout: const Duration(seconds: 8),
    );
    final t1 = DateTime.now().microsecondsSinceEpoch;
    return t1 - t0;
  }

  void writeHex(String hex) =>
      send('write_data', <String, dynamic>{'bytes': hex});

  Future<void> stop() async {
    send('close_port');
    try {
      await _proc.stdin.close();
    } catch (_) {}
    try {
      await _proc.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      try {
        _proc.kill();
      } catch (_) {}
    } catch (_) {}
    try {
      await _events.close();
    } catch (_) {}
  }
}

/// "AA 55 01" -> 3
int hexByteCount(Object? s) {
  if (s is! String || s.isEmpty) return 0;
  final compact = s.replaceAll(RegExp(r'\s'), '');
  return compact.length ~/ 2;
}

/// 生成带序号与填充的 HEX 帧，长度约 [targetBytes]
String buildFrame(int seq, int targetBytes) {
  final body = <int>[0xAA, 0x55, (seq >> 8) & 0xFF, seq & 0xFF];
  var i = 0;
  while (body.length < targetBytes) {
    body.add(0x30 + (i % 10));
    i++;
  }
  if (body.length > targetBytes) body.removeRange(targetBytes, body.length);
  return body
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
