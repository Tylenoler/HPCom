import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../core/backend_bridge.dart';
import '../models/frame_protocol.dart';
import '../models/log_copy.dart';
import '../models/log_export.dart';
import '../models/receive_framer.dart';
import '../models/serial_entry.dart';
import '../models/time_zone.dart';
import '../theme/hcom_theme.dart';

enum SendMode { sequence, loop, trigger, periodic }

enum SendInputFormat { hex, plainText }

enum PacketSuffix { none, cr, crlf, lf }

extension PacketSuffixDetails on PacketSuffix {
  String get label => switch (this) {
        PacketSuffix.none => '无',
        PacketSuffix.cr => r'+ \r',
        PacketSuffix.crlf => r'+ \r\n',
        PacketSuffix.lf => r'+ \n',
      };

  String get hex => switch (this) {
        PacketSuffix.none => '',
        PacketSuffix.cr => '0D',
        PacketSuffix.crlf => '0D 0A',
        PacketSuffix.lf => '0A',
      };
}

const _queueDeleteDoubleClickWindow = Duration(milliseconds: 450);
const _minimumAppWidthForQueueEditor = 600.0;
const _sendFormatSyncWindow = Duration(milliseconds: 1500);

class _QueuedCommand {
  _QueuedCommand({
    required this.name,
    required this.hex,
    this.packetSuffix = PacketSuffix.none,
  });

  String name;
  String hex;
  bool enabled = true;
  int delayMilliseconds = 0;
  PacketSuffix packetSuffix;

  String get wireHex => _appendPacketSuffix(hex, packetSuffix);
}

String _appendPacketSuffix(String bytes, PacketSuffix suffix) {
  final base = bytes.trim();
  if (base.isEmpty) return suffix.hex;
  return suffix.hex.isEmpty ? base : '$base ${suffix.hex}';
}

class _StartupSettings {
  const _StartupSettings({
    required this.timeZoneOffsetMinutes,
    required this.leftDockExpanded,
    required this.rightDockExpanded,
    required this.queueExpanded,
    required this.startupRealtimeLoggingEnabled,
    required this.isDark,
  });

  final int timeZoneOffsetMinutes;
  final bool leftDockExpanded;
  final bool rightDockExpanded;
  final bool queueExpanded;
  final bool startupRealtimeLoggingEnabled;
  final bool isDark;
}

