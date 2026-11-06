import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:zhi_ai/main.dart';

void main() {
  testWidgets('login and registration screens are available', (tester) async {
    await tester.pumpWidget(const ZhiApp());
    expect(find.text('啄知 AI'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    await tester.tap(find.text('创建账号'));
    await tester.pump();
    expect(find.text('注册'), findsOneWidget);
  });
  testWidgets('upload page explains the service limitation', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: UploadPage(courseId: 'course', mistake: false)));
    expect(find.text('处理服务尚待接入'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
  });
  testWidgets('exam page explains the service limitation', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: ExamWorkflow(courseId: 'course', materialId: 'material')));
    expect(find.text('试卷服务尚待接入'), findsOneWidget);
    expect(find.text('导入试卷'), findsOneWidget);
  });
}
