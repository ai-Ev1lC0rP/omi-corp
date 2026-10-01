import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/startup_error_app.dart';

void main() {
  testWidgets('shows the startup exception text', (tester) async {
    final error = StateError(
      'Mobile profile production requires Firebase project based-hardware, '
      'but the app was initialized with cason-omi.',
    );

    await tester.pumpWidget(StartupErrorApp(error: error, stackTrace: StackTrace.current));

    expect(find.text(StartupErrorApp.title), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && (widget.data ?? '').contains('initialized with cason-omi'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders without a stack trace', (tester) async {
    await tester.pumpWidget(const StartupErrorApp(error: 'boom'));

    expect(find.text(StartupErrorApp.title), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is SelectableText && widget.data == 'boom'), findsOneWidget);
  });
}
