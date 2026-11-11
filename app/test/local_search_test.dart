import 'package:flutter_test/flutter_test.dart';
import 'package:zhi_ai/local_search.dart';

void main() {
  test('search returns exact excerpts and their own source', () {
    const body =
        '📚 机器学习分类模型用于预测类别。\nAccuracy is the fraction of correct predictions.';
    final notes = <Map<String, Object?>>[
      {'title': '讲义', 'body': body},
      {'title': '其他', 'body': '完全无关的材料'},
    ];
    final english = searchLocalNotes(notes, 'What is Accuracy?');
    expect(english, isNotEmpty);
    expect(english.first.title, '讲义');
    expect(body.contains(english.first.text), isTrue);
    expect(english.first.text, contains('📚'));
    final chinese = searchLocalNotes(notes, '分类模型');
    expect(chinese.first.title, '讲义');
    expect(searchLocalNotes(notes, 'quantumxyz'), isEmpty);
    expect(searchLocalNotes(notes, ''), isEmpty);
  });
}
