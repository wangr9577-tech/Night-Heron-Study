/// A verbatim passage from a locally imported source.
class LocalSearchHit {
  const LocalSearchHit({
    required this.title,
    required this.text,
    required this.score,
  });
  final String title;
  final String text;
  final int score;
}

List<LocalSearchHit> searchLocalRequest(
  (List<Map<String, Object?>>, String) request,
) => searchLocalNotes(request.$1, request.$2);

/// A lightweight lexical search, not a semantic answer or AI generation.
List<LocalSearchHit> searchLocalNotes(
  List<Map<String, Object?>> notes,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty || q.length > 500) return [];
  final terms = <String>{};
  const stopWords = {
    'is',
    'are',
    'the',
    'what',
    'how',
    'why',
    'and',
    'for',
    'with',
    'does',
    '什么',
    '如何',
    '怎么',
    '解释',
    '请问',
    '是否',
    '定义',
    '的是',
    '是什',
    '么是',
  };
  for (final match in RegExp(
    r'[a-z0-9]{2,}|[\u4e00-\u9fff]{2,}',
  ).allMatches(q)) {
    final word = match.group(0)!;
    if (RegExp(r'^[\u4e00-\u9fff]+$').hasMatch(word) && word.length > 2) {
      for (var i = 0; i < word.length - 1 && terms.length < 24; i++) {
        final token = word.substring(i, i + 2);
        if (!stopWords.contains(token)) terms.add(token);
      }
    } else {
      if (!stopWords.contains(word)) terms.add(word);
    }
    if (terms.length >= 24) break;
  }
  if (terms.isEmpty) return [];
  final hits = <LocalSearchHit>[];
  for (final note in notes) {
    final body = note['body'];
    final title = note['title'];
    if (body is! String || title is! String) continue;
    // Slice by code points to keep UTF-16 surrogate pairs intact. Every
    // result is a continuous source substring and does not alter the original.
    final points = body.runes.toList();
    const size = 500;
    const stride = 400;
    for (var i = 0; i < points.length; i += stride) {
      final end = (i + size < points.length) ? i + size : points.length;
      final excerpt = String.fromCharCodes(points.sublist(i, end));
      final haystack = excerpt.toLowerCase();
      final score = terms.where(haystack.contains).length;
      if (score > 0)
        hits.add(LocalSearchHit(title: title, text: excerpt, score: score));
      if (end == points.length) break;
    }
  }
  hits.sort((a, b) => b.score.compareTo(a.score));
  return hits.take(5).toList();
}
