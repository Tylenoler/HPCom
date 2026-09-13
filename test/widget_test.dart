import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hcom/main.dart';
import 'package:hcom/models/frame_protocol.dart';
import 'package:hcom/models/log_copy.dart';
import 'package:hcom/models/log_export.dart';
import 'package:hcom/models/receive_framer.dart';
import 'package:hcom/models/serial_entry.dart';
import 'package:hcom/models/time_zone.dart';
import 'package:hcom/screens/workbench_screen.dart';
import 'package:hcom/theme/hcom_theme.dart';

void main() {
  testWidgets('renders the UART workbench and its in-stream clear action',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    expect(find.text('HCOM 调试助手'), findsOneWidget);
    expect(find.text('HEX 原始'), findsOneWidget);
    expect(find.text('统计'), findsNothing);
    expect(find.text('时间轴'), findsNothing);
    expect(find.text('发送面板'), findsOneWidget);
    expect(find.text('浮动面板'), findsNothing);
    expect(find.text('清除日志'), findsOneWidget);
    expect(find.text('显示行号'), findsOneWidget);
    expect(find.text('手动保存'), findsOneWidget);
    expect(find.text('实时保存 · 已关闭'), findsOneWidget);
    expect(find.textContaining('实时数据'), findsNothing);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('周期'), findsOneWidget);
    expect(find.byIcon(Icons.timer), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-editor-panel')), findsNothing);
  });

  testWidgets('reflows bottom metrics and build identity on a narrow window',
      (tester) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const HcomApp());
    await tester.pumpAndSettle();

    final statusBar = find.byKey(const ValueKey('status-bar'));
    expect(statusBar, findsOneWidget);
    expect(tester.getSize(statusBar).height, greaterThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('mutes but does not disable the hide-line-numbers action',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('显示行号'));
    await tester.pumpAndSettle();

    final buttonFinder = find.ancestor(
      of: find.text('隐藏行号'),
      matching: find.byType(FilledButton),
    );
    final button = tester.widget<FilledButton>(buttonFinder.first);
    final scheme = Theme.of(tester.element(find.text('隐藏行号'))).colorScheme;
    expect(button.style!.backgroundColor!.resolve({}),
        scheme.onSurface.withValues(alpha: .12));
    expect(button.onPressed, isNotNull);

    await tester.tap(find.text('隐藏行号'));
    await tester.pumpAndSettle();
    expect(find.text('显示行号'), findsOneWidget);
  });

  testWidgets('opens the about page from settings', (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于 HCOM'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于 HCOM'));
    await tester.pumpAndSettle();

    expect(find.text('HCOM 串口调试助手'), findsOneWidget);
    expect(find.text('版本 0.3.2'), findsAtLeastNWidgets(1));
    expect(find.text('Tylenoler'), findsOneWidget);
    expect(find.text('github.com/Tylenoler/HCOM'), findsOneWidget);
    expect(find.text('© 2026 Tylenoler'), findsOneWidget);
    expect(find.text('开发构建'), findsOneWidget);
    expect(find.text('未打包'), findsOneWidget);
  });

  testWidgets('calculates and returns a complete integrity frame',
      (tester) async {
    String? returnedFrame;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IntegrityCalculatorPage(
          onSendToMain: (frame) => returnedFrame = frame,
        ),
      ),
    ));

    await tester.enterText(find.byKey(const ValueKey('crc-calculator-input')),
        '31 32 33 34 35 36 37 38 39');
    await tester.pumpAndSettle();
    expect(find.text('校验值'), findsOneWidget);
    expect(find.text('37 4B（小端）'), findsOneWidget);
    expect(find.text('完整帧'), findsOneWidget);
    expect(find.text('31 32 33 34 35 36 37 38 39 37 4B'), findsOneWidget);

    await tester.tap(find.text('填入主发送框'));
    await tester.pumpAndSettle();
    expect(returnedFrame, '31 32 33 34 35 36 37 38 39 37 4B');
  });

  testWidgets('keeps the floating integrity panel state after minimizing',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('打开校验模块'));
    await tester.pumpAndSettle();
    expect(find.text('校验模块'), findsOneWidget);

    const source = '31 32 33 34 35 36 37 38 39';
    const frame = '$source 37 4B';
    await tester.enterText(
        find.byKey(const ValueKey('crc-calculator-input')), source);
    await tester.pumpAndSettle();
    expect(find.text(frame), findsOneWidget);

    await tester.tap(find.byTooltip('缩小校验面板'));
    await tester.pumpAndSettle();
    expect(find.text('校验模块'), findsNothing);

    await tester.tap(find.byTooltip('打开校验模块'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('crc-calculator-input')),
          )
          .controller!
          .text,
      source,
    );
    expect(find.text(frame), findsOneWidget);

    await tester.ensureVisible(find.text('填入主发送框'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('填入主发送框'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('main-send-input')))
          .controller!
          .text,
      frame,
    );
  });

  testWidgets('keeps the floating integrity panel inside the main window',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('打开校验模块'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('integrity-calculator-window'));

    await tester.drag(find.text('校验模块'), const Offset(-2000, -2000));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(panel).dx, greaterThanOrEqualTo(12));
    expect(tester.getTopLeft(panel).dy, greaterThanOrEqualTo(12));

    await tester.drag(find.text('校验模块'), const Offset(4000, 4000));
    await tester.pumpAndSettle();
    final bounds = tester.getRect(panel);
    expect(bounds.right, lessThanOrEqualTo(1280 - 12));
    expect(bounds.bottom, lessThanOrEqualTo(820 - 12));
  });

  testWidgets('updates the selected baud rate while disconnected',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('115200'));
    await tester.pumpAndSettle();
    expect(find.text('9600'), findsOneWidget);

    await tester.tap(find.text('9600'));
    await tester.pumpAndSettle();
    expect(find.text('9600'), findsOneWidget);
  });

  testWidgets('collapses port configuration and keeps a compact send bar',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('收起串口配置').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开串口配置'), findsOneWidget);

    await tester.tap(find.byTooltip('收起发送面板'));
    await tester.pumpAndSettle();
    expect(find.text('发送面板'), findsNothing);
    expect(find.byTooltip('展开完整发送面板'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);
  });

  testWidgets('collapses either vertical dock from its center control',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    final leftBefore = tester.getCenter(find.byTooltip('收起左侧 Dock')).dy;
    final leftBodyBefore =
        tester.getCenter(find.byKey(const ValueKey('left-dock-body'))).dy;
    expect((leftBodyBefore - leftBefore).abs(), lessThanOrEqualTo(1));
    await tester.tap(find.byTooltip('收起左侧 Dock'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开左侧 Dock'), findsOneWidget);
    final leftAfter = tester.getCenter(find.byTooltip('展开左侧 Dock')).dy;
    expect((leftAfter - leftBefore).abs(), lessThanOrEqualTo(1));
    final leftBodyAfter =
        tester.getCenter(find.byKey(const ValueKey('left-dock-body'))).dy;
    expect((leftBodyAfter - leftAfter).abs(), lessThanOrEqualTo(1));

    final rightBefore = tester.getCenter(find.byTooltip('收起右侧 Dock')).dy;
    final rightBodyBefore =
        tester.getCenter(find.byKey(const ValueKey('right-dock-body'))).dy;
    expect((rightBodyBefore - rightBefore).abs(), lessThanOrEqualTo(1));
    await tester.tap(find.byTooltip('收起右侧 Dock'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开右侧 Dock'), findsOneWidget);
    final rightAfter = tester.getCenter(find.byTooltip('展开右侧 Dock')).dy;
    expect((rightAfter - rightBefore).abs(), lessThanOrEqualTo(1));
    final rightBodyAfter =
        tester.getCenter(find.byKey(const ValueKey('right-dock-body'))).dy;
    expect((rightBodyAfter - rightAfter).abs(), lessThanOrEqualTo(1));
  });

  testWidgets('uses an explicit start icon for periodic sending',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('周期'));
    await tester.pumpAndSettle();
    expect(find.text('开始周期'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-editor-panel')), findsNothing);
  });

  testWidgets('opens the queue editor in the right half of a wide workspace',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('循环'));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('queue-editor-panel'));
    expect(panel, findsOneWidget);
    expect(tester.getTopLeft(panel).dx, greaterThan(960));
    expect(find.byType(Checkbox), findsNWidgets(2));
  });

  testWidgets('splits receive and queue panels evenly in a half-screen window',
      (tester) async {
    tester.view.physicalSize = const Size(960, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());
    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    final queue = find.byKey(const ValueKey('queue-editor-panel'));
    final receive = find.byKey(const ValueKey('receive-stream'));
    expect(queue, findsOneWidget);
    expect(
      (tester.getSize(queue).width - tester.getSize(receive).width).abs(),
      lessThanOrEqualTo(16),
    );
  });

  testWidgets('rejects queue expansion below 600 px without selecting a mode',
      (tester) async {
    tester.view.physicalSize = const Size(599, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('queue-editor-panel')), findsNothing);
    expect(find.text('当前界面小于 600px，无法展开队列编辑。'), findsOneWidget);
    expect(find.text('发送已选'), findsNothing);
  });

  testWidgets(
      'links receive format after three send toggles and keeps it synchronized',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('普通'));
    await tester.pumpAndSettle();
    expect(find.text('HEX 原始'), findsOneWidget);
    expect(find.textContaining('实时数据'), findsNothing);
    expect(find.text('输入普通文本，将以 UTF-8 编码发送'), findsOneWidget);

    await tester.tap(find.text('HEX'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通'));
    await tester.pumpAndSettle();
    expect(find.text('文本 原始'), findsOneWidget);
    expect(find.text('发送与接收格式已开启联动；以后切换发送格式会立即同步接收格式'), findsOneWidget);

    // Once linked, every send-format change immediately updates reception.
    await tester.tap(find.text('HEX'));
    await tester.pumpAndSettle();
    expect(find.text('HEX 原始'), findsOneWidget);
    expect(find.textContaining('实时数据'), findsNothing);

    // Choosing the receive text page directly makes it independent again.
    await tester.tap(find.text('文本 原始'));
    await tester.pumpAndSettle();
    expect(find.text('文本 原始'), findsOneWidget);
    expect(find.textContaining('实时数据'), findsNothing);

    await tester.tap(find.text('HEX'));
    await tester.pumpAndSettle();
    expect(find.text('文本 原始'), findsOneWidget);
  });

  testWidgets('protects queue deletion with a second click or confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());
    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    final delete = find.byTooltip('删除命令：单击确认，450 ms 内再点直接删除');
    expect(delete, findsNWidgets(2));
    await tester.tap(delete.first);
    await tester.pump(const Duration(milliseconds: 300));
    final armed = find.byTooltip('再点一次立即删除');
    expect(armed, findsOneWidget);
    await tester.tap(armed);
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除命令：单击确认，450 ms 内再点直接删除'), findsOneWidget);

    await tester.tap(find.byTooltip('删除命令：单击确认，450 ms 内再点直接删除'));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text('删除队列命令？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'moves the full queue row instead of retaining its old input state',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());
    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    final heartbeat = find.text('心跳');
    final before = tester.getTopLeft(heartbeat).dy;
    await tester.tap(find.byTooltip('下移命令').first);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(heartbeat).dy, greaterThan(before));
  });

  testWidgets('uses packaged Noto Sans SC as the Chinese fallback',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    final context = tester.element(find.text('HCOM 调试助手'));
    expect(Theme.of(context).textTheme.bodyMedium!.fontFamilyFallback,
        contains(HcomTheme.chineseFontFamily));
    expect(Theme.of(context).textTheme.bodyMedium!.fontFamily,
        HcomTheme.latinFontFamily);
  });

  testWidgets('opens the persisted log time-zone setting', (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('日志时间时区'), findsOneWidget);
    expect(find.text('UTC+08:00（中国标准时间）'), findsOneWidget);
    expect(find.text('启动默认值'), findsOneWidget);
    expect(find.text('左侧 Dock'), findsOneWidget);
    expect(find.text('右侧 Dock'), findsOneWidget);
    expect(find.text('队列编辑面板'), findsOneWidget);
    expect(find.text('实时保存'), findsOneWidget);
    expect(find.text('启动时默认关闭'), findsOneWidget);

    await tester.tap(find.text('修改时区'));
    await tester.pumpAndSettle();
    expect(find.text('选择时区'), findsOneWidget);
    expect(find.text('UTC-12:00'), findsOneWidget);
  });

  testWidgets('uses rounded hover states for menu options', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('分包 · 自动识别'));
    await tester.pumpAndSettle();
    final anchor = tester.widget<MenuAnchor>(
      find.byType(MenuAnchor).first,
    );
    final surfaceShape = anchor.style!.shape!.resolve({});
    expect(surfaceShape, isA<RoundedRectangleBorder>());
    expect(
      (surfaceShape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(16),
    );

    final menuItem =
        tester.widget<MenuItemButton>(find.byType(MenuItemButton).first);
    final itemShape = menuItem.style!.shape!.resolve({WidgetState.hovered});
    expect(itemShape, isA<RoundedRectangleBorder>());
    expect(
      (itemShape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(10),
    );

    await tester.tap(find.text('固定长度'));
    await tester.pumpAndSettle();
    expect(find.text('分包 · 固定长度'), findsOneWidget);
    expect(find.text('接收分包'), findsNothing);
  });

  testWidgets('offers an explicit off option for realtime saving',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    final buttonFinder = find.ancestor(
      of: find.text('实时保存 · 已关闭'),
      matching: find.byType(FilledButton),
    );
    final button = tester.widget<FilledButton>(buttonFinder.first);
    final scheme =
        Theme.of(tester.element(find.text('实时保存 · 已关闭'))).colorScheme;
    expect(button.style!.backgroundColor!.resolve({}),
        scheme.onSurface.withValues(alpha: .12));
    expect(button.onPressed, isNotNull);

    await tester.tap(find.text('实时保存 · 已关闭'));
    await tester.pumpAndSettle();
    expect(find.text('关闭实时保存'), findsOneWidget);
    expect(find.text('实时保存 CSV'), findsOneWidget);
    expect(find.text('实时保存 TXT'), findsOneWidget);
  });

  testWidgets('shows the Phase 3 structured field view and template editor',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    expect(find.byKey(const ValueKey('field-stream')), findsNothing);
    await tester.tap(find.byTooltip('打开字段模块'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('field-stream')), findsOneWidget);
    expect(find.text('默认 UART 帧'), findsOneWidget);
    expect(find.text('编辑模板'), findsOneWidget);

    await tester.tap(find.text('编辑模板'));
    await tester.pumpAndSettle();
    expect(find.text('帧定义器'), findsOneWidget);
    expect(find.text('实时预览 HEX'), findsOneWidget);
    expect(find.text('添加字段'), findsOneWidget);
  });

  test('defaults log timestamps to China Standard Time', () {
    final timestamp = DateTime.utc(2026, 9, 11, 12, 17, 19, 450);

    expect(defaultTimeZoneOffsetMinutes, 480);
    expect(formatDisplayTimestamp(timestamp, defaultTimeZoneOffsetMinutes),
        '20:17:19.450');
    expect(formatDisplayTimestamp(timestamp, 0), '12:17:19.450');
  });

  test('copies selected HEX log rows as readable two-line records', () {
    final entries = [
      SerialEntry(
        direction: SerialDirection.rx,
        timestamp: DateTime.utc(2026, 9, 11, 12, 38, 53, 175),
        hex: 'AA 55 A0 00',
        label: 'Core',
      ),
      SerialEntry(
        direction: SerialDirection.tx,
        timestamp: DateTime.utc(2026, 9, 11, 12, 38, 53, 345),
        hex: '11 22 33 44',
        label: 'Core',
      ),
    ];
    final selectedText =
        entries.map((entry) => selectableLogEntryText(entry, 480)).join();

    expect(hexDirectionLabel(SerialDirection.rx), 'RX(HEX)');
    expect(hexDirectionLabel(SerialDirection.tx), 'TX(HEX)');
    expect(
      formatSelectedLogCopy(entries, selectedText, 480),
      '26-09-11 20:38:53.175 RX(HEX)\n'
      'AA 55 A0 00\n'
      '26-09-11 20:38:53.345 TX(HEX)\n'
      '11 22 33 44',
    );
  });

  test('exports logs as CSV and TXT records', () {
    final entries = [
      SerialEntry(
        direction: SerialDirection.rx,
        timestamp: DateTime.utc(2026, 9, 11, 12, 38, 53, 175),
        hex: 'AA 55 A0 00',
        label: 'Core',
      ),
    ];

    final csv = serializeLogEntries(
      entries,
      LogFileFormat.csv,
      defaultTimeZoneOffsetMinutes,
    );
    expect(csv, contains('timestamp,direction,format,byte_count,data'));
    expect(csv, contains('26-09-11 20:38:53.175,RX,HEX,4,"AA 55 A0 00"'));

    final txt = serializeLogEntries(
      entries,
      LogFileFormat.txt,
      defaultTimeZoneOffsetMinutes,
    );
    expect(txt, '26-09-11 20:38:53.175 RX(HEX)\nAA 55 A0 00\n');
  });

  test('automatically splits a transport batch by the learned packet length',
      () {
    final framer = ReceiveFramer();
    final time = DateTime.utc(2026, 9, 12, 8, 38, 41);
    for (var index = 0; index < 3; index++) {
      expect(framer.addHex('01 02 03 04', time), hasLength(1));
    }

    final frames = framer.addHex('AA 55 55 AA 10 20 30 40', time);
    expect(frames.map((frame) => frame.hex), ['AA 55 55 AA', '10 20 30 40']);
  });

  test('fixed-length framing spans arbitrary transport reads', () {
    final framer = ReceiveFramer(const ReceiveFramingConfig(
        mode: ReceiveFramingMode.fixedLength, fixedLength: 4));
    final time = DateTime.utc(2026, 9, 12, 8, 38, 41);

    expect(framer.addHex('AA 55', time), isEmpty);
    final frames = framer.addHex('55 AA 11 22 33 44', time);
    expect(frames.map((frame) => frame.hex), ['AA 55 55 AA', '11 22 33 44']);
  });

  test('delimiter framing supports protocol-specific heads and tails', () {
    final framer = ReceiveFramer(const ReceiveFramingConfig(
      mode: ReceiveFramingMode.delimiters,
      headerHex: '7E 01',
      trailerHex: '0D 0A',
    ));
    final time = DateTime.utc(2026, 9, 12, 8, 38, 41);

    expect(framer.addHex('7E 01 10', time), isEmpty);
    final frames = framer.addHex('20 0D 0A 7E 01 30 0D 0A', time);
    expect(frames.map((frame) => frame.hex),
        ['7E 01 10 20 0D 0A', '7E 01 30 0D 0A']);
  });

  test('parses a length-delimited frame and validates SUM-8', () {
    final parser = ProtocolFrameParser(FrameTemplate.standard());

    final parsed = parser.parseHex('AA 55 03 10 20 30 62 0D');

    expect(parsed.valid, isTrue);
    expect(parsed.fields.map((field) => field.field.name),
        ['帧头', '长度', '数据域', '和校验', '帧尾']);
    expect(parsed.fields[2].hex, '10 20 30');
  });

  test('reports checksum and fixed delimiter failures explicitly', () {
    final parser = ProtocolFrameParser(FrameTemplate.standard());

    expect(parser.parseHex('AA 55 01 10 11 0D').valid, isFalse);
    expect(parser.parseHex('AB 55 00 FF 0D').error, contains('帧头 不匹配'));
  });

  test('calculates standard check values for the common CRC algorithms', () {
    final bytes = '123456789'.codeUnits;

    expect(CrcAlgorithm.crc8.calculate(bytes), 0xF4);
    expect(CrcAlgorithm.crc8Maxim.calculate(bytes), 0xA1);
    expect(CrcAlgorithm.crc16Ibm.calculate(bytes), 0xBB3D);
    expect(CrcAlgorithm.crc16Modbus.calculate(bytes), 0x4B37);
    expect(CrcAlgorithm.crc16CcittFalse.calculate(bytes), 0x29B1);
    expect(CrcAlgorithm.crc16X25.calculate(bytes), 0x906E);
    expect(CrcAlgorithm.crc32IsoHdlc.calculate(bytes), 0xCBF43926);
  });

  test('round-trips a frame template through its portable JSON format', () {
    final original = FrameTemplate.standard();
    final decoded = FrameTemplate.decode(original.encode());

    expect(decoded.name, original.name);
    expect(decoded.fields.length, original.fields.length);
    expect(decoded.fields.last.kind, ProtocolFieldKind.trailer);
  });
}
