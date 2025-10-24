// lib/realtime_test_screen.dart
import 'package:flutter/material.dart';
import 'core/realtime.dart';

class RealtimeTestScreen extends StatefulWidget {
  const RealtimeTestScreen({super.key});

  @override
  State<RealtimeTestScreen> createState() => _RealtimeTestScreenState();
}

class _RealtimeTestScreenState extends State<RealtimeTestScreen> {
  PlaylistSnapshot? _snap;

  @override
  void initState() {
    super.initState();
    RealtimeManager.I.stream.listen((s) {
      setState(() => _snap = s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated: ${s.contentVersion} (items: ${s.items.length})')),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snap;
    return Scaffold(
      appBar: AppBar(title: const Text('Realtime Test')),
      body: Center(
        child: (snap == null)
            ? const Text('Waiting for data...')
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Version: ${snap.contentVersion}', style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 10),
                  Text('Items: ${snap.items.length}', style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 20),
                  Expanded(
                    child: ListView.builder(
                      itemCount: snap.items.length,
                      itemBuilder: (_, i) {
                        final it = snap.items[i];
                        return ListTile(
                          dense: true,
                          title: Text(it['type']?.toString() ?? '-'),
                          subtitle: Text(it['url']?.toString() ?? ''),
                          trailing: Text('${it['duration_sec'] ?? 0}s'),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
