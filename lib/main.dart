// lib/main.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/realtime.dart';
import 'realtime_test_screen.dart';
import 'homepage.dart';
import 'Auth/register_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('token');
  final base  = prefs.getString('base_origin') ?? 'http://192.168.1.168:8000';
  final ws    = '${Uri.parse(base).scheme}://${Uri.parse(base).host}:8081';

  // Start realtime only if we have a token
  if (token != null && token.isNotEmpty) {
    await RealtimeManager.I.start(apiBase: base, wsUrl: ws);
  }

  runApp(MyApp(hasToken: token != null && token.isNotEmpty));
}

class MyApp extends StatelessWidget {
  final bool hasToken;
  const MyApp({super.key, required this.hasToken});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Madar',
      debugShowCheckedModeBanner: false,
      routes: {
        '/realtime-test': (_) => const RealtimeTestScreen(),
      },
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
        fontFamily: 'NunitoSans',
      ),
      // For normal flow:
      home: hasToken ? const HomePage() : RegisterPage(),

      // For testing realtime quickly, you can use:
      // home: hasToken ? const RealtimeTestScreen() : RegisterPage(),
    );
  }
}