class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen({
    super.key,
    required this.isDark,
    required this.onThemeChanged,
    required this.onStartupThemeChanged,
  });

  final bool isDark;
  final VoidCallback onThemeChanged;
  final ValueChanged<bool> onStartupThemeChanged;

  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends State<WorkbenchScreen>
    with TickerProviderStateMixin {
  final _bridge = BackendBridge();
  final _commandController = TextEditingController();
  final _periodicIntervalController = TextEditingController(text: '1000');
  final _queueNameController = TextEditingController(text: '默认队列');
  final _streamController = ScrollController();
  late final StreamSubscription<Map<String, dynamic>> _eventSubscription;
  late final AnimationController _connectionPulseController;
  late final AnimationController _sendPanelFadeController;
  late List<SerialEntry> _entries;
  final Map<SerialEntry, ParsedFrame> _parsedEntries = {};
  final List<SerialEntry> _pendingEntries = [];
  Timer? _entryFlushTimer;
  List<_SerialPort> _ports = const [];
  SendMode? _sendMode;
  SendInputFormat _sendInputFormat = SendInputFormat.hex;
  SendInputFormat _receiveInputFormat = SendInputFormat.hex;
  ReceiveFramingConfig _receiveFramingConfig = const ReceiveFramingConfig();
  final ReceiveFramer _receiveFramer = ReceiveFramer();
  FrameTemplate _frameTemplate = FrameTemplate.standard();
  PacketSuffix _sendPacketSuffix = PacketSuffix.none;
  DateTime? _lastSendFormatToggleAt;
  int _sendFormatToggleCount = 0;
  bool _formatsLinked = false;
  final List<_QueuedCommand> _queue = [
    _QueuedCommand(
      name: '心跳',
      hex: 'AA 55 A0 00 00 00 00 00 00 00 00 00',
    ),
    _QueuedCommand(
      name: '查询状态',
      hex: 'AA 55 01 01 04 00 41 42 20 1A',
    ),
  ];
  bool _connected = false;
  bool _connecting = false;
  bool _portConfigurationExpanded = true;
  bool _sendPanelExpanded = true;
  bool _periodicSending = false;
  bool _queueSending = false;
  int _queueRunToken = 0;
  Timer? _notificationTimer;
  Timer? _queueDeleteTimer;
  _QueuedCommand? _armedQueueDelete;
  String? _notificationMessage;
  bool _notificationHovered = false;
  String? _selectedLogText;
  bool _showLineNumbers = false;
  LogFileFormat? _realtimeLogFormat;
  String? _realtimeLogPath;
  bool _startupRealtimeLoggingEnabled = false;
  Future<void> _realtimeWriteChain = Future.value();
  int _timeZoneOffsetMinutes = defaultTimeZoneOffsetMinutes;
  _SerialPort? _selectedPort;
  String _baudRate = '115200';
  String _dataBits = '8';
  String _stopBits = '1';
  String _parity = '无 None';
  String _flowControl = '无';
  int _leftRailIndex = 0;
  int _rightRailIndex = -1;
  bool _fieldPanelOpen = false;
  bool _integrityPanelVisible = false;
  bool _leftRailExpanded = true;
  bool _rightRailExpanded = true;
  bool _queuePanelExpanded = false;

  @override
  void initState() {
    super.initState();
    _entries = [];
    _connectionPulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _sendPanelFadeController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200), value: 1);
    _eventSubscription = _bridge.events.listen(_consumeCoreEvent);
    unawaited(_bridge.start());
    unawaited(_loadStartupPreferences());
  }

  @override
  void dispose() {
    if (_periodicSending) _bridge.send('stop_periodic');
    _queueRunToken++;
    _notificationTimer?.cancel();
    _queueDeleteTimer?.cancel();
    _entryFlushTimer?.cancel();
    _eventSubscription.cancel();
    _connectionPulseController.dispose();
    _sendPanelFadeController.dispose();
    _commandController.dispose();
    _periodicIntervalController.dispose();
    _queueNameController.dispose();
    _streamController.dispose();
    unawaited(_bridge.dispose());
    super.dispose();
  }

  void _showIntegrityPanel() {
    setState(() {
      _fieldPanelOpen = false;
      _rightRailIndex = 1;
      _integrityPanelVisible = true;
    });
  }

  void _minimizeIntegrityPanel() {
    setState(() {
      _integrityPanelVisible = false;
      _rightRailIndex = -1;
    });
  }

  void _fillSendInputFromIntegrityPanel(String frame) {
    setState(() {
      _commandController.text = frame;
      _sendInputFormat = SendInputFormat.hex;
    });
    _showMessage('已将完整帧填入发送输入框');
  }

  void _consumeCoreEvent(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is! Map) return;
    switch (event['event']) {
      case 'ports':
        final rawPorts = payload['ports'];
        if (rawPorts is! List) return;
        final ports = rawPorts
            .whereType<Map>()
            .map(_SerialPort.fromCore)
            .whereType<_SerialPort>()
            .toList();
        final retained =
            ports.where((port) => port.port == _selectedPort?.port);
        setState(() {
          _ports = ports;
          _selectedPort = retained.isNotEmpty
              ? retained.first
              : (ports.isEmpty ? null : ports.first);
        });
      case 'connection_state':
        final state = payload['state'];
        if (state is! String) return;
        final wasConnected = _connected;
        setState(() {
          _connecting = state == 'connecting';
          _connected = state == 'connected';
        });
        if (!_connected && wasConnected) _stopPeriodicSend();
        if (_connected && !wasConnected) {
          _connectionPulseController.forward(from: 0);
          _showMessage('已连接 ${payload['port'] ?? _selectedPort?.port ?? '串口'}');
        }
      case 'periodic_state':
        final active = payload['active'];
        if (active is bool && active != _periodicSending && mounted) {
          setState(() => _periodicSending = active);
        }
      case 'serial_data':
        final bytes = payload['bytes'];
        if (bytes is! String) return;
        final direction = payload['direction'] == 'tx'
            ? SerialDirection.tx
            : SerialDirection.rx;
        final receivedAt =
            DateTime.tryParse(payload['timestamp']?.toString() ?? '') ??
                DateTime.now();
        final entries = direction == SerialDirection.tx
            ? [
                SerialEntry(
                    direction: direction,
                    timestamp: receivedAt,
                    hex: bytes,
                    label: 'Core')
              ]
            : _receiveFramer
                .addHex(bytes, receivedAt)
                .map((frame) => SerialEntry(
                      direction: direction,
                      timestamp: frame.timestamp,
                      hex: frame.hex,
                      label: 'Core',
                    ))
                .toList();
        if (entries.isEmpty) return;
        _queueIncomingEntries(entries);
      case 'error':
        final message = payload['message'];
        if (message is String && message.isNotEmpty) _showMessage(message);
    }
  }

  void _queueIncomingEntries(Iterable<SerialEntry> entries) {
    _pendingEntries.addAll(entries);
    for (final entry in entries) {
      _appendRealtimeLog(entry);
    }
    _entryFlushTimer ??= Timer(
      const Duration(milliseconds: 33),
      _flushIncomingEntries,
    );
  }

  void _flushIncomingEntries() {
    _entryFlushTimer = null;
    if (!mounted || _pendingEntries.isEmpty) return;
    final incoming = List<SerialEntry>.of(_pendingEntries);
    _pendingEntries.clear();
    final followLatest = !_streamController.hasClients ||
        _streamController.position.maxScrollExtent -
                _streamController.position.pixels <
            48;
    setState(() => _appendEntries(incoming));
    if (followLatest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_streamController.hasClients) {
          _streamController.jumpTo(_streamController.position.maxScrollExtent);
        }
      });
    }
  }

  void _appendEntries(Iterable<SerialEntry> entries) {
    final parser = ProtocolFrameParser(_frameTemplate);
    for (final entry in entries) {
      _entries.add(entry);
      _parsedEntries[entry] = parser.parseHex(entry.hex);
    }
    final overflow = _entries.length - 5000;
    if (overflow > 0) {
      final removed = _entries.sublist(0, overflow);
      _entries.removeRange(0, overflow);
      for (final entry in removed) {
        _parsedEntries.remove(entry);
      }
    }
  }

  void _setFrameTemplate(FrameTemplate template) {
    _frameTemplate = template;
    final parser = ProtocolFrameParser(template);
    _parsedEntries
      ..clear()
      ..addEntries({
        for (final entry in _entries) entry: parser.parseHex(entry.hex),
      }.entries);
  }

  void _showMessage(String message) {
    _notificationTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _notificationMessage = message;
      _notificationHovered = false;
    });
    _notificationTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notificationMessage = null);
    });
  }

  Future<void> _loadStartupPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    final offset = preferences.getInt('displayTimeZoneOffsetMinutes');
    final shouldResumeRealtimeLogging =
        preferences.getBool('startupRealtimeLoggingEnabled') ?? false;
    final previousRealtimePath = preferences.getString('lastRealtimeLogPath');
    final previousRealtimeFormat =
        _logFileFormatFromName(preferences.getString('lastRealtimeLogFormat'));
    if (!mounted) return;
    setState(() {
      if (offset != null && availableTimeZoneOffsets.contains(offset)) {
        _timeZoneOffsetMinutes = offset;
      }
      _leftRailExpanded =
          preferences.getBool('startupLeftDockExpanded') ?? true;
      _rightRailExpanded =
          preferences.getBool('startupRightDockExpanded') ?? true;
      _queuePanelExpanded =
          preferences.getBool('startupQueueExpanded') ?? false;
      _startupRealtimeLoggingEnabled = shouldResumeRealtimeLogging;
    });
    if (shouldResumeRealtimeLogging &&
        previousRealtimePath != null &&
        previousRealtimeFormat != null) {
      await _resumeRealtimeLog(previousRealtimePath, previousRealtimeFormat);
    }
  }

  LogFileFormat? _logFileFormatFromName(String? value) {
    for (final format in LogFileFormat.values) {
      if (format.name == value) return format;
    }
    return null;
  }

  Future<void> _showSettings() async {
    final settings = await _showContainerTransformDialog<_StartupSettings>(
      context: context,
      alignment: Alignment.topRight,
      builder: (context) {
        var draftOffset = _timeZoneOffsetMinutes;
        var draftLeftDockExpanded = _leftRailExpanded;
        var draftRightDockExpanded = _rightRailExpanded;
        var draftQueueExpanded = _queuePanelExpanded;
        var draftStartupRealtimeLoggingEnabled = _startupRealtimeLoggingEnabled;
        var draftIsDark = widget.isDark;
        return StatefulBuilder(builder: (context, setDialogState) {
          final contentHeight =
              (MediaQuery.sizeOf(context).height - 260).clamp(280.0, 520.0);
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            title: const Text('设置'),
            content: SizedBox(
              width: 440,
              height: contentHeight,
              child: Scrollbar(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule_rounded),
                      title: const Text('日志时间时区'),
                      subtitle: Text(timeZoneLabel(draftOffset)),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: () async {
                          final offset =
                              await _chooseTimeZone(context, draftOffset);
                          if (offset != null) {
                            setDialogState(() => draftOffset = offset);
                          }
                        },
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('修改时区'),
                      ),
                    ),
                    const Divider(height: 28),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('启动默认值',
                          style: Theme.of(context).textTheme.titleSmall),
                    ),
                    const SizedBox(height: 6),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(draftIsDark
                          ? Icons.dark_mode_outlined
                          : Icons.light_mode_outlined),
                      title: const Text('主题'),
                      subtitle: Text(draftIsDark ? '深色' : '浅色'),
                      trailing: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                              value: false,
                              icon: Icon(Icons.light_mode_outlined, size: 16),
                              label: Text('浅色')),
                          ButtonSegment(
                              value: true,
                              icon: Icon(Icons.dark_mode_outlined, size: 16),
                              label: Text('深色')),
                        ],
                        selected: {draftIsDark},
                        showSelectedIcon: false,
                        onSelectionChanged: (value) =>
                            setDialogState(() => draftIsDark = value.first),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.vertical_split_rounded),
                      title: const Text('左侧 Dock'),
                      subtitle: Text(draftLeftDockExpanded ? '启动时展开' : '启动时隐藏'),
                      value: draftLeftDockExpanded,
                      onChanged: (value) =>
                          setDialogState(() => draftLeftDockExpanded = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.vertical_split_rounded),
                      title: const Text('右侧 Dock'),
                      subtitle:
                          Text(draftRightDockExpanded ? '启动时展开' : '启动时隐藏'),
                      value: draftRightDockExpanded,
                      onChanged: (value) =>
                          setDialogState(() => draftRightDockExpanded = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.playlist_play_rounded),
                      title: const Text('队列编辑面板'),
                      subtitle: Text(draftQueueExpanded ? '启动时展开' : '启动时隐藏'),
                      value: draftQueueExpanded,
                      onChanged: (value) =>
                          setDialogState(() => draftQueueExpanded = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.save_alt_rounded),
                      title: const Text('实时保存'),
                      subtitle: Text(draftStartupRealtimeLoggingEnabled
                          ? '启动时续写上次选择的保存文件'
                          : '启动时默认关闭'),
                      value: draftStartupRealtimeLoggingEnabled,
                      onChanged: (value) => setDialogState(
                          () => draftStartupRealtimeLoggingEnabled = value),
                    ),
                    const Divider(height: 28),
                    Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 4),
                        leading: const Icon(Icons.info_outline_rounded),
                        title: const Text('关于 HCOM'),
                        subtitle: const Text('版本、开发者、仓库与版权信息'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _showAbout,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(
                        context,
                        _StartupSettings(
                          timeZoneOffsetMinutes: draftOffset,
                          leftDockExpanded: draftLeftDockExpanded,
                          rightDockExpanded: draftRightDockExpanded,
                          queueExpanded: draftQueueExpanded,
                          startupRealtimeLoggingEnabled:
                              draftStartupRealtimeLoggingEnabled,
                          isDark: draftIsDark,
                        ),
                      ),
                  child: const Text('保存')),
            ],
          );
        });
      },
    );
    if (settings == null) return;
    setState(() {
      _timeZoneOffsetMinutes = settings.timeZoneOffsetMinutes;
      _leftRailExpanded = settings.leftDockExpanded;
      _rightRailExpanded = settings.rightDockExpanded;
      _queuePanelExpanded = settings.queueExpanded;
      _startupRealtimeLoggingEnabled = settings.startupRealtimeLoggingEnabled;
    });
    widget.onStartupThemeChanged(settings.isDark);
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setInt(
          'displayTimeZoneOffsetMinutes', settings.timeZoneOffsetMinutes),
      preferences.setBool('startupLeftDockExpanded', settings.leftDockExpanded),
      preferences.setBool(
          'startupRightDockExpanded', settings.rightDockExpanded),
      preferences.setBool('startupQueueExpanded', settings.queueExpanded),
      preferences.setBool('startupRealtimeLoggingEnabled',
          settings.startupRealtimeLoggingEnabled),
    ]);
    if (mounted) _showMessage('启动默认值已保存');
  }

  Future<void> _showAbout() => _showContainerTransformDialog<void>(
        context: context,
        alignment: Alignment.bottomCenter,
        builder: (context) => _AboutHcomDialog(
          onClose: () => Navigator.pop(context),
        ),
      );

  Future<int?> _chooseTimeZone(BuildContext context, int selectedOffset) =>
      _showContainerTransformDialog<int>(
        context: context,
        alignment: Alignment.centerLeft,
        builder: (context) => AlertDialog(
          title: const Text('选择时区'),
          content: SizedBox(
            width: 360,
            height: 420,
            child: ListView(
              children: availableTimeZoneOffsets
                  .map((offset) => ListTile(
                        dense: true,
                        leading: Icon(offset == selectedOffset
                            ? Icons.check_rounded
                            : Icons.schedule_outlined),
                        title: Text(timeZoneLabel(offset)),
                        onTap: () => Navigator.pop(context, offset),
                      ))
                  .toList(),
            ),
          ),
        ),
      );

  void _toggleConnection() {
    if (_connected) {
      _stopPeriodicSend();
      _bridge.send('close_port');
      return;
    }
    final port = _selectedPort;
    if (port == null) {
      _showMessage('未发现可用串口，请连接设备后刷新。');
      _bridge.send('scan_ports');
      return;
    }
    _bridge.send('open_port', {
      'port': port.port,
      'baudRate': int.parse(_baudRate),
      'dataBits': int.parse(_dataBits),
      'stopBits': int.parse(_stopBits),
      'parity': switch (_parity) {
        '奇 Odd' => 'odd',
        '偶 Even' => 'even',
        _ => 'none',
      },
      'flowControl': switch (_flowControl) {
        'RTS/CTS' => 'rts_cts',
        'XON/XOFF' => 'xon_xoff',
        _ => 'none',
      },
    });
  }

  void _selectReceiveFramingMode(ReceiveFramingMode mode) {
    if (mode == _receiveFramingConfig.mode) return;
    final unfinished = _receiveFramer.flush().map((frame) => SerialEntry(
          direction: SerialDirection.rx,
          timestamp: frame.timestamp,
          hex: frame.hex,
          label: 'Core',
        ));
    final config = ReceiveFramingConfig(
      mode: mode,
      fixedLength: _receiveFramingConfig.fixedLength,
      headerHex: _receiveFramingConfig.headerHex,
      trailerHex: _receiveFramingConfig.trailerHex,
    );
    setState(() {
      _appendEntries(unfinished);
      _receiveFramingConfig = config;
      _receiveFramer.configure(config);
    });
    _showMessage('接收分包已切换为 ${config.mode.label}');
  }

  Future<void> _exportFrameTemplate() async {
    final location = await getSaveLocation(
      suggestedName:
          '${_frameTemplate.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}_frame.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'HCOM 帧模板', extensions: ['json'])
      ],
    );
    if (location == null) return;
    try {
      await File(location.path)
          .writeAsString(_frameTemplate.encode(), flush: true);
      if (mounted) _showMessage('已导出帧模板“${_frameTemplate.name}”');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('导出失败：${error.message}');
    }
  }

  Future<void> _importFrameTemplate() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'HCOM 帧模板', extensions: ['json'])
      ],
    );
    if (file == null) return;
    try {
      final template = FrameTemplate.decode(await file.readAsString());
      if (!mounted) return;
      setState(() => _setFrameTemplate(template));
      _showMessage('已导入帧模板“${template.name}”');
    } on FormatException catch (error) {
      if (mounted) _showMessage('导入失败：${error.message}');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('读取失败：${error.message}');
    }
  }

  Future<ProtocolField?> _editProtocolField(
    BuildContext context,
    ProtocolField initial,
  ) async {
    final name = TextEditingController(text: initial.name);
    final length = TextEditingController(text: initial.byteLength.toString());
    final value = TextEditingController(text: initial.valueHex);
    var kind = initial.kind;
    var order = initial.byteOrder;
    var algorithm = initial.checksumAlgorithm;
    final result = await _showContainerTransformDialog<ProtocolField>(
      context: context,
      alignment: Alignment.centerRight,
      builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
                title: Text(initial.id == 'new' ? '添加字段' : '编辑字段'),
                content: SizedBox(
                    width: 400,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      _HcomPopupField<ProtocolFieldKind>(
                          width: 400,
                          label: '字段类型',
                          value: kind,
                          options: ProtocolFieldKind.values,
                          textOf: (item) => item.label,
                          onChanged: (item) =>
                              setDialogState(() => kind = item)),
                      const SizedBox(height: 12),
                      TextField(
                          controller: name,
                          decoration: const InputDecoration(labelText: '字段名称')),
                      const SizedBox(height: 12),
                      TextField(
                          controller: length,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: '字节数（数据域由长度字段决定）')),
                      const SizedBox(height: 12),
                      if (kind == ProtocolFieldKind.header ||
                          kind == ProtocolFieldKind.trailer)
                        TextField(
                            controller: value,
                            decoration: const InputDecoration(
                                labelText: '固定 HEX 值，例如 AA 55')),
                      if (kind == ProtocolFieldKind.length ||
                          kind == ProtocolFieldKind.integer) ...[
                        const SizedBox(height: 12),
                        _HcomPopupField<ByteOrder>(
                            width: 400,
                            label: '字节序',
                            value: order,
                            options: ByteOrder.values,
                            textOf: (item) => item.label,
                            onChanged: (item) =>
                                setDialogState(() => order = item)),
                      ],
                      if (kind == ProtocolFieldKind.checksum) ...[
                        const SizedBox(height: 12),
                        _HcomPopupField<ChecksumAlgorithm>(
                            width: 400,
                            label: '算法',
                            value: algorithm,
                            options: ChecksumAlgorithm.values,
                            textOf: (item) => item.label,
                            onChanged: (item) =>
                                setDialogState(() => algorithm = item)),
                      ],
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        final byteLength = int.tryParse(length.text);
                        if (name.text.trim().isEmpty ||
                            byteLength == null ||
                            byteLength < 1 ||
                            byteLength > 4096) {
                          return;
                        }
                        if ((kind == ProtocolFieldKind.header ||
                                kind == ProtocolFieldKind.trailer) &&
                            parseHexBytes(value.text).length != byteLength) {
                          return;
                        }
                        Navigator.pop(
                            context,
                            ProtocolField(
                                id: initial.id == 'new'
                                    ? DateTime.now()
                                        .microsecondsSinceEpoch
                                        .toString()
                                    : initial.id,
                                kind: kind,
                                name: name.text.trim(),
                                byteLength: byteLength,
                                byteOrder: order,
                                valueHex: value.text.trim().toUpperCase(),
                                checksumAlgorithm: algorithm));
                      },
                      child: const Text('保存')),
                ],
              )),
    );
    name.dispose();
    length.dispose();
    value.dispose();
    return result;
  }

  Future<void> _showFrameDefinitionDialog() async {
    final name = TextEditingController(text: _frameTemplate.name);
    var fields = List<ProtocolField>.of(_frameTemplate.fields);
    final previewController =
        TextEditingController(text: 'AA 55 03 10 20 30 62 0D');
    await _showContainerTransformDialog<void>(
      context: context,
      alignment: Alignment.topCenter,
      builder: (dialogContext) =>
          StatefulBuilder(builder: (context, setDialogState) {
        final parsed = ProtocolFrameParser(FrameTemplate(
                id: _frameTemplate.id, name: name.text, fields: fields))
            .parseHex(previewController.text);
        return AlertDialog(
          title: const Row(children: [
            Icon(Icons.account_tree_rounded),
            SizedBox(width: 10),
            Text('帧定义器')
          ]),
          content: SizedBox(
              width: 680,
              height: 560,
              child: Column(children: [
                TextField(
                    controller: name,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(labelText: '帧模板名称')),
                const SizedBox(height: 12),
                Expanded(
                    child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: fields.length,
                  onReorderItem: (oldIndex, newIndex) => setDialogState(() {
                    final field = fields.removeAt(oldIndex);
                    fields.insert(newIndex, field);
                  }),
                  itemBuilder: (context, index) {
                    final field = fields[index];
                    return Card(
                        key: ValueKey(field.id),
                        child: ListTile(
                          leading: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_indicator_rounded)),
                          title: Text(field.name),
                          subtitle: Text(
                              '${field.kind.label} · ${field.byteLength} B${field.valueHex.isEmpty ? '' : ' · ${field.valueHex}'}${field.kind == ProtocolFieldKind.checksum ? ' · ${field.checksumAlgorithm.label}' : ''}'),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                                tooltip: '编辑字段',
                                onPressed: () async {
                                  final edited = await _editProtocolField(
                                      dialogContext, field);
                                  if (edited != null) {
                                    setDialogState(
                                        () => fields[index] = edited);
                                  }
                                },
                                icon: const Icon(Icons.edit_outlined)),
                            IconButton(
                                tooltip: '删除字段',
                                onPressed: fields.length == 1
                                    ? null
                                    : () => setDialogState(
                                        () => fields.removeAt(index)),
                                icon: const Icon(Icons.delete_outline_rounded)),
                          ]),
                        ));
                  },
                )),
                Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                        onPressed: () async {
                          final created = await _editProtocolField(
                              dialogContext,
                              const ProtocolField(
                                  id: 'new',
                                  kind: ProtocolFieldKind.integer,
                                  name: '新字段'));
                          if (created != null) {
                            setDialogState(() => fields.add(created));
                          }
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('添加字段'))),
                const Divider(height: 24),
                TextField(
                    controller: previewController,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                        labelText: '实时预览 HEX',
                        hintText: 'AA 55 03 10 20 30 62 0D')),
                const SizedBox(height: 8),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        parsed.valid
                            ? '预览通过：${parsed.fields.map((field) => '${field.field.name}=${field.hex}').join('  |  ')}'
                            : '预览失败：${parsed.error}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: parsed.valid
                                ? (widget.isDark
                                    ? HcomTheme.txDark
                                    : HcomTheme.txLight)
                                : Theme.of(dialogContext).colorScheme.error))),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  setState(() => _setFrameTemplate(FrameTemplate(
                      id: _frameTemplate.id,
                      name:
                          name.text.trim().isEmpty ? '未命名模板' : name.text.trim(),
                      fields: fields)));
                  Navigator.pop(dialogContext);
                  _showMessage('帧模板已应用到字段解析视图');
                },
                child: const Text('应用模板'))
          ],
        );
      }),
    );
    name.dispose();
    previewController.dispose();
  }

  void _toggleSendPanel() {
    if (_sendPanelExpanded && _periodicSending) _stopPeriodicSend();
    setState(() => _sendPanelExpanded = !_sendPanelExpanded);
    _sendPanelExpanded
        ? _sendPanelFadeController.forward()
        : _sendPanelFadeController.reverse();
  }

  void _togglePortConfiguration() {
    if (_portConfigurationExpanded) {
      _connectionPulseController.forward(from: 0);
    }
    setState(() => _portConfigurationExpanded = !_portConfigurationExpanded);
  }

  void _selectSendMode(Set<SendMode> selection) {
    final mode = selection.isEmpty ? null : selection.first;
    if (mode != null &&
        MediaQuery.sizeOf(context).width < _minimumAppWidthForQueueEditor) {
      _showMessage('当前界面小于 600px，无法展开队列编辑。');
      return;
    }
    if (_periodicSending && mode != SendMode.periodic) _stopPeriodicSend();
    if (_queueSending && mode != SendMode.loop && mode != SendMode.sequence) {
      _stopQueueSend();
    }
    setState(() {
      _sendMode = mode;
      _queuePanelExpanded = mode != null && mode != SendMode.periodic;
    });
  }

  void _queueCommand() {
    final bytes = _commandBaseBytes;
    if (bytes == null) {
      _showMessage(_sendInputFormat == SendInputFormat.hex
          ? '请输入 HEX 命令后再加入队列。'
          : '请输入普通文本后再加入队列。');
      return;
    }
    setState(() => _queue.add(_QueuedCommand(
          name: '命令 ${_queue.length + 1}',
          hex: bytes,
          packetSuffix: _sendPacketSuffix,
        )));
    _showMessage(
        '已加入 ${_queueNameController.text.trim().isEmpty ? '默认队列' : _queueNameController.text.trim()}');
    _commandController.clear();
  }

  List<_QueuedCommand> get _enabledQueue =>
      _queue.where((command) => command.enabled).toList(growable: false);

  void _toggleQueueItem(int index, bool? enabled) =>
      setState(() => _queue[index].enabled = enabled ?? false);

  void _moveQueueItem(int index, int direction) {
    final target = index + direction;
    if (target < 0 || target >= _queue.length) return;
    setState(() {
      final item = _queue.removeAt(index);
      _queue.insert(target, item);
    });
  }

  void _requestQueueDelete(_QueuedCommand command) {
    if (identical(_armedQueueDelete, command)) {
      _queueDeleteTimer?.cancel();
      setState(() => _armedQueueDelete = null);
      _deleteQueueItem(command);
      return;
    }
    _queueDeleteTimer?.cancel();
    setState(() => _armedQueueDelete = command);
    _queueDeleteTimer = Timer(_queueDeleteDoubleClickWindow, () {
      if (!mounted || !identical(_armedQueueDelete, command)) return;
      setState(() => _armedQueueDelete = null);
      unawaited(_confirmQueueDelete(command));
    });
  }

  Future<void> _confirmQueueDelete(_QueuedCommand command) async {
    final confirmed = await _showContainerTransformDialog<bool>(
      context: context,
      alignment: Alignment.centerRight,
      builder: (context) => AlertDialog(
        title: const Text('删除队列命令？'),
        content: Text(
            '确认从“${_queueNameController.text.trim().isEmpty ? '默认队列' : _queueNameController.text.trim()}”中删除“${command.name}”？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _deleteQueueItem(command);
  }

  void _deleteQueueItem(_QueuedCommand command) {
    final index = _queue.indexOf(command);
    if (index < 0) return;
    setState(() => _queue.removeAt(index));
    _showMessage('已删除命令“${command.name}”');
  }

  Future<void> _startQueueSend({required bool repeat}) async {
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    final commands = _enabledQueue;
    if (commands.isEmpty) {
      _showMessage('请在右侧队列中至少勾选一条命令。');
      return;
    }
    final runToken = ++_queueRunToken;
    setState(() => _queueSending = true);
    do {
      for (var index = 0; index < commands.length; index++) {
        if (!_connected || runToken != _queueRunToken) break;
        final command = commands[index];
        _sendBytes(command.wireHex);
        final isLast = index == commands.length - 1;
        final delay = isLast && !repeat ? 0 : command.delayMilliseconds;
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
      }
    } while (repeat && _connected && runToken == _queueRunToken);

    if (mounted && runToken == _queueRunToken) {
      setState(() => _queueSending = false);
      _showMessage(repeat ? '循环发送已停止' : '顺序发送完成');
    }
  }

  void _stopQueueSend() {
    if (!_queueSending) return;
    _queueRunToken++;
    if (mounted) setState(() => _queueSending = false);
    _showMessage('队列发送已停止');
  }

  void _sendToPort() {
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    final bytes = _commandBytes;
    if (bytes == null) {
      _showMessage(_sendInputFormat == SendInputFormat.hex
          ? '请输入 HEX 命令后再发送。'
          : '请输入普通文本后再发送。');
      return;
    }
    _sendBytes(bytes);
  }

  String? get _commandBaseBytes {
    final input = _commandController.text;
    if (input.trim().isEmpty) return null;
    if (_sendInputFormat == SendInputFormat.hex) {
      return input.trim().toUpperCase();
    }
    return utf8
        .encode(input)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }

  String? get _commandBytes {
    final bytes = _commandBaseBytes;
    return bytes == null ? null : _appendPacketSuffix(bytes, _sendPacketSuffix);
  }

  void _selectSendInputFormat(Set<SendInputFormat> formats) {
    if (formats.isEmpty) return;
    final format = formats.first;
    if (format == _sendInputFormat) return;
    final now = DateTime.now();
    final consecutive = _lastSendFormatToggleAt != null &&
        now.difference(_lastSendFormatToggleAt!) <= _sendFormatSyncWindow;
    _lastSendFormatToggleAt = now;
    _sendFormatToggleCount = consecutive ? _sendFormatToggleCount + 1 : 1;
    var linkJustEnabled = false;
    setState(() {
      _sendInputFormat = format;
      if (!_formatsLinked && _sendFormatToggleCount >= 3) {
        _formatsLinked = true;
        _receiveInputFormat = format;
        _sendFormatToggleCount = 0;
        linkJustEnabled = true;
      } else if (_formatsLinked) {
        _receiveInputFormat = format;
      }
    });
    if (linkJustEnabled) {
      _showMessage('发送与接收格式已开启联动；以后切换发送格式会立即同步接收格式');
    }
  }

  void _selectReceiveInputFormat(Set<SendInputFormat> formats) {
    if (formats.isEmpty) return;
    final format = formats.first;
    if (format == _receiveInputFormat) return;
    setState(() {
      _receiveInputFormat = format;
      _formatsLinked = false;
      _sendFormatToggleCount = 0;
    });
    _showMessage('已解除发送与接收格式联动');
  }

  void _sendBytes(String bytes) => _bridge.send('write_data', {'bytes': bytes});

  void _togglePeriodicSend() {
    if (_periodicSending) {
      _stopPeriodicSend();
      return;
    }
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    final intervalMilliseconds = int.tryParse(_periodicIntervalController.text);
    if (intervalMilliseconds == null ||
        intervalMilliseconds < 10 ||
        intervalMilliseconds > 3600000) {
      _showMessage('周期请输入 10–3600000 ms。');
      return;
    }
    final bytes = _commandBytes;
    if (bytes == null) {
      _showMessage(_sendInputFormat == SendInputFormat.hex
          ? '请输入 HEX 命令后再开始周期。'
          : '请输入普通文本后再开始周期。');
      return;
    }
    _bridge.send('start_periodic', {
      'intervalMs': intervalMilliseconds,
      'commands': [bytes],
    });
    setState(() => _periodicSending = true);
    _showMessage('已开始周期发送：每 $intervalMilliseconds ms 发送当前消息');
  }

  void _stopPeriodicSend() {
    if (!_periodicSending) return;
    _bridge.send('stop_periodic');
    if (mounted) setState(() => _periodicSending = false);
    _showMessage('周期发送已停止');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Stack(children: [
      Scaffold(
        body: Column(children: [
          _windowTitleBar(scheme),
          SizedBox(
            height: 64,
            child: AppBar(
              primary: false,
              toolbarHeight: 64,
              titleSpacing: 16,
              title: Row(children: [
                _brandLogo(size: 44),
                const SizedBox(width: 12),
                const Text('HCOM 调试助手'),
              ]),
              actions: [
                _appAction(Icons.folder_open_rounded, '打开日志'),
                _appAction(Icons.account_tree_rounded, '帧定义器',
                    _showFrameDefinitionDialog),
                _appAction(
                    Icons.upload_file_rounded, '导入帧配置', _importFrameTemplate),
                _appAction(
                    Icons.download_rounded, '导出帧配置', _exportFrameTemplate),
                const Spacer(),
                _connectionChip(scheme),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '切换${widget.isDark ? '浅色' : '深色'}主题',
                  onPressed: widget.onThemeChanged,
                  icon: Icon(widget.isDark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined),
                ),
                _appAction(Icons.settings_outlined, '设置', _showSettings),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            child: Column(children: [
              Expanded(
                child: Row(children: [
                  _protocolRail(scheme),
                  Expanded(child: _workspace(scheme)),
                  _extensionRail(scheme),
                ]),
              ),
              _statusBar(scheme),
            ]),
          ),
        ]),
      ),
      if (_notificationMessage case final message?)
        _transientNotification(message, scheme),
      Positioned.fill(
        child: _FloatingIntegrityPanel(
          visible: _integrityPanelVisible,
          onMinimize: _minimizeIntegrityPanel,
          onSendToMain: _fillSendInputFromIntegrityPanel,
        ),
      ),
    ]);
    return _usesNativeWindowFrame
        ? WindowBorder(
            color: scheme.outlineVariant.withValues(alpha: .7),
            width: 1,
            child: content,
          )
        : content;
  }

  bool get _usesNativeWindowFrame =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  Widget _windowTitleBar(ColorScheme scheme) {
    final buttonColors = WindowButtonColors(
      iconNormal: scheme.onSurfaceVariant,
      mouseOver: scheme.surfaceContainerHighest,
      mouseDown: scheme.surfaceContainerHigh,
      iconMouseOver: scheme.onSurface,
      iconMouseDown: scheme.onSurface,
    );
    final closeButtonColors = WindowButtonColors(
      iconNormal: scheme.onSurfaceVariant,
      mouseOver: scheme.error,
      mouseDown: scheme.errorContainer,
      iconMouseOver: scheme.onError,
      iconMouseDown: scheme.onErrorContainer,
    );
    final title = Container(
      height: 36,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(children: [
        Expanded(
          child: _usesNativeWindowFrame
              ? MoveWindow(
                  child: _windowTitleContent(scheme),
                )
              : _windowTitleContent(scheme),
        ),
        if (_usesNativeWindowFrame)
          Tooltip(
            message: '最小化窗口',
            child: MinimizeWindowButton(colors: buttonColors),
          ),
        if (_usesNativeWindowFrame)
          Tooltip(
            message: '最大化或还原窗口',
            child: MaximizeWindowButton(colors: buttonColors),
          ),
        if (_usesNativeWindowFrame)
          Tooltip(
            message: '关闭窗口',
            child: CloseWindowButton(colors: closeButtonColors),
          ),
      ]),
    );
    return _usesNativeWindowFrame ? WindowTitleBarBox(child: title) : title;
  }

  Widget _windowTitleContent(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(left: 14, right: 8),
        child: Row(children: [
          _brandLogo(size: 24),
          const SizedBox(width: 8),
          Text('HCOM',
              style: TextStyle(
                  color: scheme.onSurface,
                  fontFamily: HcomTheme.latinFontFamily,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .5,
                  fontSize: 13)),
          const SizedBox(width: 10),
          Text('UART WORKBENCH',
              style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontFamily: HcomTheme.latinFontFamily,
                  letterSpacing: .8,
                  fontSize: 10)),
        ]),
      );

  Widget _transientNotification(String message, ColorScheme scheme) =>
      Positioned(
        left: 0,
        right: 0,
        bottom: 42,
        child: Center(
          child: MouseRegion(
            opaque: false,
            onEnter: (_) => setState(() => _notificationHovered = true),
            child: IgnorePointer(
              ignoring: _notificationHovered,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: _notificationHovered ? .16 : 1,
                child: Material(
                  color: scheme.surfaceContainerHighest,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Text(message,
                        style: TextStyle(color: scheme.onSurface)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// Leaves a deliberate M3 gap between independent toolbar actions so their
  /// circular containers do not visually merge into one control.
  Widget _appAction(IconData icon, String tooltip, [VoidCallback? action]) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: IconButton.filledTonal(
          tooltip: tooltip,
          onPressed: action ?? () => _showMessage('$tooltip将在后续阶段接入'),
          icon: Icon(icon, size: 20),
        ),
      );

  Widget _connectionChip(ColorScheme scheme) {
    final accent = widget.isDark ? HcomTheme.txDark : HcomTheme.txLight;
    final isActive = _connected || _connecting;
    final summary = _connected
        ? '${_selectedPort?.port ?? 'COM'} · $_baudRate · $_dataBits-$_parityCode-$_stopBits'
        : (_connecting ? '连接中…' : '未连接');
    return ScaleTransition(
      scale: TweenSequence<double>([
        TweenSequenceItem(tween: Tween(begin: 1, end: 1.055), weight: 55),
        TweenSequenceItem(tween: Tween(begin: 1.055, end: 1), weight: 45),
      ]).animate(CurvedAnimation(
          parent: _connectionPulseController,
          curve: Easing.emphasizedDecelerate)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Easing.standard,
        height: 40,
        decoration: BoxDecoration(
          color: isActive
              ? accent.withValues(alpha: .15)
              : scheme.surfaceContainerLow,
          border: Border.all(
              color: isActive
                  ? accent.withValues(alpha: .55)
                  : scheme.outlineVariant),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: '当前串口配置摘要',
                child: InkWell(
                  onTap: _portConfigurationExpanded
                      ? null
                      : _togglePortConfiguration,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14, right: 12),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Easing.standard,
                        child: Icon(
                            _connected
                                ? Icons.link_rounded
                                : Icons.link_off_rounded,
                            key: ValueKey(_connected),
                            size: 16,
                            color:
                                _connected ? accent : scheme.onSurfaceVariant),
                      ),
                      const SizedBox(width: 8),
                      Text(summary,
                          style: const TextStyle(
                              fontFamily: HcomTheme.latinFontFamily,
                              fontSize: 12)),
                    ]),
                  ),
                ),
              ),
              Container(width: 1, height: 24, color: scheme.outlineVariant),
              Tooltip(
                message: _portConfigurationExpanded ? '收起串口配置' : '展开串口配置',
                child: InkWell(
                  onTap: _togglePortConfiguration,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      _portConfigurationExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: isActive ? accent : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _protocolRail(ColorScheme scheme) => _AnimatedRail(
        destinations: const [
          _RailDestination(Icons.usb_rounded, 'UART'),
          _RailDestination(Icons.route_rounded, 'CAN'),
          _RailDestination(Icons.bolt_rounded, 'CAN-FD'),
          _RailDestination(Icons.hub_rounded, 'I2C'),
          _RailDestination(Icons.lan_rounded, 'TCP'),
          _RailDestination(Icons.memory_rounded, '虚拟串口'),
          _RailDestination(Icons.settings_outlined, '设置'),
        ],
        selectedIndex: _leftRailIndex,
        onSelected: (value) {
          if (value == 6) {
            unawaited(_showSettings());
            return;
          }
          if (value != 0) _showMessage('仅 UART/COM 在 v1 范围内');
          setState(() => _leftRailIndex = value);
        },
        scheme: scheme,
        side: _RailSide.left,
        expanded: _leftRailExpanded,
        onToggle: () => setState(() => _leftRailExpanded = !_leftRailExpanded),
      );

  Widget _extensionRail(ColorScheme scheme) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Easing.emphasizedDecelerate,
            alignment: Alignment.centerRight,
            child: _fieldPanelOpen
                ? SizedBox(
                    width: 390,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 16, 10, 16),
                      child: _fieldStream(scheme),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          _AnimatedRail(
            destinations: const [
              _RailDestination(Icons.data_object_rounded, '字段'),
              _RailDestination(Icons.verified_user_rounded, '校验'),
              _RailDestination(Icons.visibility_rounded, '帧监听'),
              _RailDestination(Icons.show_chart_rounded, '时序'),
              _RailDestination(Icons.science_outlined, '信号'),
              _RailDestination(Icons.link_rounded, '抓包'),
              _RailDestination(Icons.extension_rounded, '插件'),
            ],
            selectedIndex: _rightRailIndex,
            onSelected: (value) {
              if (value == 0) {
                if (MediaQuery.sizeOf(context).width < 960) {
                  _showMessage('窗口宽度不足，无法展开字段解析 Dock。');
                  return;
                }
                setState(() {
                  _fieldPanelOpen = !_fieldPanelOpen;
                  _rightRailIndex = _fieldPanelOpen ? 0 : -1;
                  if (_fieldPanelOpen) _queuePanelExpanded = false;
                });
                return;
              }
              if (value == 1) {
                _showIntegrityPanel();
                return;
              }
              setState(() {
                _fieldPanelOpen = false;
                _rightRailIndex = value;
              });
              _showMessage('该扩展模块将在后续阶段接入。');
            },
            scheme: scheme,
            side: _RailSide.right,
            expanded: _rightRailExpanded,
            onToggle: () =>
                setState(() => _rightRailExpanded = !_rightRailExpanded),
          ),
        ],
      );

  Widget _workspace(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          final appWidth = MediaQuery.sizeOf(context).width;
          final availableWorkspaceWidth = constraints.maxWidth - 32;
          final queueWidth = availableWorkspaceWidth >= 1000
              ? 500.0
              : availableWorkspaceWidth / 2;
          final shouldCloseQueueForWindow =
              _queuePanelExpanded && appWidth < _minimumAppWidthForQueueEditor;
          if (shouldCloseQueueForWindow) {
            // Defer the state change until after layout so a window resize is
            // safe. Above 600 px the two panels share the workspace equally.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _queuePanelExpanded) {
                setState(() => _queuePanelExpanded = false);
              }
            });
          }
          final showQueuePanel =
              _queuePanelExpanded && !shouldCloseQueueForWindow;
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _portConfiguration(scheme),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Easing.standard,
                height: _portConfigurationExpanded ? 14 : 0,
              ),
              Expanded(
                child: _hexStream(scheme),
              ),
              const SizedBox(height: 14),
              _sendPanel(scheme),
            ],
          );

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(children: [
              Expanded(child: content),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Easing.emphasizedDecelerate,
                width: showQueuePanel ? 14 : 0,
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Easing.emphasizedDecelerate,
                alignment: Alignment.centerRight,
                child: showQueuePanel
                    ? SizedBox(
                        width: queueWidth,
                        child: _queueEditorPanel(scheme),
                      )
                    : const SizedBox.shrink(),
              ),
            ]),
          );
        },
      );

  Widget _portConfiguration(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          final portWidth = constraints.maxWidth >= 1100
              ? 300.0
              : constraints.maxWidth >= 760
                  ? 250.0
                  : 220.0;
          // With both docks expanded, a half-screen workspace can become too
          // narrow for a useful configuration form.  Keep the receive stream
          // usable by temporarily showing the compact state; the user's
          // explicit expand/collapse preference is left untouched.
          final compactWorkspace = constraints.maxWidth < 420;
          final showIdentity = MediaQuery.sizeOf(context).height >= 700;
          return AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Easing.emphasizedDecelerate,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Easing.standard,
              switchOutCurve: Easing.standard,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: child),
              ),
              child: _portConfigurationExpanded && !compactWorkspace
                  ? Card(
                      key: const ValueKey('port-configuration'),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _portField(portWidth),
                            if (showIdentity && _selectedPort != null)
                              _deviceIdentity(portWidth, scheme),
                            _selectField(
                                '波特率',
                                _baudRate,
                                const [
                                  '9600',
                                  '38400',
                                  '57600',
                                  '115200',
                                  '921600'
                                ],
                                (value) => setState(() => _baudRate = value)),
                            _selectField(
                                '数据位',
                                _dataBits,
                                const ['5', '6', '7', '8'],
                                (value) => setState(() => _dataBits = value)),
                            _selectField('停止位', _stopBits, const ['1', '2'],
                                (value) => setState(() => _stopBits = value)),
                            _selectField(
                                '校验',
                                _parity,
                                const ['无 None', '奇 Odd', '偶 Even'],
                                (value) => setState(() => _parity = value)),
                            _selectField(
                                '流控',
                                _flowControl,
                                const ['无', 'RTS/CTS', 'XON/XOFF'],
                                (value) =>
                                    setState(() => _flowControl = value)),
                            Tooltip(
                              message: _connected ? '关闭当前串口' : '按当前配置打开串口',
                              child: FilledButton.icon(
                                style: _connected
                                    ? FilledButton.styleFrom(
                                        backgroundColor: scheme.error,
                                        foregroundColor: scheme.onError)
                                    : null,
                                onPressed:
                                    _connecting ? null : _toggleConnection,
                                icon: Icon(_connected
                                    ? Icons.link_off_rounded
                                    : Icons.link_rounded),
                                label: Text(_connected
                                    ? '关闭端口'
                                    : (_connecting ? '连接中…' : '打开端口')),
                              ),
                            ),
                            IconButton(
                              tooltip: '收起串口配置',
                              onPressed: _togglePortConfiguration,
                              icon: const Icon(Icons.keyboard_arrow_up_rounded),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(key: ValueKey('port-configuration-hidden')),
            ),
          );
        },
      );

  Widget _portField(double width) {
    final selected = _selectedPort;
    if (selected == null) {
      return SizedBox(
        width: width,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _connecting ? null : () => _bridge.send('scan_ports'),
          child: const InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(labelText: '串口', isDense: true),
            child: Row(children: [
              Expanded(child: Text('未发现串口，点击刷新')),
              Icon(Icons.refresh_rounded),
            ]),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: _HcomPopupField<_SerialPort>(
        width: width,
        label: '串口',
        value: selected,
        options: _ports,
        textOf: (port) => '${port.port} · ${port.description}',
        iconOf: (port) => port.icon,
        onChanged: _connected || _connecting
            ? null
            : (port) => setState(() => _selectedPort = port),
      ),
    );
  }

  Widget _deviceIdentity(double width, ColorScheme scheme) => SizedBox(
        width: width,
        child: Tooltip(
          message: '硬件 ID: ${_selectedPort!.hardwareId}',
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(_selectedPort!.icon, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_selectedPort!.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    Text(_selectedPort!.hardwareId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontFamily: HcomTheme.latinFontFamily,
                            fontSize: 11)),
                  ])),
            ]),
          ),
        ),
      );

  String get _parityCode => switch (_parity) {
        '奇 Odd' => 'O',
        '偶 Even' => 'E',
        _ => 'N',
      };

  Widget _selectField(String label, String selected, List<String> options,
          ValueChanged<String> onChanged) =>
      SizedBox(
        width: 132,
        child: _HcomPopupField<String>(
          width: 132,
          label: label,
          value: selected,
          options: options,
          textOf: (option) => option,
          useMono: true,
          onChanged: _connected || _connecting ? null : onChanged,
        ),
      );

  void _clearLog() {
    if (_entries.isEmpty) return;
    setState(() {
      _entryFlushTimer?.cancel();
      _entryFlushTimer = null;
      _pendingEntries.clear();
      _entries.clear();
      _parsedEntries.clear();
    });
    _showMessage('已清除当前日志');
  }

  Future<void> _saveLogManually(LogFileFormat format) async {
    if (_entries.isEmpty) {
      _showMessage('当前没有可保存的日志。');
      return;
    }
    final location = await _chooseLogSaveLocation(format, 'HCOM_日志');
    if (location == null) return;
    try {
      await File(location.path).writeAsString(
        serializeLogEntries(_entries, format, _timeZoneOffsetMinutes),
        flush: true,
      );
      if (mounted) _showMessage('日志已保存为 ${format.label}');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('保存失败：${error.message}');
    }
  }

  Future<void> _startRealtimeLog(LogFileFormat format) async {
    final location = await _chooseLogSaveLocation(format, 'HCOM_实时日志');
    if (location == null) return;
    try {
      await File(location.path).writeAsString(
        serializeLogEntries(_entries, format, _timeZoneOffsetMinutes),
        flush: true,
      );
      if (!mounted) return;
      setState(() {
        _realtimeLogFormat = format;
        _realtimeLogPath = location.path;
      });
      final preferences = await SharedPreferences.getInstance();
      await Future.wait([
        preferences.setString('lastRealtimeLogPath', location.path),
        preferences.setString('lastRealtimeLogFormat', format.name),
      ]);
      _showMessage('已开始实时保存 ${format.label}');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('无法开始实时保存：${error.message}');
    }
  }

  Future<void> _resumeRealtimeLog(String path, LogFileFormat format) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      if (await file.length() == 0) {
        await file.writeAsString(
          serializeLogEntries(const [], format, _timeZoneOffsetMinutes),
          flush: true,
        );
      }
      if (!mounted) return;
      setState(() {
        _realtimeLogFormat = format;
        _realtimeLogPath = path;
      });
      _showMessage('已按启动默认值启用实时保存 ${format.label}');
    } on FileSystemException {
      if (mounted) _showMessage('无法续写上次的实时保存文件，已保持关闭。');
    }
  }

  void _stopRealtimeLog() {
    if (_realtimeLogPath == null) {
      _showMessage('实时保存已关闭');
      return;
    }
    setState(() {
      _realtimeLogFormat = null;
      _realtimeLogPath = null;
    });
    _showMessage('实时保存已关闭');
  }

  void _appendRealtimeLog(SerialEntry entry) {
    final path = _realtimeLogPath;
    final format = _realtimeLogFormat;
    if (path == null || format == null) return;
    _realtimeWriteChain = _realtimeWriteChain.then((_) async {
      await File(path).writeAsString(
        serializeLogEntries(
          [entry],
          format,
          _timeZoneOffsetMinutes,
          includeCsvHeader: false,
        ),
        mode: FileMode.append,
        flush: true,
      );
    }).catchError((Object error) {
      if (!mounted) return;
      setState(() {
        _realtimeLogFormat = null;
        _realtimeLogPath = null;
      });
      _showMessage('实时保存已关闭：写入文件失败');
    });
  }

  Future<FileSaveLocation?> _chooseLogSaveLocation(
    LogFileFormat format,
    String prefix,
  ) {
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return getSaveLocation(
      suggestedName: '${prefix}_$stamp.${format.extension}',
      acceptedTypeGroups: [
        XTypeGroup(
          label: '${format.label} 日志',
          extensions: [format.extension],
        ),
      ],
    );
  }

  Future<void> _copySelectedLog() async {
    final selectedText = _selectedLogText;
    if (selectedText == null || selectedText.isEmpty) return;
    final text = formatSelectedLogCopy(
      _entries,
      selectedText,
      _timeZoneOffsetMinutes,
    );
    await Clipboard.setData(ClipboardData(text: text));
  }

  Widget _logContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final items = selectableRegionState.contextMenuButtonItems
        .map(
          (item) => item.type == ContextMenuButtonType.copy
              ? ContextMenuButtonItem(
                  type: ContextMenuButtonType.copy,
                  onPressed: () {
                    unawaited(_copySelectedLog());
                    selectableRegionState.hideToolbar();
                  },
                )
              : item,
        )
        .toList();
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Widget _fieldStream(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          // The receive surface is deliberately the first region to yield in
          // a short window. Keep the tab switchable without an overflow.
          if (constraints.maxHeight < 100) {
            return Container(
              key: const ValueKey('field-stream'),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text('窗口高度不足，展开窗口以查看字段解析',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            );
          }
          return _fieldStreamContent(scheme);
        },
      );

  Widget _fieldStreamContent(ColorScheme scheme) {
    final validCount = _entries
        .where((entry) => (_parsedEntries[entry]?.valid ?? false))
        .length;
    return Container(
      key: const ValueKey('field-stream'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
          child: Row(children: [
            const Icon(Icons.account_tree_rounded, size: 19),
            const SizedBox(width: 9),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(_frameTemplate.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                      '${_frameTemplate.fields.length} 个字段 · 已校验 $validCount/${_entries.length} 条',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 11)),
                ])),
            FilledButton.tonalIcon(
              style: _receiveToolbarButtonStyle(),
              onPressed: _showFrameDefinitionDialog,
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('编辑模板'),
            ),
          ]),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(
          child: _entries.isEmpty
              ? Center(
                  child: Text('收到 HEX 数据后，将按当前帧模板显示字段与校验结果',
                      style: TextStyle(color: scheme.onSurfaceVariant)))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    final result = _parsedEntries[entry] ??
                        const ParsedFrame(
                          fields: [],
                          valid: false,
                          error: '正在更新解析结果。',
                        );
                    final isRx = entry.direction == SerialDirection.rx;
                    final accent = isRx
                        ? (widget.isDark ? HcomTheme.rxDark : HcomTheme.rxLight)
                        : (widget.isDark
                            ? HcomTheme.txDark
                            : HcomTheme.txLight);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 7),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                        leading: Container(
                            width: 9,
                            height: 36,
                            decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(99))),
                        title: Text(
                            '${isRx ? 'RX' : 'TX'} · ${_formatTime(entry.timestamp)}',
                            style: const TextStyle(
                                fontFamily: HcomTheme.latinFontFamily,
                                fontSize: 12)),
                        subtitle: Text(
                            result.valid
                                ? '解析通过 · ${entry.byteCount} B'
                                : '解析失败 · ${result.error}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: result.valid
                                    ? (widget.isDark
                                        ? HcomTheme.txDark
                                        : HcomTheme.txLight)
                                    : scheme.error,
                                fontSize: 11.5)),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                            child: Column(children: [
                              for (final field in result.fields)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 3),
                                  child: Row(children: [
                                    SizedBox(
                                        width: 105,
                                        child: Text(field.field.name,
                                            style: TextStyle(
                                                color: scheme.onSurfaceVariant,
                                                fontSize: 12))),
                                    Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                            color: scheme.surfaceContainerHigh,
                                            borderRadius:
                                                BorderRadius.circular(8)),
                                        child: Text(field.hex,
                                            style: const TextStyle(
                                                fontFamily:
                                                    HcomTheme.latinFontFamily,
                                                fontSize: 12))),
                                    if (field.value != null &&
                                        (field.field.kind ==
                                                ProtocolFieldKind.length ||
                                            field.field.kind ==
                                                ProtocolFieldKind.integer)) ...[
                                      const SizedBox(width: 10),
                                      Text('= ${field.value}',
                                          style: TextStyle(
                                              color: scheme.onSurfaceVariant,
                                              fontFamily:
                                                  HcomTheme.latinFontFamily,
                                              fontSize: 12)),
                                    ],
                                  ]),
                                ),
                              if (!result.valid && result.fields.isEmpty)
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('原始：${entry.hex}',
                                        style: const TextStyle(
                                            fontFamily:
                                                HcomTheme.latinFontFamily,
                                            fontSize: 12))),
                            ]),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Widget _hexStream(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          // At very short heights keep all receive actions reachable while
          // giving the stream its last few pixels instead of overflowing.
          final compactToolbar = constraints.maxHeight < 120;
          return Container(
            key: const ValueKey('receive-stream'),
            decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Padding(
                padding: compactToolbar
                    ? const EdgeInsets.fromLTRB(12, 0, 8, 0)
                    : const EdgeInsets.fromLTRB(12, 6, 8, 2),
                child: _receiveToolbar(scheme),
              ),
              Expanded(
                child: Actions(
                  actions: {
                    CopySelectionTextIntent:
                        CallbackAction<CopySelectionTextIntent>(
                      onInvoke: (_) {
                        unawaited(_copySelectedLog());
                        return null;
                      },
                    ),
                  },
                  child: SelectionArea(
                    onSelectionChanged: (content) =>
                        _selectedLogText = content?.plainText,
                    contextMenuBuilder: _logContextMenu,
                    child: _entries.isEmpty
                        ? Center(
                            child: Text('打开串口后，实时 RX/TX 数据将在此显示',
                                style:
                                    TextStyle(color: scheme.onSurfaceVariant)))
                        : ListView.builder(
                            controller: _streamController,
                            padding: const EdgeInsets.all(8),
                            itemCount: _entries.length,
                            itemBuilder: (_, index) =>
                                _entryRow(_entries[index], scheme, index),
                          ),
                  ),
                ),
              ),
            ]),
          );
        },
      );

  Widget _receiveToolbar(ColorScheme scheme) {
    final title = Row(mainAxisSize: MainAxisSize.min, children: [
      SegmentedButton<SendInputFormat>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 10, vertical: 0)),
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
        ),
        segments: const [
          ButtonSegment(
              value: SendInputFormat.hex,
              icon: Icon(Icons.data_object_rounded, size: 16),
              label: Text('HEX 原始')),
          ButtonSegment(
              value: SendInputFormat.plainText,
              icon: Icon(Icons.text_fields_rounded, size: 16),
              label: Text('文本 原始')),
        ],
        selected: {_receiveInputFormat},
        onSelectionChanged: _selectReceiveInputFormat,
      ),
    ]);
    final actions = <Widget>[
      Tooltip(
        message: _showLineNumbers ? '隐藏接收区行号' : '显示接收区行号',
        child: FilledButton.tonalIcon(
          style: _receiveToolbarButtonStyle(
            muted: _showLineNumbers,
            scheme: scheme,
          ),
          onPressed: () => setState(() => _showLineNumbers = !_showLineNumbers),
          icon: Icon(
            _showLineNumbers
                ? Icons.format_list_numbered_rtl_rounded
                : Icons.format_list_numbered_rounded,
            size: 18,
          ),
          label: Text(_showLineNumbers ? '隐藏行号' : '显示行号'),
        ),
      ),
      const SizedBox(width: 8),
      MenuAnchor(
        style: _hcomMenuSurfaceStyle(scheme),
        menuChildren: [
          for (final mode in ReceiveFramingMode.values)
            MenuItemButton(
              style: _hcomMenuItemStyle(
                scheme,
                selected: mode == _receiveFramingConfig.mode,
              ),
              clipBehavior: Clip.antiAlias,
              onPressed: () => _selectReceiveFramingMode(mode),
              leadingIcon: Icon(
                mode == _receiveFramingConfig.mode
                    ? Icons.check_rounded
                    : Icons.call_split_rounded,
              ),
              child: Text(mode.label),
            ),
        ],
        builder: (context, controller, child) => Tooltip(
          message: '选择接收分包方式',
          child: FilledButton.tonalIcon(
            style: _receiveToolbarButtonStyle(),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.call_split_rounded, size: 18),
            label: Text('分包 · ${_receiveFramingConfig.mode.label}'),
          ),
        ),
      ),
      const SizedBox(width: 8),
      MenuAnchor(
        style: _hcomMenuSurfaceStyle(scheme),
        menuChildren: [
          for (final format in LogFileFormat.values)
            MenuItemButton(
              style: _hcomMenuItemStyle(scheme),
              clipBehavior: Clip.antiAlias,
              onPressed: () => unawaited(_saveLogManually(format)),
              leadingIcon: const Icon(Icons.save_as_rounded),
              child: Text('手动保存 ${format.label}'),
            ),
        ],
        builder: (context, controller, child) => Tooltip(
          message: '将当前全部日志另存为 CSV 或 TXT',
          child: FilledButton.tonalIcon(
            style: _receiveToolbarButtonStyle(),
            onPressed: _entries.isEmpty
                ? null
                : () =>
                    controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.save_as_rounded, size: 18),
            label: const Text('手动保存'),
          ),
        ),
      ),
      const SizedBox(width: 8),
      MenuAnchor(
        style: _hcomMenuSurfaceStyle(scheme),
        menuChildren: [
          MenuItemButton(
            style: _hcomMenuItemStyle(
              scheme,
              selected: _realtimeLogPath == null,
            ),
            clipBehavior: Clip.antiAlias,
            onPressed: _stopRealtimeLog,
            leadingIcon: const Icon(Icons.pause_circle_outline_rounded),
            child: const Text('关闭实时保存'),
          ),
          const Divider(),
          MenuItemButton(
            style: _hcomMenuItemStyle(
              scheme,
              selected: _realtimeLogPath != null &&
                  _realtimeLogFormat == LogFileFormat.csv,
            ),
            clipBehavior: Clip.antiAlias,
            onPressed: () => unawaited(_startRealtimeLog(LogFileFormat.csv)),
            leadingIcon: const Icon(Icons.table_rows_rounded),
            child: const Text('实时保存 CSV'),
          ),
          MenuItemButton(
            style: _hcomMenuItemStyle(
              scheme,
              selected: _realtimeLogPath != null &&
                  _realtimeLogFormat == LogFileFormat.txt,
            ),
            clipBehavior: Clip.antiAlias,
            onPressed: () => unawaited(_startRealtimeLog(LogFileFormat.txt)),
            leadingIcon: const Icon(Icons.description_outlined),
            child: const Text('实时保存 TXT'),
          ),
        ],
        builder: (context, controller, child) => Tooltip(
          message: '选择关闭、CSV 或 TXT 实时保存',
          child: FilledButton.tonalIcon(
            style: _receiveToolbarButtonStyle(
              selected: _realtimeLogPath != null,
              muted: _realtimeLogPath == null,
              scheme: scheme,
            ),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: Icon(
              _realtimeLogPath == null
                  ? Icons.sync_rounded
                  : Icons.sync_lock_rounded,
              size: 18,
            ),
            label: Text(
              _realtimeLogFormat == null
                  ? '实时保存 · 已关闭'
                  : '实时保存中 · ${_realtimeLogFormat!.label}',
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Tooltip(
        message: '清除当前 RX/TX 日志',
        child: FilledButton.tonalIcon(
          style: _receiveToolbarButtonStyle(),
          onPressed: _entries.isEmpty ? null : _clearLog,
          icon: const Icon(Icons.delete_sweep_rounded, size: 18),
          label: const Text('清除日志'),
        ),
      ),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final actionRow = Row(mainAxisSize: MainAxisSize.min, children: actions);
      if (constraints.maxWidth >= 1200) {
        return Row(children: [title, const Spacer(), actionRow]);
      }
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [title, const SizedBox(width: 14), actionRow]),
      );
    });
  }

  ButtonStyle _receiveToolbarButtonStyle({
    bool selected = false,
    bool muted = false,
    ColorScheme? scheme,
  }) =>
      FilledButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        backgroundColor: selected
            ? scheme?.primaryContainer
            : (muted ? scheme?.onSurface.withValues(alpha: .12) : null),
        foregroundColor: selected
            ? scheme?.onPrimaryContainer
            : (muted ? scheme?.onSurface.withValues(alpha: .38) : null),
      );

  Widget _entryRow(SerialEntry entry, ColorScheme scheme, int index) {
    final isRx = entry.direction == SerialDirection.rx;
    final directionLabel = _receiveInputFormat == SendInputFormat.hex
        ? hexDirectionLabel(entry.direction)
        : (isRx ? 'RX(TEXT)' : 'TX(TEXT)');
    final payload = _receiveInputFormat == SendInputFormat.hex
        ? entry.hex
        : _decodeHexText(entry.hex);
    final accent = isRx
        ? (widget.isDark ? HcomTheme.rxDark : HcomTheme.rxLight)
        : (widget.isDark ? HcomTheme.txDark : HcomTheme.txLight);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(children: [
            if (_showLineNumbers) ...[
              SelectionContainer.disabled(
                child: SizedBox(
                  width: 36,
                  child: Text('${index + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11.5,
                          fontFamily: HcomTheme.latinFontFamily)),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Container(
                width: 68,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: .20),
                    borderRadius: BorderRadius.circular(99)),
                child: Text(directionLabel,
                    style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 11))),
            const SizedBox(width: 12),
            SizedBox(
                width: 92,
                child: Text(_formatTime(entry.timestamp),
                    style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11.5,
                        fontFamily: HcomTheme.latinFontFamily))),
            const SizedBox(width: 12),
            Expanded(
                child: Text(payload,
                    style: TextStyle(
                        color: scheme.onSurface,
                        fontFamily: _receiveInputFormat == SendInputFormat.hex
                            ? HcomTheme.latinFontFamily
                            : null,
                        fontSize: 12.5))),
            const SizedBox(width: 12),
            SelectionContainer.disabled(
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('${entry.byteCount} B',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant))),
            ),
          ]),
        ),
      ),
    );
  }

  String _decodeHexText(String hex) {
    final bytes = hex
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .map((value) => int.tryParse(value, radix: 16))
        .whereType<int>()
        .toList();
    return utf8.decode(bytes, allowMalformed: true);
  }

  Widget _brandLogo({required double size}) => SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(
          'Image/未命名的设计.svg',
          fit: BoxFit.contain,
        ),
      );

  Widget _sendPanel(ColorScheme scheme) => Card(
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16))),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, _sendPanelExpanded ? 10 : 0, 16, _sendPanelExpanded ? 12 : 0),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Easing.standard,
            child: _sendPanelExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sendPanelHeader(),
                      FadeTransition(
                        opacity: CurvedAnimation(
                            parent: _sendPanelFadeController,
                            curve: Easing.standard),
                        child: Column(children: [
                          const SizedBox(height: 8),
                          _sendCommandBar(scheme),
                        ]),
                      ),
                    ],
                  )
                : _sendCommandBar(scheme, collapsed: true),
          ),
        ),
      );

  Widget _sendPanelHeader() => LayoutBuilder(builder: (context, constraints) {
        final formatSelector = SegmentedButton<SendInputFormat>(
          segments: const [
            ButtonSegment(
                value: SendInputFormat.hex,
                icon: Icon(Icons.data_object_rounded, size: 17),
                label: Text('HEX'),
                tooltip: '以十六进制字节发送'),
            ButtonSegment(
                value: SendInputFormat.plainText,
                icon: Icon(Icons.text_fields_rounded, size: 17),
                label: Text('普通'),
                tooltip: '以 UTF-8 文本编码发送'),
          ],
          selected: {_sendInputFormat},
          showSelectedIcon: false,
          onSelectionChanged: _selectSendInputFormat,
        );
        final modeSelector = SegmentedButton<SendMode>(
          segments: const [
            ButtonSegment(
                value: SendMode.sequence,
                icon: Icon(Icons.playlist_play_rounded, size: 17),
                label: Text('顺序'),
                tooltip: '按队列顺序发送一轮；每条遵循发送后延时'),
            ButtonSegment(
                value: SendMode.loop,
                icon: Icon(Icons.repeat_rounded, size: 17),
                label: Text('循环'),
                tooltip: '重复执行勾选队列，直到点击停止循环'),
            ButtonSegment(
                value: SendMode.trigger,
                icon: Icon(Icons.bolt_rounded, size: 17),
                label: Text('触发'),
                tooltip: '手动触发一轮已选队列；接收条件将在后续提供'),
            ButtonSegment(
                value: SendMode.periodic,
                icon: Icon(Icons.timer, size: 17),
                label: Text('周期'),
                tooltip: '按设定间隔重复发送发送框当前消息，不使用队列'),
          ],
          selected: _sendMode == null ? {} : {_sendMode!},
          emptySelectionAllowed: true,
          onSelectionChanged: _selectSendMode,
        );
        final collapseButton = IconButton(
          tooltip: '收起发送面板',
          onPressed: _toggleSendPanel,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        );
        const title = Text('发送面板',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500));
        // Keep the complete header on one visual line.  On a compact window a
        // second line here would consume the receive stream's last usable
        // height; scale the controls down instead of pushing that stream away.
        return Row(children: [
          title,
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              alignment: Alignment.centerRight,
              fit: BoxFit.scaleDown,
              child: Row(children: [
                formatSelector,
                const SizedBox(width: 10),
                modeSelector,
                collapseButton,
              ]),
            ),
          ),
        ]);
      });

  Widget _sendCommandBar(ColorScheme scheme, {bool collapsed = false}) {
    final periodicMode = _sendMode == SendMode.periodic;
    final queueMode = _sendMode == SendMode.sequence ||
        _sendMode == SendMode.loop ||
        _sendMode == SendMode.trigger;
    final queueRunMode =
        _sendMode == SendMode.sequence || _sendMode == SendMode.loop;
    final queueIsRunning = queueRunMode && _queueSending;
    Widget commandInput({bool expand = false}) => TextField(
          key: const ValueKey('main-send-input'),
          controller: _commandController,
          decoration: InputDecoration(
            hintText: _sendInputFormat == SendInputFormat.hex
                ? '输入 HEX 命令，例如 AA 55 01 01 04 00 41 42 20 1A'
                : '输入普通文本，将以 UTF-8 编码发送',
            isDense: true,
          ),
        );

    Widget periodicField() => Tooltip(
          message: '周期范围：10 ms–1 h',
          child: SizedBox(
            width: 108,
            child: TextField(
              controller: _periodicIntervalController,
              enabled: !_periodicSending,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                  fontFamily: HcomTheme.latinFontFamily, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '周期',
                suffixText: 'ms',
                isDense: true,
              ),
            ),
          ),
        );

    Widget packetButton() => MenuAnchor(
          style: _hcomMenuSurfaceStyle(scheme),
          menuChildren: [
            for (final suffix in PacketSuffix.values)
              MenuItemButton(
                style: _hcomMenuItemStyle(
                  scheme,
                  selected: _sendPacketSuffix == suffix,
                ),
                clipBehavior: Clip.antiAlias,
                onPressed: () => setState(() => _sendPacketSuffix = suffix),
                child: Text(suffix.label),
              ),
          ],
          builder: (context, controller, child) => Tooltip(
            message: '发送当前消息后追加 ${_sendPacketSuffix.label}',
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.call_split_rounded, size: 18),
              label: Text('组包 ${_sendPacketSuffix.label}'),
            ),
          ),
        );

    Widget queueButton() => Tooltip(
          message: '将发送框当前消息加入队列',
          child: FilledButton.tonalIcon(
              onPressed: _queueCommand,
              icon: const Icon(Icons.add_rounded),
              label: const Text('加入队列')),
        );

    Widget sendButton() => Tooltip(
          message: periodicMode
              ? '按设定间隔重复发送发送框当前消息'
              : queueRunMode
                  ? '开始或停止当前队列发送'
                  : queueMode
                      ? '发送队列中已勾选的消息'
                      : '发送当前消息',
          child: FilledButton.icon(
            style: (periodicMode && _periodicSending) || queueIsRunning
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.errorContainer,
                    foregroundColor: scheme.onErrorContainer)
                : null,
            onPressed: _connected
                ? (periodicMode
                    ? _togglePeriodicSend
                    : (queueIsRunning
                        ? _stopQueueSend
                        : (queueMode
                            ? () => unawaited(_startQueueSend(
                                  repeat: _sendMode == SendMode.loop,
                                ))
                            : _sendToPort)))
                : null,
            icon: Icon(periodicMode
                ? (_periodicSending ? Icons.stop : Icons.play_arrow)
                : (queueIsRunning ? Icons.stop : Icons.send_rounded)),
            label: Text(periodicMode
                ? (_periodicSending ? '停止周期' : '开始周期')
                : (queueIsRunning
                    ? '停止${_sendMode == SendMode.loop ? '循环' : '顺序'}'
                    : (queueMode ? '发送已选' : '发送'))),
          ),
        );

    Widget expandButton() => IconButton.filledTonal(
          tooltip: '展开完整发送面板',
          onPressed: _toggleSendPanel,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        );

    // A compact window must never let controls squeeze the message input or
    // overflow into the receive stream.  Stack the action row only when the
    // available width cannot safely fit the desktop layout.
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 420;
      if (!compact) {
        return Row(children: [
          Expanded(child: commandInput()),
          if (periodicMode) ...[const SizedBox(width: 10), periodicField()],
          const SizedBox(width: 10),
          packetButton(),
          const SizedBox(width: 10),
          queueButton(),
          const SizedBox(width: 10),
          sendButton(),
          if (collapsed) ...[const SizedBox(width: 6), expandButton()],
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        commandInput(),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (periodicMode) periodicField(),
              packetButton(),
              queueButton(),
              sendButton(),
              if (collapsed) expandButton(),
            ]),
      ]);
    });
  }

  Widget _queueEditorPanel(ColorScheme scheme) => Card(
        key: const ValueKey('queue-editor-panel'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.playlist_play_rounded),
              const SizedBox(width: 8),
              const Text('队列编辑',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${_enabledQueue.length}/${_queue.length} 已选',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              IconButton(
                tooltip: '收起队列编辑',
                onPressed: () => setState(() {
                  _queuePanelExpanded = false;
                  _sendMode = null;
                }),
                icon: const Icon(Icons.close_rounded),
              ),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _queueNameController,
              decoration: const InputDecoration(
                labelText: '队列名称',
                hintText: '例如：设备初始化',
                prefixIcon: Icon(Icons.drive_file_rename_outline),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            Text(
              '勾选本次 ${_sendModeLabel()} 要发送的命令',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _queue.isEmpty
                  ? Center(
                      child: Text('队列为空，使用左侧“加入队列”添加命令。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  : ListView.separated(
                      itemCount: _queue.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _queueEditorRow(index, scheme),
                    ),
            ),
          ]),
        ),
      );

  String _sendModeLabel() => switch (_sendMode) {
        SendMode.sequence => '顺序发送',
        SendMode.loop => '循环发送',
        SendMode.trigger => '触发发送',
        SendMode.periodic => '周期发送',
        null => '发送',
      };

  Widget _queueEditorRow(int index, ColorScheme scheme) {
    final command = _queue[index];
    return Container(
      key: ObjectKey(command),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tooltip(
          message: command.enabled ? '本次发送此命令' : '不发送此命令',
          child: Checkbox(
            value: command.enabled,
            onChanged: (value) => _toggleQueueItem(index, value),
          ),
        ),
        Expanded(
          child: Column(children: [
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: command.name,
                  enabled: command.enabled,
                  onChanged: (value) => command.name = value,
                  decoration: const InputDecoration(
                    hintText: '命令名称',
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: identical(_armedQueueDelete, command)
                    ? '再点一次立即删除'
                    : '删除命令：单击确认，450 ms 内再点直接删除',
                child: IconButton.filledTonal(
                  onPressed: () => _requestQueueDelete(command),
                  icon: Icon(identical(_armedQueueDelete, command)
                      ? Icons.delete_forever_rounded
                      : Icons.delete_outline_rounded),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            TextFormField(
              initialValue: command.hex,
              enabled: command.enabled,
              onChanged: (value) => command.hex = value.toUpperCase(),
              decoration: const InputDecoration(
                hintText: 'HEX 命令',
                isDense: true,
              ),
              style: const TextStyle(
                  fontFamily: HcomTheme.latinFontFamily, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              Tooltip(
                message: '设置发送该条后等待下一条的时间',
                child: SizedBox(
                  width: 112,
                  child: TextFormField(
                    initialValue: '${command.delayMilliseconds}',
                    enabled: command.enabled,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (value) =>
                        command.delayMilliseconds = int.tryParse(value) ?? 0,
                    decoration: const InputDecoration(
                      labelText: '发送后延时',
                      suffixText: 'ms',
                      isDense: true,
                    ),
                    style: const TextStyle(
                        fontFamily: HcomTheme.latinFontFamily, fontSize: 12),
                  ),
                ),
              ),
              MenuAnchor(
                style: _hcomMenuSurfaceStyle(scheme),
                menuChildren: [
                  for (final suffix in PacketSuffix.values)
                    MenuItemButton(
                      style: _hcomMenuItemStyle(
                        scheme,
                        selected: command.packetSuffix == suffix,
                      ),
                      clipBehavior: Clip.antiAlias,
                      onPressed: command.enabled
                          ? () => setState(() => command.packetSuffix = suffix)
                          : null,
                      child: Text(suffix.label),
                    ),
                ],
                builder: (context, controller, child) => Tooltip(
                  message: '发送此条消息后追加 ${command.packetSuffix.label}',
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: command.enabled
                        ? () => controller.isOpen
                            ? controller.close()
                            : controller.open()
                        : null,
                    icon: const Icon(Icons.call_split_rounded, size: 18),
                    label: Text('组包 ${command.packetSuffix.label}'),
                  ),
                ),
              ),
            ]),
          ]),
        ),
        Column(children: [
          IconButton(
            tooltip: '上移命令',
            iconSize: 18,
            onPressed: index == 0 ? null : () => _moveQueueItem(index, -1),
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
          IconButton(
            tooltip: '下移命令',
            iconSize: 18,
            onPressed: index == _queue.length - 1
                ? null
                : () => _moveQueueItem(index, 1),
            icon: const Icon(Icons.arrow_downward_rounded),
          ),
        ]),
      ]),
    );
  }

  Widget _statusBar(ColorScheme scheme) {
    final rx = _entries
        .where((entry) => entry.direction == SerialDirection.rx)
        .fold(0, (sum, entry) => sum + entry.byteCount);
    final tx = _entries
        .where((entry) => entry.direction == SerialDirection.tx)
        .fold(0, (sum, entry) => sum + entry.byteCount);
    Text item(String label, String value) => Text.rich(
          TextSpan(
            text: '$label ',
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                    color: scheme.onSurface,
                    fontFamily: HcomTheme.latinFontFamily,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        );
    final metrics = Wrap(
      spacing: 20,
      runSpacing: 2,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        item('RX', '$rx B'),
        item('TX', '$tx B'),
        item('速率', '—'),
        item('帧', '${_entries.length}'),
        item('校验通过率', '—'),
      ],
    );
    final buildIdentity = Text(
      'App $applicationVersion · Core $coreVersion · IPC $protocolVersion',
      maxLines: 1,
      overflow: TextOverflow.fade,
      softWrap: false,
      style: TextStyle(
        color: scheme.onSurfaceVariant,
        fontFamily: HcomTheme.latinFontFamily,
        fontSize: 11.5,
      ),
    );
    return Container(
      key: const ValueKey('status-bar'),
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      color: scheme.surfaceContainerLow,
      child: LayoutBuilder(builder: (context, constraints) {
        // Keep live transport data visually centered on a wide desktop while
        // reserving the far-right edge for the build identity. Narrow windows
        // deliberately reflow instead of clipping or horizontally overflowing.
        if (constraints.maxWidth >= 1100) {
          return SizedBox(
            height: 22,
            child: Stack(children: [
              Align(alignment: Alignment.center, child: metrics),
              Align(alignment: Alignment.centerRight, child: buildIdentity),
            ]),
          );
        }
        return Column(mainAxisSize: MainAxisSize.min, children: [
          metrics,
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: buildIdentity,
            ),
          ),
        ]);
      }),
    );
  }

  String _formatTime(DateTime value) =>
      formatDisplayTimestamp(value, _timeZoneOffsetMinutes);
}

