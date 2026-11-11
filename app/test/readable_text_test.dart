import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhi_ai/readable_text.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

void main() {
  testWidgets(
    'Markdown answers use the math-capable renderer on narrow screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const source =
          r'# 准确率'
          '\n\n'
          r'公式：$\frac{TP+TN}{TP+TN+FP+FN}$';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReadingText(source, rich: true, selectable: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final markdown = tester.widget<GptMarkdown>(find.byType(GptMarkdown));
      expect(markdown.data, source);
      expect(markdown.useDollarSignsForLatex, isTrue);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'learning text preserves formulas and wraps on a narrow large-text screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const source =
          '分类准确率 Accuracy\n(TP + TN) / (TP + TN + FP + FN)\n'
          'Precision measures the fraction of positive predictions that are correct.';
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: ReadingText(source)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.data, source);
      expect(text.softWrap, isTrue);
      expect(text.style!.height, 1.6);
      expect(
        MediaQuery.of(tester.element(find.byType(Text))).textScaler.scale(16),
        32,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the selectable variant retains source line breaks', (
    tester,
  ) async {
    const source = '提示：先识别分母。\nRecall = TP / (TP + FN)';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ReadingText(source, selectable: true)),
      ),
    );
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.data, source);
    expect(text.style!.height, 1.6);
    expect(tester.takeException(), isNull);
  });
}
