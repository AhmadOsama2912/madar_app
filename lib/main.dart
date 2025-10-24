import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:madar_app/homepage.dart';
import 'package:madar_app/Auth/register_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load stored token
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('token');

  runApp(MyApp(hasToken: token != null && token.isNotEmpty));
}

class MyApp extends StatelessWidget {
  final bool hasToken;
  const MyApp({super.key, required this.hasToken});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Madar App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
        fontFamily: 'NunitoSans',
      ),
      // Decide which page to open based on token
      home: hasToken ? const HomePage() : RegisterPage(),
    );
  }
}
