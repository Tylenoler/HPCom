// HCOM 性能测试台 (HCOM Performance Test Bench)
//
// 用法（在 HCOM 项目根目录）：
//   dart run tool/perftest/perftest.dart
//   dart run tool/perftest/perftest.dart --writer COM29 --reader COM30
//   dart run tool/perftest/perftest.dart --quick
//
// 设计说明：
//  * 直接驱动真实 hcom-core.exe（NDJSON over stdio），不修改本体代码。
//  * 回环测试需要一对连通的串口（如虚拟串口对 COM29 <-> COM30）。
//  * 每项测试结束输出一张报告卡，最后输出总报告并落盘 Markdown。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'core_harness.dart';

// ============================================================
// 配置
// ============================================================
class Config {
  String writer = 'COM29';
  String reader = 'COM30';
  int baud = 115200;
  int frameBytes = 64;
  int throughputSeconds = 10;
  int latencySamples = 200;
  int timerIntervalMs = 20;
  int timerSamples = 100;
  int soakSeconds = 30;
  int soakStatusIntervalSeconds = 60;
  int reconnectIntervalSeconds = 0;
  int pingSamples = 300;
  bool quick = false;

  static Config parse(List<String> args) {
    final c = Config();
    String? val(String key) {
      final i = args.indexOf('--$key');
      if (i >= 0 && i + 1 < args.length) return args[i + 1];
      return null;
    }

    c.writer = val('writer') ?? c.writer;
    c.reader = val('reader') ?? c.reader;
    c.baud = int.tryParse(val('baud') ?? '') ?? c.baud;
    c.frameBytes = int.tryParse(val('frame') ?? '') ?? c.frameBytes;
    c.throughputSeconds =
        int.tryParse(val('throughput') ?? '') ?? c.throughputSeconds;
    c.latencySamples = int.tryParse(val('latency') ?? '') ?? c.latencySamples;
    c.timerSamples = int.tryParse(val('timer') ?? '') ?? c.timerSamples;
    c.soakSeconds = int.tryParse(val('soak') ?? '') ?? c.soakSeconds;
    c.soakStatusIntervalSeconds = int.tryParse(val('status-interval') ?? '') ??
        c.soakStatusIntervalSeconds;
    c.reconnectIntervalSeconds =
        int.tryParse(val('reconnect-interval') ?? '') ??
            c.reconnectIntervalSeconds;
    c.quick = args.contains('--quick');
    if (c.quick) {
      c.throughputSeconds = 3;
      c.latencySamples = 40;
      c.timerSamples = 40;
      c.soakSeconds = 6;
      c.soakStatusIntervalSeconds = 2;
      c.pingSamples = 60;
    }
    return c;
  }
}

// ============================================================
// 报告模型
// ============================================================
enum Status { pass, warn, fail, skip }

extension StatusX on Status {
  String get icon => switch (this) {
        Status.pass => '✅ 通过',
        Status.warn => '⚠️  警告',
        Status.fail => '❌ 失败',
        Status.skip => '⏭️  跳过',
      };
}

class Metric {
  Metric(this.name, this.value, [this.note]);
  final String name;
  final String value;
  final String? note;
}

class TestReport {
  TestReport(this.id, this.title, this.category);
  final String id;
  final String title;
  final String category;
  Status status = Status.skip;
  final List<Metric> metrics = <Metric>[];
  final List<String> notes = <String>[];
  Duration elapsed = Duration.zero;
  String verdict = '';

  void metric(String name, String value, [String? note]) =>
      metrics.add(Metric(name, value, note));

  void addMetric(Metric m) => metrics.add(m);

  void note(String s) => notes.add(s);

  void printReport() {
    const width = 74;
    String pad(String s) {
      final visible = s.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
      return s + ' ' * max(0, width - 4 - visible.length);
    }

    stdout.writeln('');
    stdout.writeln(
        '╭─ [$id] $title ${'─' * max(0, width - title.length - id.length - 7)}');
    stdout.writeln('│ 分类: $category');
    stdout.writeln(
        '│ 状态: ${status.icon}      耗时: ${(elapsed.inMicroseconds / 1000).toStringAsFixed(0)} ms');
    if (metrics.isNotEmpty) {
      stdout.writeln('│');
      stdout.writeln('│ 指标');
      for (final m in metrics) {
        final note = m.note == null ? '' : '   (${m.note})';
        stdout.writeln('│   ${pad('${m.name}  ${m.value}$note')}');
      }
    }
    if (notes.isNotEmpty) {
      stdout.writeln('│');
      for (final n in notes) {
        stdout.writeln('│  · $n');
      }
    }
    if (verdict.isNotEmpty) {
      stdout.writeln('│');
      stdout.writeln('│ 结论: $verdict');
    }
    stdout.writeln('╰${'─' * width}');
  }
}

