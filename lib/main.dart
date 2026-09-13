import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/workbench_screen.dart';
import 'theme/hcom_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HcomApp());

  doWhenWindowReady(() {
    const initialSize = Size(1280, 720);
    appWindow
      ..minSize = const Size(600, 480)
      ..size = initialSize
      ..alignment = Alignment.center
      ..title = 'HCOM 调试助手'
      ..show();
  });
}

class HcomApp extends StatefulWidget {
  const HcomApp({super.key});

  @override
  State<HcomApp> createState() => _HcomAppState();
}

class _HcomAppState extends State<HcomApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _loadStartupTheme();
  }

  Future<void> _loadStartupTheme() async {
    final preferences = await SharedPreferences.getInstance();
    final isDark = preferences.getBool('startupDarkTheme') ?? true;
    if (mounted) {
      setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
    }
  }

  void _setStartupTheme(bool isDark) {
    setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
    SharedPreferences.getInstance()
        .then((preferences) => preferences.setBool('startupDarkTheme', isDark));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HCOM 调试助手',
        debugShowCheckedModeBanner: false,
        theme: HcomTheme.light(),
        darkTheme: HcomTheme.dark(),
        themeMode: _themeMode,
        themeAnimationDuration: const Duration(milliseconds: 200),
        themeAnimationCurve: Easing.standard,
        home: WorkbenchScreen(
          isDark: _themeMode == ThemeMode.dark,
          onThemeChanged: () => _setStartupTheme(_themeMode != ThemeMode.dark),
          onStartupThemeChanged: _setStartupTheme,
        ),
      );
}
