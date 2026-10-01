import 'package:flutter/material.dart';

/// Minimal fallback app shown when startup (`_init` in `main.dart`) throws.
///
/// Startup failures are usually build or configuration problems (for example a
/// Firebase project or API host that does not match the selected environment
/// profile). Rendering the exception keeps them visible instead of leaving the
/// native launch screen up forever. This widget must not depend on Firebase,
/// providers, localization, or any service that `_init` may have failed to set
/// up.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.stackTrace});

  final Object error;
  final StackTrace? stackTrace;

  static const title = 'Omi failed to start';

  @override
  Widget build(BuildContext context) {
    final stack = stackTrace?.toString().trim() ?? '';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  title,
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  error.toString(),
                  style: const TextStyle(color: Colors.redAccent, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: 24),
                const Text(
                  'This build is misconfigured. Share this message with the developer.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                if (stack.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  SelectableText(
                    stack,
                    style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