/// The shared Material 3 container transform for every in-app detail surface.
/// It keeps the opening control and destination visually related through the
/// same rounded, tonal container rather than using a disconnected popup fade.
Future<T?> _showContainerTransformDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Alignment alignment = Alignment.center,
  bool barrierDismissible = true,
}) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: .32),
      transitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (routeContext, _, __) => SafeArea(
        child: Center(child: builder(routeContext)),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          _ContainerTransformTransition(
        animation: animation,
        alignment: alignment,
        child: child,
      ),
    );

class _ContainerTransformTransition extends StatelessWidget {
  const _ContainerTransformTransition({
    required this.animation,
    required this.alignment,
    required this.child,
  });

  final Animation<double> animation;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final progress = Easing.emphasizedDecelerate.transform(animation.value);
        final radius = BorderRadius.lerp(
          BorderRadius.circular(40),
          BorderRadius.circular(28),
          progress,
        )!;
        return Opacity(
          opacity: progress,
          child: Align(
            alignment: alignment,
            child: Transform.scale(
              alignment: alignment,
              scale: .86 + (.14 * progress),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color.lerp(
                    scheme.secondaryContainer,
                    scheme.surfaceContainerHigh,
                    progress,
                  ),
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .28 * progress),
                      blurRadius: 28 * progress,
                      offset: Offset(0, 12 * progress),
                    ),
                  ],
                ),
                child: ClipRRect(borderRadius: radius, child: child!),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shared menu treatment: a generous surface radius with small inset around