// ============================================================
// 工具
// ============================================================
class ProcSample {
  ProcSample(this.workingSetBytes, this.cpuSeconds);
  final int workingSetBytes;
  final double cpuSeconds;
}

/// 采样某个进程的内存 / CPU 时间（Windows）
Future<ProcSample?> sampleProc(int pid) async {
  try {
    // 注意：不要在内层使用双引号——经 cmd.exe 会被吞掉导致解析失败。
    // 用两行输出代替 "a|b" 拼接。
    final r = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-Command',
          '\$p = Get-Process -Id $pid -ErrorAction Stop; '
              'Write-Output \$p.WorkingSet64; '
              'Write-Output \$p.TotalProcessorTime.TotalSeconds',
        ],
        runInShell: true);
    if (r.exitCode != 0) return null;
    final lines = r.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final ws = int.tryParse(lines[0]);
    final cpu = double.tryParse(lines[1]);
    if (ws == null || cpu == null) return null;
    return ProcSample(ws, cpu);
  } catch (_) {
    return null;
  }
}

String fmtBytes(num b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

double percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[idx].toDouble();
}

/// 定位 hcom-core.exe
String? locateCore() {
  const candidates = <String>[
    'core/target/release/hcom-core.exe',
    'core/target/debug/hcom-core.exe',
    'build/windows/x64/runner/Release/hcom-core.exe',
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

// ============================================================
// 测试项
// ============================================================

/// 按线路速率给批次写入定节奏（默认 90% 带宽），避免缓冲区无界堆积
Duration paceDelay(Config cfg, int batchBytes) {
  final bytesPerSec = cfg.baud / 10 * 0.9; // 8N1：10 bit/byte
  final us = (batchBytes / bytesPerSec * 1000000).round();
  return Duration(microseconds: us < 500 ? 500 : us);
}

/// T0 环境与握手
Future<TestReport> testEnv(CoreHarness core, Config cfg) async {
  final r = TestReport('T0', '环境与 Core 握手', '环境基线');
  final sw = Stopwatch()..start();
  final ready = await core.handshake();
  final ports = await core.scanPorts();
  sw.stop();

  r.metric('操作系统', Platform.operatingSystem, Platform.operatingSystemVersion);
  r.metric('CPU 核心数', '${Platform.numberOfProcessors}');
  r.metric('Core 协议版本', '${ready['protocolVersion']}');
  r.metric('Core 版本', '${ready['coreVersion']}');
  r.metric('Core PID', '${core.pid}');
  r.metric('枚举到串口数', '${ports.length}');
  for (final p in ports.take(6)) {
    r.metric('  · 端口', '${p['port']}', '${p['description'] ?? ''}');
  }
  final names = ports.map((p) => p['port']).toSet();
  if (!names.contains(cfg.writer)) {
    r.note('警告: 未枚举到 ${cfg.writer}');
  }
  if (!names.contains(cfg.reader)) {
    r.note('警告: 未枚举到 ${cfg.reader}');
  }
  final ok = ports.isNotEmpty &&
      names.contains(cfg.writer) &&
      names.contains(cfg.reader);
  r.status = ok ? Status.pass : Status.warn;
  r.verdict = ok ? '环境就绪，可用于回环测试' : '缺少回环所需的串口对，回环类测试将跳过';
  r.elapsed = sw.elapsed;
  return r;
}

/// T1 IPC 往返延迟（ping/pong）
Future<TestReport> testIpcPing(CoreHarness core, Config cfg) async {
  final r = TestReport('T1', 'Core IPC 往返延迟', '延迟');
  final sw = Stopwatch()..start();
  final samples = <int>[];
  for (var i = 0; i < cfg.pingSamples; i++) {
    final t0 = DateTime.now().microsecondsSinceEpoch;
    await core.sendAndWait('ping', const {}, (e) => e.event == 'pong');
    samples.add(DateTime.now().microsecondsSinceEpoch - t0);
  }
  sw.stop();
  samples.sort();
  final avg = samples.reduce((a, b) => a + b) / samples.length;
  r.metric('样本数', '${samples.length}');
  r.metric('平均', '${(avg / 1000).toStringAsFixed(3)} ms');
  r.metric(
      'P50', '${(percentile(samples, 0.50) / 1000).toStringAsFixed(3)} ms');
  r.metric(
      'P95', '${(percentile(samples, 0.95) / 1000).toStringAsFixed(3)} ms');
  r.metric(
      'P99', '${(percentile(samples, 0.99) / 1000).toStringAsFixed(3)} ms');
  r.metric('最大', '${(samples.last / 1000).toStringAsFixed(3)} ms');
  final p95 = percentile(samples, 0.95) / 1000;
  r.status = p95 < 20 ? Status.pass : (p95 < 50 ? Status.warn : Status.fail);
  r.verdict = p95 < 20 ? 'IPC 通道往返稳定' : 'IPC 往返偏高，需关注';
  r.elapsed = sw.elapsed;
  return r;
}

/// T2 端口扫描耗时
Future<TestReport> testScanPorts(CoreHarness core, Config cfg) async {
  final r = TestReport('T2', '串口扫描耗时', '延迟 / 稳定性');
  final sw = Stopwatch()..start();
  final n = cfg.quick ? 5 : 20;
  final samples = <int>[];
  for (var i = 0; i < n; i++) {
    final t0 = DateTime.now().microsecondsSinceEpoch;
    await core.scanPorts();
    samples.add(DateTime.now().microsecondsSinceEpoch - t0);
  }
  sw.stop();
  samples.sort();
  final avg = samples.reduce((a, b) => a + b) / samples.length;
  r.metric('样本数', '$n');
  r.metric('平均', '${(avg / 1000).toStringAsFixed(2)} ms');
  r.metric(
      'P95', '${(percentile(samples, 0.95) / 1000).toStringAsFixed(2)} ms');
  r.metric('最大', '${(samples.last / 1000).toStringAsFixed(2)} ms');
  r.status = avg / 1000 < 500 ? Status.pass : Status.warn;
  r.verdict = '扫描结果可直接驱动端口下拉刷新';
  r.elapsed = sw.elapsed;
  return r;
}

/// T3 打开 / 关闭端口耗时
Future<TestReport> testOpenClose(CoreHarness core, Config cfg) async {
  final r = TestReport('T3', '端口打开 / 关闭耗时', '延迟');
  final sw = Stopwatch()..start();
  final opens = <int>[];
  final closes = <int>[];
  final n = cfg.quick ? 2 : 5;
  try {
    for (var i = 0; i < n; i++) {
      opens.add(await core.openPort(cfg.writer, baudRate: cfg.baud));
      closes.add(await core.closePort());
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  } catch (e) {
    r.status = Status.skip;
    r.note('打开失败: $e');
    r.verdict = '端口被占用或不可用，跳过';
    r.elapsed = sw.elapsed;
    return r;
  }
  sw.stop();
  final oAvg = opens.reduce((a, b) => a + b) / opens.length;
  final cAvg = closes.reduce((a, b) => a + b) / closes.length;
  r.metric('打开次数', '$n');
  r.metric('打开平均', '${(oAvg / 1000).toStringAsFixed(1)} ms');
  r.metric('关闭平均', '${(cAvg / 1000).toStringAsFixed(1)} ms');
  r.metric('波特率', '${cfg.baud}');
  r.status = oAvg / 1000 < 2000 ? Status.pass : Status.warn;
  r.verdict = '连接状态机响应及时';
  r.elapsed = sw.elapsed;
  return r;
}

/// T4 回环吞吐与丢包
Future<TestReport> testLoopback(
    CoreHarness writer, CoreHarness reader, Config cfg) async {
  final r = TestReport('T4', '回环吞吐与丢包', '数据完整性 / 吞吐');
  writer.resetStats();
  reader.resetStats();

  final frame = buildFrame(0, cfg.frameBytes);
  const bw = 64;
  final batchBytes = bw * cfg.frameBytes;
  final sw = Stopwatch()..start();
  final deadline = DateTime.now().add(Duration(seconds: cfg.throughputSeconds));
  var framesQueued = 0;
  while (DateTime.now().isBefore(deadline)) {
    for (var i = 0; i < bw; i++) {
      writer.writeHex(frame);
      framesQueued++;
    }
    await Future<void>.delayed(paceDelay(cfg, batchBytes));
  }
  // 等待积压真正排空：TX 连续 1.5s 不增长即视为发完（最多再等 20s）
  var lastTx = writer.txBytes;
  var stableMs = 0;
  var drainTimedOut = false;
  final drainDeadline = DateTime.now().add(const Duration(seconds: 20));
  while (stableMs < 1500) {
    if (DateTime.now().isAfter(drainDeadline)) {
      drainTimedOut = true;
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (writer.txBytes == lastTx) {
      stableMs += 150;
    } else {
      stableMs = 0;
      lastTx = writer.txBytes;
    }
  }
  sw.stop();

  final secs = sw.elapsedMicroseconds / 1e6;
  final tx = writer.txBytes;
  final rx = reader.rxBytes;
  final lost = tx - rx;
  final lossRate = tx == 0 ? 0.0 : (lost / tx * 100);
  final throughput = rx / secs;

  r.metric('目标帧长', '${cfg.frameBytes} B');
  r.metric('波特率', '${cfg.baud}');
  r.metric('理论带宽上限', '${fmtBytes(cfg.baud / 10)}/s', '8N1');
  final queuedBytes = framesQueued * cfg.frameBytes;
  r.metric('排队指令数', '$framesQueued');
  r.metric('排队字节', fmtBytes(queuedBytes));
  r.metric('Core 实际 TX', fmtBytes(tx));
  final backlog = queuedBytes - tx;
  r.metric('发送积压(未发出)', fmtBytes(backlog > 0 ? backlog : 0),
      drainTimedOut ? '排空超时 20s' : null);
  r.metric('Core 接收 RX', fmtBytes(rx));
  r.metric('实测吞吐', '${fmtBytes(throughput)}/s');
  r.metric('丢包字节', fmtBytes(lost));
  r.metric('丢包率', '${lossRate.toStringAsFixed(4)} %');
  r.metric('接收事件数', '${reader.rxEvents}');
  r.metric('背压丢弃字节', fmtBytes(reader.droppedBytes));
  r.metric('背压事件数', '${reader.backpressureCount}');

  if (tx == 0 || rx == 0) {
    r.status = Status.skip;
    r.verdict = '回环链路无数据，无法判定（请确认端口对连通）';
  } else if (lost <= 0 && reader.droppedBytes == 0) {
    r.status = Status.pass;
    r.verdict = '零丢包，链路完整';
  } else if (lossRate < 0.01 && reader.droppedBytes == 0) {
    r.status = Status.warn;
    r.verdict = '微量丢包（${lossRate.toStringAsFixed(4)}%）';
  } else {
    r.status = Status.fail;
    r.verdict = '存在丢包或背压丢弃，需排查';
  }
  r.elapsed = sw.elapsed;
  return r;
}

/// T5 回环逐条延迟
Future<TestReport> testLatency(
    CoreHarness writer, CoreHarness reader, Config cfg) async {
  final r = TestReport('T5', '回环逐条延迟', '延迟');
  final samples = <int>[];
  final sw = Stopwatch()..start();
  final frame = buildFrame(1, 8); // 小帧，减少串行传输时间占比
  try {
    for (var i = 0; i < cfg.latencySamples; i++) {
      final f = reader.nextWhere(
          (e) => e.event == 'serial_data' && e.payload['direction'] == 'rx');
      final t0 = DateTime.now().microsecondsSinceEpoch;
      writer.writeHex(frame);
      await f;
      samples.add(DateTime.now().microsecondsSinceEpoch - t0);
    }
  } catch (e) {
    r.status = Status.skip;
    r.note('采样中断: $e');
    r.verdict = '链路不可用，跳过';
    r.elapsed = sw.elapsed;
    return r;
  }
  sw.stop();
  samples.sort();
  final avg = samples.reduce((a, b) => a + b) / samples.length;
  r.metric('样本数', '${samples.length}');
  r.metric('帧长', '8 B');
  r.metric('平均', '${(avg / 1000).toStringAsFixed(3)} ms');
  r.metric(
      'P50', '${(percentile(samples, 0.50) / 1000).toStringAsFixed(3)} ms');
  r.metric(
      'P95', '${(percentile(samples, 0.95) / 1000).toStringAsFixed(3)} ms');
  r.metric(
      'P99', '${(percentile(samples, 0.99) / 1000).toStringAsFixed(3)} ms');
  r.metric('最大', '${(samples.last / 1000).toStringAsFixed(3)} ms');
  final p95 = percentile(samples, 0.95) / 1000;
  r.status = p95 < 50 ? Status.pass : (p95 < 200 ? Status.warn : Status.fail);
  r.verdict = '端到端（发出 → 收到）延迟分布';
  r.elapsed = sw.elapsed;
  return r;
}

/// T6 定时发送精度（宿主侧调度）
Future<TestReport> testTimer(CoreHarness writer, Config cfg) async {
  final r = TestReport('T6', '定时发送调度精度', '时序精度');
  final stamps = <int>[];
  final sw = Stopwatch()..start();
  final completer = Completer<void>();
  var count = 0;
  final target = Duration(milliseconds: cfg.timerIntervalMs);
  final frame = buildFrame(2, 8);
  Timer.periodic(target, (timer) {
    stamps.add(DateTime.now().microsecondsSinceEpoch);
    writer.writeHex(frame);
    count++;
    if (count >= cfg.timerSamples) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    }
  });
  await completer.future.timeout(
    Duration(seconds: cfg.timerIntervalMs * cfg.timerSamples ~/ 1000 + 10),
  );
  sw.stop();

  final deltas = <int>[];
  for (var i = 1; i < stamps.length; i++) {
    deltas.add(stamps[i] - stamps[i - 1]);
  }
  deltas.sort();
  final targetUs = cfg.timerIntervalMs * 1000;
  final avg =
      deltas.isEmpty ? 0.0 : deltas.reduce((a, b) => a + b) / deltas.length;
  final maxDev =
      deltas.isEmpty ? 0 : deltas.map((d) => (d - targetUs).abs()).reduce(max);

  r.metric('目标间隔', '${cfg.timerIntervalMs} ms');
  r.metric('触发次数', '$count');
  r.metric('实际平均间隔', '${(avg / 1000).toStringAsFixed(3)} ms');
  r.metric('平均偏差', '${((avg - targetUs) / 1000).toStringAsFixed(3)} ms');
  r.metric('最大偏差', '${(maxDev / 1000).toStringAsFixed(3)} ms');
  r.metric(
      'P99 间隔', '${(percentile(deltas, 0.99) / 1000).toStringAsFixed(3)} ms');
  final maxDevMs = maxDev / 1000;
  r.status =
      maxDevMs < 5 ? Status.pass : (maxDevMs < 20 ? Status.warn : Status.fail);
  r.verdict = maxDevMs < 5 ? '调度精度良好' : '抖动偏大，高精度定时需专用调度';
  r.note('本项测的是宿主调用侧调度；Core 内的定时发送属于 Phase 4，尚未实现');
  r.elapsed = sw.elapsed;
  return r;
}

/// T7 资源占用（内存 / CPU）
Future<TestReport> testResources(
    CoreHarness writer, CoreHarness reader, Config cfg) async {
  final r = TestReport('T7', 'Core 资源占用', '资源');
  final sw = Stopwatch()..start();

  final idleW = await sampleProc(writer.pid);
  final idleR = await sampleProc(reader.pid);
  if (idleW == null || idleR == null) {
    r.status = Status.skip;
    r.note('无法采样进程资源（PowerShell 调用失败）');
    r.verdict = '跳过';
    r.elapsed = sw.elapsed;
    return r;
  }

  // 制造负载
  final t0 = DateTime.now();
  final c0 = idleW.cpuSeconds + idleR.cpuSeconds;
  final frame = buildFrame(3, cfg.frameBytes);
  while (DateTime.now().difference(t0) < const Duration(seconds: 3)) {
    for (var i = 0; i < 32; i++) {
      writer.writeHex(frame);
    }
    await Future<void>.delayed(paceDelay(cfg, 32 * cfg.frameBytes));
  }
  final wall = DateTime.now().difference(t0).inMilliseconds / 1000;
  final loadW = await sampleProc(writer.pid);
  final loadR = await sampleProc(reader.pid);
  sw.stop();

  if (loadW == null || loadR == null) {
    r.status = Status.skip;
    r.verdict = '负载期采样失败';
    r.elapsed = sw.elapsed;
    return r;
  }
  final c1 = loadW.cpuSeconds + loadR.cpuSeconds;
  final cpuPct = (c1 - c0) / wall * 100;

  r.metric('写端内存（空载）', fmtBytes(idleW.workingSetBytes));
  r.metric('读端内存（空载）', fmtBytes(idleR.workingSetBytes));
  r.metric('写端内存（负载）', fmtBytes(loadW.workingSetBytes));
  r.metric('读端内存（负载）', fmtBytes(loadR.workingSetBytes));
  r.metric('两 Core 合计 CPU', '${cpuPct.toStringAsFixed(1)} %', '单核口径');
  r.metric('CPU 核心数', '${Platform.numberOfProcessors}');
  r.status = cpuPct < 50 ? Status.pass : Status.warn;
  r.verdict = '两进程内存占用可控，CPU 随负载增长';
  r.elapsed = sw.elapsed;
  return r;
}

/// T8 持续运行、资源采样与可选的模拟断开/重连。
Future<TestReport> testSoak(
    CoreHarness writer, CoreHarness reader, Config cfg) async {
  final r = TestReport('T8', '连续运行稳定性', '稳定性');
  final sw = Stopwatch()..start();
  final memWriter = <int>[];
  final memReader = <int>[];
  final cpuPts = <double>[];
  final base = await sampleProc(writer.pid);
  if (base == null) {
    r.status = Status.skip;
    r.verdict = '无法采样，跳过';
    r.elapsed = sw.elapsed;
    return r;
  }

  var lastCpu = base.cpuSeconds;
  writer.resetStats();
  reader.resetStats();
  final frame = buildFrame(4, cfg.frameBytes);
  final startedAt = DateTime.now();
  final endAt = startedAt.add(Duration(seconds: cfg.soakSeconds));
  var lastSample = startedAt;
  var lastStatus = DateTime.fromMillisecondsSinceEpoch(0);
  var reconnects = 0;
  var nextReconnectAt = cfg.reconnectIntervalSeconds > 0
      ? startedAt.add(Duration(seconds: cfg.reconnectIntervalSeconds))
      : endAt;
  var peak = base.workingSetBytes;
  final rssBase = base.workingSetBytes;
  final statusFile = File('tool/perftest/reports/soak-status.json');
  statusFile.parent.createSync(recursive: true);

  Future<void> writeStatus(String state, {String? failure}) async {
    final now = DateTime.now();
    await statusFile.writeAsString(jsonEncode(<String, Object?>{
      'state': state,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'updatedAt': now.toUtc().toIso8601String(),
      'targetSeconds': cfg.soakSeconds,
      'elapsedSeconds': now.difference(startedAt).inSeconds,
      'writerPid': writer.pid,
      'readerPid': reader.pid,
      'writerAlive': writer.isAlive,
      'readerAlive': reader.isAlive,
      'writerMemoryBytes': memWriter.isEmpty ? rssBase : memWriter.last,
      'readerMemoryBytes': memReader.isEmpty ? null : memReader.last,
      'peakWriterMemoryBytes': peak,
      'writerTxBytes': writer.txBytes,
      'writerRxBytes': writer.rxBytes,
      'readerRxBytes': reader.rxBytes,
      'droppedBytes': reader.droppedBytes,
      'errorCount': writer.errorCount + reader.errorCount,
      'reconnects': reconnects,
      if (failure != null) 'failure': failure,
    }));
  }

  await writeStatus('running');
  try {
    while (DateTime.now().isBefore(endAt)) {
      for (var i = 0; i < 24; i++) {
        writer.writeHex(frame);
      }
      await Future<void>.delayed(paceDelay(cfg, 24 * cfg.frameBytes));
      if (DateTime.now().isAfter(nextReconnectAt)) {
        // Let the bounded Core command queue drain before disconnecting. The
        // receiver closes first so no fresh RX events arrive mid-transition.
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await reader.closePort();
        await writer.closePort();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await reader.openPort(cfg.reader, baudRate: cfg.baud);
        await writer.openPort(cfg.writer, baudRate: cfg.baud);
        reconnects++;
        nextReconnectAt =
            DateTime.now().add(Duration(seconds: cfg.reconnectIntervalSeconds));
      }
      if (DateTime.now().difference(lastSample).inMilliseconds >= 2000) {
        final writerSample = await sampleProc(writer.pid);
        if (writerSample != null) {
          memWriter.add(writerSample.workingSetBytes);
          peak = max(peak, writerSample.workingSetBytes);
          final seconds =
              DateTime.now().difference(lastSample).inMilliseconds / 1000;
          cpuPts.add((writerSample.cpuSeconds - lastCpu) / seconds * 100);
          lastCpu = writerSample.cpuSeconds;
        }
        final readerSample = await sampleProc(reader.pid);
        if (readerSample != null) memReader.add(readerSample.workingSetBytes);
        lastSample = DateTime.now();
      }
      if (DateTime.now().difference(lastStatus).inSeconds >=
          cfg.soakStatusIntervalSeconds) {
        await writeStatus('running');
        lastStatus = DateTime.now();
      }
    }
  } catch (error) {
    await writeStatus('failed', failure: error.toString());
    rethrow;
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  sw.stop();

  final memEnd = memWriter.isEmpty ? rssBase : memWriter.last;
  final growth = rssBase == 0 ? 0.0 : (memEnd - rssBase) / rssBase * 100;
  final avgCpu = cpuPts.isEmpty
      ? 0.0
      : cpuPts.reduce((left, right) => left + right) / cpuPts.length;
  final alive = writer.isAlive && reader.isAlive;
  r.metric('持续时间', '${cfg.soakSeconds} s');
  r.metric('起始内存', fmtBytes(rssBase));
  r.metric('结束内存', fmtBytes(memEnd));
  r.metric('峰值内存', fmtBytes(peak));
  r.metric('内存增长', '${growth.toStringAsFixed(2)} %');
  r.metric('平均 CPU', '${avgCpu.toStringAsFixed(1)} %');
  r.metric(
      '写端 RX/TX', '${fmtBytes(writer.rxBytes)} / ${fmtBytes(writer.txBytes)}');
  r.metric('读端 RX', fmtBytes(reader.rxBytes));
  r.metric('读端丢包字节', fmtBytes(reader.droppedBytes));
  r.metric('模拟断开/重连', '$reconnects 次');
  r.metric('进程存活', alive ? '是' : '否');

  if (!alive) {
    r.status = Status.fail;
    r.verdict = 'Core 进程意外退出';
  } else if (growth.abs() < 5) {
    r.status = Status.pass;
    r.verdict = '无显著内存增长，运行稳定';
  } else {
    r.status = Status.warn;
    r.verdict = '内存增长 ${growth.toStringAsFixed(1)}%，建议延长观察';
  }
  r.note('状态每 ${cfg.soakStatusIntervalSeconds} 秒写入 soak-status.json。');
  r.elapsed = sw.elapsed;
  await writeStatus(r.status == Status.fail ? 'failed' : 'completed',
      failure: r.status == Status.fail ? r.verdict : null);
  return r;
}

// ============================================================
// 主流程
// ============================================================
Future<int> main(List<String> args) async {
  final cfg = Config.parse(args);
  final corePath = locateCore();

  stdout.writeln('');
  stdout.writeln(
      '══════════════════════════════════════════════════════════════════════');
  stdout.writeln('  HCOM 性能测试台 (Performance Test Bench)');
  stdout.writeln(
      '══════════════════════════════════════════════════════════════════════');
  stdout.writeln('  模式      : ${cfg.quick ? '快速' : '完整'}');
  stdout.writeln('  回环端口  : ${cfg.writer} <-> ${cfg.reader}');
  stdout.writeln('  波特率    : ${cfg.baud}');
  if (corePath == null) {
    stdout.writeln('');
    stdout.writeln('  ❌ 未找到 hcom-core.exe。请先构建:');
    stdout
        .writeln('     cargo build --release --manifest-path core/Cargo.toml');
    return 2;
  }
  stdout.writeln('  Core      : $corePath');
  stdout.writeln(
      '══════════════════════════════════════════════════════════════════════');

  final reports = <TestReport>[];

  // ---- 单 Core 测试 ----
  CoreHarness? main1;
  try {
    main1 = await CoreHarness.start(corePath);
  } catch (e) {
    stdout.writeln('❌ 无法启动 hcom-core.exe: $e');
    return 3;
  }

  Future<void> run(Future<TestReport> Function() f) async {
    try {
      final rep = await f();
      reports.add(rep);
      rep.printReport();
    } catch (e) {
      final rep = TestReport('??', '未捕获异常', '-');
      rep.status = Status.fail;
      rep.note('$e');
      reports.add(rep);
      rep.printReport();
    }
  }

  await run(() => testEnv(main1!, cfg));
  await run(() => testIpcPing(main1!, cfg));
  await run(() => testScanPorts(main1!, cfg));
  await run(() => testOpenClose(main1!, cfg));
  await main1.stop();
  main1 = null;

  // ---- 回环测试（两个 Core）----
  CoreHarness? w;
  CoreHarness? rd;
  var loopbackReady = false;
  try {
    w = await CoreHarness.start(corePath);
    rd = await CoreHarness.start(corePath);
    await w.handshake();
    await rd.handshake();
    await w.openPort(cfg.writer, baudRate: cfg.baud);
    await rd.openPort(cfg.reader, baudRate: cfg.baud);
    loopbackReady = true;
  } catch (e) {
    stdout.writeln('');
    stdout.writeln('⚠️  回环链路不可用（$e）');
    stdout.writeln('    → 请确认应用已关闭，且 ${cfg.writer}/${cfg.reader} 未被占用。');
  }

  if (loopbackReady) {
    await run(() => testLoopback(w!, rd!, cfg));
    await run(() => testLatency(w!, rd!, cfg));
    await run(() => testTimer(w!, cfg));
    await run(() => testResources(w!, rd!, cfg));
    await run(() => testSoak(w!, rd!, cfg));
    try {
      await w!.closePort();
      await rd!.closePort();
    } catch (_) {}
  } else {
    for (final spec in <List<String>>[
      ['T4', '回环吞吐与丢包', '数据完整性 / 吞吐'],
      ['T5', '回环逐条延迟', '延迟'],
      ['T6', '定时发送调度精度', '时序精度'],
      ['T7', 'Core 资源占用', '资源'],
      ['T8', '连续运行稳定性', '稳定性'],
    ]) {
      final rep = TestReport(spec[0], spec[1], spec[2]);
      rep.status = Status.skip;
      rep.verdict = '回环链路不可用（端口对未释放）';
      reports.add(rep);
      rep.printReport();
    }
  }
  await w?.stop();
  await rd?.stop();

  // ---- 总报告 ----
  final passed = reports.where((r) => r.status == Status.pass).length;
  final warned = reports.where((r) => r.status == Status.warn).length;
  final failed = reports.where((r) => r.status == Status.fail).length;
  final skipped = reports.where((r) => r.status == Status.skip).length;

  stdout.writeln('');
  stdout.writeln(
      '══════════════════════════════════════════════════════════════════════');
  stdout.writeln('  总报告');
  stdout.writeln(
      '══════════════════════════════════════════════════════════════════════');
  for (final r in reports) {
    final line = '  ${r.status.icon.padRight(8)} [${r.id}] ${r.title}';
    final ms = (r.elapsed.inMicroseconds / 1000).toStringAsFixed(0);
    stdout.writeln('${line.padRight(56)}$ms ms');
  }
  stdout.writeln(
      '──────────────────────────────────────────────────────────────────────');
  stdout.writeln('  通过 $passed · 警告 $warned · 失败 $failed · 跳过 $skipped');
  stdout.writeln(
      '  总耗时 ${(reports.fold<int>(0, (a, r) => a + r.elapsed.inMilliseconds) / 1000).toStringAsFixed(1)} s');
  stdout.writeln(
      '══════════════════════════════════════════════════════════════════════');
  stdout.writeln('');

  // 落盘 Markdown
  try {
    final dir = Directory('tool/perftest/reports')..createSync(recursive: true);
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .substring(0, 19);
    final f = File('${dir.path}/perftest-$ts.md');
    f.writeAsStringSync(buildMarkdown(reports, cfg, corePath));
    stdout.writeln('  📄 报告已保存: ${f.path}');
    stdout.writeln('');
  } catch (e) {
    stdout.writeln('  ⚠️ 报告落盘失败: $e');
  }

  if (failed > 0) return 1;
  return 0;
}

String buildMarkdown(List<TestReport> reports, Config cfg, String corePath) {
  final b = StringBuffer();
  b.writeln('# HCOM 性能测试报告');
  b.writeln();
  b.writeln('- 时间: ${DateTime.now().toIso8601String()}');
  b.writeln('- 模式: ${cfg.quick ? '快速' : '完整'}');
  b.writeln('- 回环端口: ${cfg.writer} <-> ${cfg.reader} @ ${cfg.baud}');
  b.writeln('- Core: `$corePath`');
  b.writeln(
      '- 平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  b.writeln('- CPU 核心: ${Platform.numberOfProcessors}');
  b.writeln();
  b.writeln('## 结果总览');
  b.writeln();
  b.writeln('| 项 | 名称 | 分类 | 状态 | 耗时 |');
  b.writeln('|----|------|------|------|------|');
  for (final r in reports) {
    b.writeln('| ${r.id} | ${r.title} | ${r.category} | ${r.status.icon} | '
        '${(r.elapsed.inMicroseconds / 1000).toStringAsFixed(0)} ms |');
  }
  b.writeln();
  for (final r in reports) {
    b.writeln('## [${r.id}] ${r.title}');
    b.writeln();
    b.writeln('- 分类: ${r.category}');
    b.writeln('- 状态: ${r.status.icon}');
    b.writeln(
        '- 耗时: ${(r.elapsed.inMicroseconds / 1000).toStringAsFixed(0)} ms');
    if (r.metrics.isNotEmpty) {
      b.writeln();
      b.writeln('| 指标 | 值 | 备注 |');
      b.writeln('|------|----|------|');
      for (final m in r.metrics) {
        b.writeln('| ${m.name} | ${m.value} | ${m.note ?? ''} |');
      }
    }
    for (final n in r.notes) {
      b.writeln();
      b.writeln('> $n');
    }
    if (r.verdict.isNotEmpty) {
      b.writeln();
      b.writeln('**结论**: ${r.verdict}');
    }
    b.writeln();
  }
  return b.toString();
}
