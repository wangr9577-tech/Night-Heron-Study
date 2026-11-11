import 'package:flutter/material.dart';

import 'local_courses.dart';
import 'local_review.dart';
import 'readable_text.dart';

class LocalReviewPage extends StatefulWidget {
  const LocalReviewPage({super.key, required this.courseId});
  final int courseId;
  @override
  State<LocalReviewPage> createState() => _LocalReviewPageState();
}

class _LocalReviewPageState extends State<LocalReviewPage> {
  LocalCourses? store;
  LocalReview? review;
  List<Map<String, Object?>> items = [];
  String? error;
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final opened = await LocalCourses.open();
      if (!mounted) {
        await opened.close();
        return;
      }
      store = opened;
      review = LocalReview(opened.db, widget.courseId);
      await _reload();
    } catch (_) {
      if (mounted) setState(() => error = '无法读取复习计划');
    }
  }

  Future<void> _reload() async {
    final result = await review!.all();
    if (mounted) setState(() => items = result);
  }

  @override
  void dispose() {
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地间隔复习')),
    body: store == null
        ? Center(child: Text(error ?? '正在读取…'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('查看答案后按记忆情况自评，系统据此安排下次复习。这是个人学习提醒，不作为自动掌握度或积分。'),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('还没有复习项目。可从自测题中加入。'),
                ),
              ...items.map((item) {
                final due = DateTime.parse(item['due_at'] as String).toLocal();
                final isDue = !due.isAfter(DateTime.now());
                final when =
                    '${due.year}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')} ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
                return Card(
                  child: ListTile(
                    title: Text(
                      item['prompt'] as String,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(isDue ? '现在可以复习' : '下次复习：$when'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: isDue
                        ? () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => LocalReviewCard(
                                  review: review!,
                                  item: item,
                                ),
                              ),
                            );
                            if (mounted) await _reload();
                          }
                        : null,
                  ),
                );
              }),
            ],
          ),
  );
}

class LocalReviewCard extends StatefulWidget {
  const LocalReviewCard({super.key, required this.review, required this.item});
  final LocalReview review;
  final Map<String, Object?> item;
  @override
  State<LocalReviewCard> createState() => _LocalReviewCardState();
}

class _LocalReviewCardState extends State<LocalReviewCard> {
  bool revealed = false, busy = false;
  Future<void> rate(int quality) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final schedule = await widget.review.rate(
        widget.item['question_id'] as int,
        quality,
      );
      if (mounted) Navigator.pop(context, schedule.intervalDays);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法记录复习，可能尚未到复习时间')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('自评复习')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ReadingText(widget.item['prompt'] as String, selectable: true),
        const SizedBox(height: 20),
        if (!revealed)
          FilledButton(
            onPressed: () => setState(() => revealed = true),
            child: const Text('查看参考答案'),
          ),
        if (revealed) ...[
          ReadingText('参考答案：${widget.item['answer']}', selectable: true),
          if ((widget.item['explanation'] as String).isNotEmpty)
            ReadingText('解析：${widget.item['explanation']}', selectable: true),
          const SizedBox(height: 16),
          const Text('回想自己在看答案前的记忆情况：'),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => rate(1),
                child: const Text('忘记了'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => rate(3),
                child: const Text('有困难'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => rate(4),
                child: const Text('记得'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => rate(5),
                child: const Text('很熟悉'),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}