/// each menu item, so hover and selected states remain rounded rather than
/// filling the whole menu as a hard-edged rectangle.
MenuStyle _hcomMenuSurfaceStyle(ColorScheme scheme, {double? width}) =>
    MenuStyle(
      backgroundColor:
          WidgetStatePropertyAll<Color?>(scheme.surfaceContainerHigh),
      elevation: const WidgetStatePropertyAll<double?>(4),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(6),
      ),
      fixedSize: width == null
          ? null
          : WidgetStatePropertyAll<Size?>(Size.fromWidth(width)),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

ButtonStyle _hcomMenuItemStyle(
  ColorScheme scheme, {
  bool selected = false,
}) =>
    MenuItemButton.styleFrom(
      backgroundColor:
          selected ? scheme.secondaryContainer : Colors.transparent,
      overlayColor: scheme.onSurface.withValues(alpha: .10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      minimumSize: const Size(0, 42),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      animationDuration: const Duration(milliseconds: 150),
    );

/// A compact M3 menu field whose rounded option states match the rest of the
/// workbench. Flutter's legacy dropdown renders rectangular item highlights.
class _HcomPopupField<T> extends StatelessWidget {
  const _HcomPopupField({
    required this.width,
    required this.label,
    required this.value,
    required this.options,
    required this.textOf,
    required this.onChanged,
    this.iconOf,
    this.useMono = false,
  });

  final double width;
  final String label;
  final T value;
  final List<T> options;
  final String Function(T value) textOf;
  final IconData? Function(T value)? iconOf;
  final ValueChanged<T>? onChanged;
  final bool useMono;

  Widget? _leadingIcon(T option) {
    final icon = iconOf?.call(option);
    return icon == null ? null : Icon(icon, size: 18);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final textStyle = TextStyle(
      color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
      fontFamily: useMono ? HcomTheme.latinFontFamily : null,
      fontSize: 13,
    );
    return MenuAnchor(
      style: _hcomMenuSurfaceStyle(scheme, width: width),
      crossAxisUnconstrained: false,
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            style: _hcomMenuItemStyle(
              scheme,
              selected: option == value,
            ),
            clipBehavior: Clip.antiAlias,
            onPressed: enabled ? () => onChanged!(option) : null,
            leadingIcon: _leadingIcon(option),
            child: Text(textOf(option),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle),
          ),
      ],
      builder: (context, controller, child) => SizedBox(
        width: width,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          child: InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(labelText: label, isDense: true),
            child: Row(children: [
              Expanded(
                  child: Text(textOf(value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle)),
              Icon(Icons.arrow_drop_down_rounded,
                  color: enabled ? scheme.onSurfaceVariant : scheme.outline),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SerialPort {
  const _SerialPort({
    required this.port,
    required this.description,
    required this.hardwareId,
    required this.kind,
  });

  static _SerialPort? fromCore(Map<dynamic, dynamic> value) {
    final port = value['port'];
    if (port is! String || port.isEmpty) return null;
    return _SerialPort(
      port: port,
      description: value['description']?.toString() ?? 'Serial Port',
      hardwareId: value['hardwareId']?.toString() ?? 'Unknown',
      kind: value['kind']?.toString() ?? 'serial',
    );
  }

  final String port;
  final String description;
  final String hardwareId;
  final String kind;

  IconData get icon => switch (kind) {
        'bluetooth' => Icons.bluetooth_rounded,
        'usb' => Icons.usb_rounded,
        _ => Icons.settings_input_component_rounded,
      };
}

class _RailDestination {
  const _RailDestination(this.icon, this.label);

  final IconData icon;
  final String label;
}

class _AboutDetail extends StatelessWidget {
  const _AboutDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ]),
      );
}

class _AboutHcomDialog extends StatelessWidget {
  const _AboutHcomDialog({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const chinese = TextStyle(
      fontFamily: HcomTheme.chineseFontFamily,
      fontFamilyFallback: HcomTheme.chineseFallback,
    );
    return AlertDialog(
      icon: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.memory_rounded, color: scheme.onPrimaryContainer),
      ),
      title: const Text('关于 HCOM', style: chinese),
      content: SizedBox(
        width: 448,
        child: SingleChildScrollView(
          child: SelectionArea(
            child: DefaultTextStyle.merge(
              style: chinese,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'HCOM 串口调试助手',
                    style: chinese.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '面向 Windows 的 UART/COM 调试与协议帧解析工具。',
                    style: chinese.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 14),
                  const Wrap(spacing: 8, runSpacing: 8, children: [
                    Chip(
                      avatar: Icon(Icons.verified_outlined, size: 18),
                      label: Text('版本 $applicationVersion', style: chinese),
                    ),
                    Chip(
                      avatar: Icon(Icons.desktop_windows_outlined, size: 18),
                      label: Text('Windows 桌面端', style: chinese),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Card(
                    color: scheme.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: DefaultTextStyle.merge(
                        style: chinese,
                        child: const Column(
                          children: [
                            _AboutDetail(label: '开发者', value: 'Tylenoler'),
                            _AboutDetail(
                              label: '开源仓库',
                              value: 'github.com/Tylenoler/HCOM',
                            ),
                            _AboutDetail(
                              label: '著作权',
                              value: '© 2026 Tylenoler',
                            ),
                            _AboutDetail(
                              label: '组件版本',
                              value:
                                  'App $applicationVersion · Core $coreVersion · IPC $protocolVersion',
                            ),
                            _AboutDetail(
                              label: 'Git 提交',
                              value: buildGitRevision,
                            ),
                            _AboutDetail(
                              label: '构建时间',
                              value: buildTimestamp,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '本软件按“自用与开源同步”的原则持续演进。保留所有权利。',
                    style: chinese.copyWith(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded),
          label: const Text('关闭', style: chinese),
        ),
      ],
    );
  }
}

class _FloatingIntegrityPanel extends StatefulWidget {
  const _FloatingIntegrityPanel({
    required this.visible,
    required this.onMinimize,
    required this.onSendToMain,
  });

  final bool visible;
  final VoidCallback onMinimize;
  final ValueChanged<String> onSendToMain;

  @override
  State<_FloatingIntegrityPanel> createState() =>
      _FloatingIntegrityPanelState();
}

class _FloatingIntegrityPanelState extends State<_FloatingIntegrityPanel> {
  Offset? _offset;

  void _resetPosition() => setState(() => _offset = null);

  void _dragBy(DragUpdateDetails details, Size panelSize, Size canvasSize) {
    final current = _offset ?? _defaultOffset(panelSize, canvasSize);
    setState(() {
      _offset = _clampOffset(current + details.delta, panelSize, canvasSize);
    });
  }

  Offset _defaultOffset(Size panelSize, Size canvasSize) => _clampOffset(
        Offset(canvasSize.width - panelSize.width - 82, 94),
        panelSize,
        canvasSize,
      );

  Offset _clampOffset(Offset value, Size panelSize, Size canvasSize) {
    const margin = 12.0;
    final maxX = (canvasSize.width - panelSize.width - margin).clamp(
      margin,
      double.infinity,
    );
    final maxY = (canvasSize.height - panelSize.height - margin).clamp(
      margin,
      double.infinity,
    );
    return Offset(
      value.dx.clamp(margin, maxX).toDouble(),
      value.dy.clamp(margin, maxY).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) => Offstage(
        offstage: !widget.visible,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: AnimatedOpacity(
            opacity: widget.visible ? 1 : 0,
            duration: const Duration(milliseconds: 360),
            curve: Easing.emphasizedDecelerate,
            child: AnimatedScale(
              scale: widget.visible ? 1 : .82,
              alignment: Alignment.centerRight,
              duration: const Duration(milliseconds: 360),
              curve: Easing.emphasizedDecelerate,
              child: LayoutBuilder(builder: (context, constraints) {
                final width = math.min(640.0, constraints.maxWidth - 24);
                final height = math.min(660.0, constraints.maxHeight - 24);
                final panelSize = Size(width, height);
                final canvasSize =
                    Size(constraints.maxWidth, constraints.maxHeight);
                final offset = _clampOffset(
                  _offset ?? _defaultOffset(panelSize, canvasSize),
                  panelSize,
                  canvasSize,
                );
                return Stack(children: [
                  Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    width: panelSize.width,
                    height: panelSize.height,
                    child: IntegrityCalculatorPage(
                      onMinimize: widget.onMinimize,
                      onResetPosition: _resetPosition,
                      onDragUpdate: (details) =>
                          _dragBy(details, panelSize, canvasSize),
                      onSendToMain: widget.onSendToMain,
                    ),
                  ),
                ]);
              }),
            ),
          ),
        ),
      );
}

class IntegrityCalculatorPage extends StatefulWidget {
  const IntegrityCalculatorPage({
    super.key,
    this.onSendToMain,
    this.onMinimize,
    this.onResetPosition,
    this.onDragUpdate,
  });

  final ValueChanged<String>? onSendToMain;
  final VoidCallback? onMinimize;
  final VoidCallback? onResetPosition;
  final GestureDragUpdateCallback? onDragUpdate;

  @override
  State<IntegrityCalculatorPage> createState() =>
      _IntegrityCalculatorPageState();
}

class _IntegrityCalculatorPageState extends State<IntegrityCalculatorPage> {
  final _inputController = TextEditingController();
  IntegrityAlgorithm _algorithm = IntegrityAlgorithm.crc16Modbus;
  ByteOrder _byteOrder = ByteOrder.littleEndian;
  List<int>? _checkBytes;
  List<int> _inputBytes = const [];
  String? _inputError;
  int _customWidth = 16;
  bool _customReflectInput = true;
  bool _customReflectOutput = true;
  final _customPolynomialController = TextEditingController(text: '8005');
  final _customInitialController = TextEditingController(text: 'FFFF');
  final _customXorOutController = TextEditingController(text: '0000');

  @override
  void dispose() {
    _inputController.dispose();
    _customPolynomialController.dispose();
    _customInitialController.dispose();
    _customXorOutController.dispose();
    super.dispose();
  }

  void _calculate() {
    final source = _inputController.text.trim();
    if (source.isEmpty) {
      setState(() {
        _checkBytes = null;
        _inputBytes = const [];
        _inputError = null;
      });
      return;
    }
    final tokens = source.split(RegExp(r'[\s,;]+'));
    if (tokens.any((token) => !RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(token))) {
      setState(() {
        _checkBytes = null;
        _inputBytes = const [];
        _inputError = '请输入两位 HEX 字节，例如：01 03 00 00 00 0A';
      });
      return;
    }
    final inputBytes =
        tokens.map((token) => int.parse(token, radix: 16)).toList();
    try {
      final checkBytes = _algorithm.calculate(
        inputBytes,
        customCrc: _customCrcConfig,
      );
      setState(() {
        _inputError = null;
        _inputBytes = inputBytes;
        _checkBytes = checkBytes;
      });
    } on FormatException {
      setState(() {
        _checkBytes = null;
        _inputError = '自定义 CRC 参数必须是有效的十六进制数。';
      });
    } on ArgumentError catch (error) {
      setState(() {
        _checkBytes = null;
        _inputError = error.message?.toString() ?? '自定义 CRC 参数无效。';
      });
    }
  }

  void _loadExample() {
    _inputController.text = '31 32 33 34 35 36 37 38 39';
    _calculate();
  }

  CustomCrcConfig get _customCrcConfig => CustomCrcConfig(
        width: _customWidth,
        polynomial: int.parse(_customPolynomialController.text, radix: 16),
        initial: int.parse(_customInitialController.text, radix: 16),
        xorOut: int.parse(_customXorOutController.text, radix: 16),
        reflectInput: _customReflectInput,
        reflectOutput: _customReflectOutput,
      );

  bool get _usesByteOrder => !_algorithm.isDigest && _algorithm.bitWidth > 8;

  List<int> get _wireByteValues =>
      !_usesByteOrder || _byteOrder == ByteOrder.bigEndian
          ? _checkBytes!
          : _checkBytes!.reversed.toList();

  String _formatBytes(Iterable<int> bytes) => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  String get _wireBytes => _formatBytes(_wireByteValues);

  String get _completeFrame =>
      _formatBytes([..._inputBytes, ..._wireByteValues]);

  Widget _customCrcControls(ColorScheme scheme) => Card(
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CRC-自定义参数',
                  style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 8, label: Text('8 位')),
                  ButtonSegment(value: 16, label: Text('16 位')),
                  ButtonSegment(value: 32, label: Text('32 位')),
                ],
                selected: {_customWidth},
                onSelectionChanged: (value) {
                  setState(() => _customWidth = value.first);
                  _calculate();
                },
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _customCrcField('多项式', _customPolynomialController),
                _customCrcField('初始值', _customInitialController),
                _customCrcField('异或输出', _customXorOutController),
              ]),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('反射输入 RefIn'),
                value: _customReflectInput,
                onChanged: (value) {
                  setState(() => _customReflectInput = value);
                  _calculate();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('反射输出 RefOut'),
                value: _customReflectOutput,
                onChanged: (value) {
                  setState(() => _customReflectOutput = value);
                  _calculate();
                },
              ),
            ],
          ),
        ),
      );

  Widget _customCrcField(String label, TextEditingController controller) =>
      SizedBox(
        width: 132,
        child: TextField(
          controller: controller,
          onChanged: (_) => _calculate(),
          style: const TextStyle(fontFamily: HcomTheme.latinFontFamily),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]'))
          ],
          decoration: InputDecoration(labelText: label, prefixText: '0x'),
        ),
      );

  Widget _calculatorActions() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _checkBytes == null
                  ? null
                  : () => Clipboard.setData(
                        ClipboardData(text: _completeFrame),
                      ),
              icon: const Icon(Icons.content_copy_rounded),
              label: const Text('复制完整帧'),
            ),
            FilledButton.tonalIcon(
              onPressed: _checkBytes == null || widget.onSendToMain == null
                  ? null
                  : () => widget.onSendToMain!(_completeFrame),
              icon: const Icon(Icons.input_rounded),
              label: const Text('填入主发送框'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                _inputController.clear();
                _calculate();
              },
              icon: const Icon(Icons.clear_rounded),
              label: const Text('清空'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Material(
        key: const ValueKey('integrity-calculator-window'),
        color: scheme.surfaceContainerHigh,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: .28),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: widget.onDragUpdate,
            child: MouseRegion(
              cursor: widget.onDragUpdate == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.move,
              child: Container(
                height: 72,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                color: scheme.surfaceContainerHighest,
                child: Row(children: [
                  Icon(Icons.verified_user_rounded, color: scheme.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('校验模块',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        Text(_algorithm.label,
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  if (widget.onResetPosition != null)
                    IconButton(
                      tooltip: '恢复默认位置',
                      onPressed: widget.onResetPosition,
                      icon: const Icon(Icons.filter_center_focus_rounded),
                    ),
                  if (widget.onMinimize != null) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '缩小校验面板',
                      onPressed: widget.onMinimize,
                      icon: const Icon(Icons.minimize_rounded),
                    ),
                  ],
                ]),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: DropdownMenu<IntegrityAlgorithm>(
                        initialSelection: _algorithm,
                        expandedInsets: EdgeInsets.zero,
                        leadingIcon: const Icon(Icons.tune_rounded),
                        label: const Text('校验 / 摘要算法'),
                        dropdownMenuEntries: IntegrityAlgorithm.values
                            .map((algorithm) => DropdownMenuEntry(
                                  value: algorithm,
                                  label: algorithm.label,
                                ))
                            .toList(),
                        onSelected: (algorithm) {
                          if (algorithm == null) return;
                          setState(() {
                            _algorithm = algorithm;
                            _byteOrder =
                                algorithm == IntegrityAlgorithm.crc16CcittFalse
                                    ? ByteOrder.bigEndian
                                    : ByteOrder.littleEndian;
                          });
                          _calculate();
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton.icon(
                      onPressed: _loadExample,
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                      label: const Text('示例'),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    Chip(
                      avatar: const Icon(Icons.info_outline_rounded, size: 18),
                      label: Text(_algorithm.isDigest
                          ? '摘要算法 · 输出不可逆'
                          : '${_algorithm.bitWidth} 位校验结果'),
                    ),
                    if (_usesByteOrder)
                      SegmentedButton<ByteOrder>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: ByteOrder.littleEndian,
                            label: Text('低位在前'),
                          ),
                          ButtonSegment(
                            value: ByteOrder.bigEndian,
                            label: Text('高位在前'),
                          ),
                        ],
                        selected: {_byteOrder},
                        onSelectionChanged: (selection) =>
                            setState(() => _byteOrder = selection.first),
                      ),
                  ]),
                  if (_algorithm == IntegrityAlgorithm.customCrc) ...[
                    const SizedBox(height: 12),
                    _customCrcControls(scheme),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('crc-calculator-input'),
                    controller: _inputController,
                    onChanged: (_) => _calculate(),
                    minLines: 2,
                    maxLines: 3,
                    keyboardType: TextInputType.multiline,
                    style:
                        const TextStyle(fontFamily: HcomTheme.latinFontFamily),
                    decoration: InputDecoration(
                      labelText: '待计算 HEX 数据',
                      hintText: '01 03 00 00 00 0A',
                      helperText: '空格、逗号或分号分隔；输入时实时计算',
                      errorText: _inputError,
                      prefixIcon: const Icon(Icons.data_object_rounded),
                    ),
                  ),
                  const SizedBox(height: 16),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Easing.emphasizedDecelerate,
                    switchOutCurve: Easing.emphasizedAccelerate,
                    child: _checkBytes == null
                        ? Card(
                            key: const ValueKey('crc-empty'),
                            color: scheme.surfaceContainer,
                            child: const ListTile(
                              leading: Icon(Icons.functions_rounded),
                              title: Text('等待 HEX 数据'),
                              subtitle: Text('输入完整字节后会立即显示校验或摘要结果。'),
                            ),
                          )
                        : Card(
                            key:
                                ValueKey('integrity-${_checkBytes!.join('-')}'),
                            color: scheme.primaryContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(children: [
                                Icon(Icons.verified_rounded,
                                    color: scheme.onPrimaryContainer),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _CrcResultLine(
                                        label:
                                            _algorithm.isDigest ? '摘要' : '校验值',
                                        value: _usesByteOrder
                                            ? '$_wireBytes（${_byteOrder.label}）'
                                            : _wireBytes,
                                        color: scheme.onPrimaryContainer,
                                      ),
                                      const Padding(
                                        padding:
                                            EdgeInsets.symmetric(vertical: 10),
                                        child: Divider(height: 1),
                                      ),
                                      _CrcResultLine(
                                        label: '完整帧',
                                        value: _completeFrame,
                                        color: scheme.onPrimaryContainer,
                                      ),
                                    ],
                                  ),
                                ),
                              ]),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          _calculatorActions(),
        ]),
      ),
    );
  }
}

