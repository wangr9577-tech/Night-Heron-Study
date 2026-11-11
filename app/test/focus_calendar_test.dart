import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhi_ai/focus_page.dart';

void main() {
  testWidgets('calendar aligns weeks and exposes duration for screen readers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SingleChildScrollView(
              child: FocusCalendar(
                today: DateTime(2026, 11, 9),
                days: const {'2026-11-9': 25},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('一'), findsOneWidget);
    expect(find.text('日'), findsOneWidget);
    expect(find.bySemanticsLabel('2026 年 11 月 9 日，专注 25 分钟'), findsOneWidget);
    expect(find.bySemanticsLabel('2026 年 11 月 10 日，未来日期'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
