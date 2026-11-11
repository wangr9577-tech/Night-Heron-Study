import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

class AiExamQuestion {
  AiExamQuestion({
    required this.prompt,
    required this.answer,
    required this.explanation,
    required this.quote,
  });
  String prompt, answer, explanation;
  final String quote;
}

String aiSourceExcerpt(String source) =>
    String.fromCharCodes(source.runes.take(12000));

Future<List<AiExamQuestion>> generateAiExam(
  AiSettings settings,
  String source,
  int count,
  String requirements, {
  http.Client? client,
}) async {
  final excerpt = aiSourceExcerpt(source);
  if (excerpt.trim().isEmpty ||
      count < 1 ||
      count > 10 ||
      requirements.length > 1000) {
    throw ArgumentError('资料、题数或要求无效');
  }
  final response = await settings.ask(
    '请根据资料出 $count 道简短答案题，要求：$requirements。只返回 JSON 对象，格式为 {"questions":[{"prompt":"题目","answer":"简短参考答案","explanation":"解析","source_quote":"资料中的连续原文"}]}。每题的 source_quote 必须逐字引用资料中的连续原文，不要编造；不包含 Markdown 代码块。',
    sourceText: excerpt,
    client: client,
  );
  if (response.length > 100000) throw FormatException('模型返回内容过长');
  var raw = response.trim();
  if (raw.startsWith('```')) {
    raw = raw
        .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '');
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map ||
      decoded['questions'] is! List ||
      (decoded['questions'] as List).length != count)
    throw FormatException('模型返回的题数或格式不正确');
  String field(Map q, String key, int max, {bool required = true}) {
    final v = q[key];
    if (v is! String || (required && v.trim().isEmpty) || v.length > max)
      throw FormatException('模型返回的题目字段无效');
    return v.trim();
  }

  return (decoded['questions'] as List).map((item) {
    if (item is! Map) throw FormatException('模型返回的题目格式不正确');
    final quote = field(item, 'source_quote', 400);
    if (!excerpt.contains(quote)) throw FormatException('模型引用的原文不在发送的资料中，请重试');
    return AiExamQuestion(
      prompt: field(item, 'prompt', 5000),
      answer: field(item, 'answer', 1000),
      explanation: field(item, 'explanation', 5000, required: false),
      quote: quote,
    );
  }).toList();
}