class _CrcResultLine extends StatelessWidget {
  const _CrcResultLine({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          SelectableText(
            value,
            style: TextStyle(
              color: color,
              fontFamily: HcomTheme.latinFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}

enum _RailSide { left, right }

/// M3 rail with an explicitly timed, shared selection pill.
class _AnimatedRail extends StatefulWidget {
  const _AnimatedRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.scheme,
    required this.side,
    required this.expanded,
    required this.onToggle,
  });

  final List<_RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final ColorScheme scheme;
  final _RailSide side;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_AnimatedRail> createState() => _AnimatedRailState();
}

class _AnimatedRailState extends State<_AnimatedRail> {
  bool _hovering = false;

  static const _itemHeight = 66.0;

  @override
  Widget build(BuildContext context) {
    final controlOnLeft = widget.side == _RailSide.right;
    final collapseIcon = widget.side == _RailSide.left
        ? Icons.chevron_left
        : Icons.chevron_right;
    final expandIcon = widget.side == _RailSide.left
        ? Icons.chevron_right
        : Icons.chevron_left;
    final tooltip = widget.expanded
        ? '收起${widget.side == _RailSide.left ? '左侧' : '右侧'} Dock'
        : '展开${widget.side == _RailSide.left ? '左侧' : '右侧'} Dock';
    final control = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: _hovering ? 1 : .62,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: widget.scheme.surfaceContainerHighest.withValues(alpha: .96),
          shape: StadiumBorder(
              side: BorderSide(color: widget.scheme.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onToggle,
            child: SizedBox(
              width: 34,
              height: 42,
              child: Icon(widget.expanded ? collapseIcon : expandIcon,
                  size: 22, color: widget.scheme.primary),
            ),
          ),
        ),
      ),
    );

    return LayoutBuilder(builder: (context, constraints) {
      const verticalInset = 16.0;
      final usableHeight = (constraints.maxHeight - verticalInset * 2)
          .clamp(0.0, double.infinity);
      final naturalHeight = widget.destinations.length * _itemHeight;
      final railHeight = usableHeight < naturalHeight
          ? usableHeight
          : naturalHeight.toDouble();
      final itemHeight = widget.destinations.isEmpty
          ? _itemHeight
          : railHeight / widget.destinations.length;
      final selectionInset = itemHeight < 12 ? 0.0 : 4.0;

      final expandedRail = Material(
        color: widget.scheme.surfaceContainerLow,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: .18),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Easing.emphasizedDecelerate,
            left: 4,
            right: 4,
            top: selectionInset + widget.selectedIndex * itemHeight,
            height:
                (itemHeight - selectionInset * 2).clamp(0.0, double.infinity),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                    color: widget.scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(100)),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(widget.destinations.length, (index) {
              final destination = widget.destinations[index];
              final selected = index == widget.selectedIndex;
              return SizedBox(
                height: itemHeight,
                width: double.infinity,
                child: Tooltip(
                  message: '打开${destination.label}模块',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(100),
                    onTap: () => widget.onSelected(index),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(destination.icon,
                              size: itemHeight < 52 ? 18 : 20,
                              color: selected
                                  ? widget.scheme.onSecondaryContainer
                                  : widget.scheme.onSurfaceVariant),
                          if (itemHeight >= 42) ...[
                            const SizedBox(height: 3),
                            Text(destination.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: itemHeight < 54 ? 10 : 11,
                                    fontWeight: FontWeight.w500,
                                    color: selected
                                        ? widget.scheme.onSurface
                                        : widget.scheme.onSurfaceVariant)),
                          ],
                        ]),
                  ),
                ),
              );
            }),
          ),
        ]),
      );
      final collapsedRail = Container(
        width: 8,
        decoration: BoxDecoration(
            color: widget.scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(99)),
      );

      return MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Easing.standard,
          width: widget.expanded ? 112 : 44,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(
              top: verticalInset,
              bottom: verticalInset,
              left: controlOnLeft ? 24 : 0,
              right: controlOnLeft ? 0 : 24,
              child: Align(
                // Keep the rail body on the very same vertical center line as
                // its external expand/collapse control.  The previous top
                // alignment left the capsule visually pinned to the window top.
                alignment: Alignment.center,
                child: SizedBox(
                  key: ValueKey(widget.side == _RailSide.left
                      ? 'left-dock-body'
                      : 'right-dock-body'),
                  width: widget.expanded ? 96 : 8,
                  height: railHeight,
                  child: widget.expanded ? expandedRail : collapsedRail,
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: controlOnLeft
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: control,
              ),
            ),
          ]),
        ),
      );
    });
  }
}
