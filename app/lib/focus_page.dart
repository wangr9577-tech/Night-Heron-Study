import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'focus_store.dart';

class FocusPage extends StatefulWidget {
  const FocusPage({super.key, this.scope = 'local'});
  final String scope;
  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage> {
  FocusStore? store;
  Map<String, Object?>? running;
  DateTime? restEndsAt;
  List<Map<String, Object?>> sessions = [];
  Timer? ticker;
  String category = '学习';
  int minutes = 25;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _init();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _init() async {
    try {
      final opened = await FocusStore.open(scope: widget.scope);
      if (!mounted) {
        await opened.close();
        return;
      }
      store = opened;
      await _reload();
      await _tick();
    } catch (e) {
      if (mounted) setState(() => error = '无法打开专注记录：$e');
    }
  }

  Future<void> _reload() async {
    final active = await store!.active();
    final rest = await store!.activeRest();
    final records = await store!.completed();
    if (mounted)
      setState(() {
        running = active;
        restEndsAt = rest;
        sessions = records;
      });
  }

  Future<void> _tick() async {
    if (!mounted || store == null || busy) return;
    if (running == null) {
      if (restEndsAt == null) return;
      if (!DateTime.now().toUtc().isBefore(restEndsAt!)) {
        busy = true;
        try {
          await _reload();
        } catch (_) {
          if (mounted) setState(() => error = '无法更新休息状态');
        } finally {
          busy = false;
        }
      } else {
        setState(() {});
      }
      return;
    }
    final end = DateTime.parse(running!['started_at'] as String)
        .add(Duration(seconds: running!['duration_seconds'] as int));
    if (!DateTime.now().toUtc().isBefore(end)) {
      busy = true;
      try {
        await store!.complete(running!['id'] as int);
        await _reload();
      } catch (e) {
        if (mounted) setState(() => error = '保存专注记录失败：$e');
      } finally {
        busy = false;
      }
    } else {
      setState(() {});
    }
  }

  Future<void> _start() async {
    if (busy) return;
    busy = true;
    try {
      await store!.start(category, minutes);
      await _reload();
    } catch (e) {
      if (mounted) setState(() => error = '无法开始：$e');
    } finally {
      busy = false;
    }
  }

  Future<void> _cancel() async {
    if (running == null || busy) return;
    busy = true;
    try {
      await store!.cancel(running!['id'] as int);
      await _reload();
    } catch (e) {
      if (mounted) setState(() => error = '无法结束：$e');
    } finally {
      busy = false;
    }
  }

  Future<void> _skipRest() async {
    if (busy || restEndsAt == null) return;
    busy = true;
    try {
      await store!.skipRest();
      await _reload();
    } catch (e) {
      if (mounted) setState(() => error = '无法结束休息：$e');
    } finally {
      busy = false;
    }
  }

  @override
  void dispose() {
    ticker?.cancel();
    store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = running == null
        ? (restEndsAt?.difference(DateTime.now().toUtc()) ??
              Duration(minutes: minutes))
        : DateTime.parse(running!['started_at'] as String)
              .add(Duration(seconds: running!['duration_seconds'] as int))
              .difference(DateTime.now().toUtc());
    final seconds = math.max(0, remaining.inSeconds);
    final totals = <String, int>{};
    final days = <String, int>{};
    for (final row in sessions) {
      final duration = (row['duration_seconds'] as int) ~/ 60;
      final label = row['category'] as String;
      totals[label] = (totals[label] ?? 0) + duration;
      final date = DateTime.parse(row['ended_at'] as String).toLocal();
      final key = '${date.year}-${date.month}-${date.day}';
      days[key] = (days[key] ?? 0) + duration;
    }
    final colors = [Colors.teal, Colors.amber, Colors.indigo, Colors.pink];
    return Scaffold(
      appBar: AppBar(title: const Text('专注与成长')),
      body: store == null
          ? Center(child: Text(error ?? '正在读取专注记录…'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Text(
                  restEndsAt == null ? '给自己一段专注时间' : '专注完成，休息一下',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                ),
                const SizedBox(height: 20),
                if (running == null && restEndsAt != null) ...[
                  const Center(child: Text('休息 5 分钟，不计积分')),
                  OutlinedButton(
                    onPressed: _skipRest,
                    child: const Text('结束休息'),
                  ),
                ] else if (running == null) ...[
                  Wrap(
                    spacing: 8,
                    children: ['学习', '阅读', '练习', '复习']
                        .map(
                          (s) => ChoiceChip(
                            label: Text(s),
                            selected: category == s,
                            onSelected: (_) => setState(() => category = s),
                          ),
                        )
                        .toList(),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [15, 25, 45]
                        .map(
                          (m) => ChoiceChip(
                            label: Text('$m 分钟'),
                            selected: minutes == m,
                            onSelected: (_) => setState(() => minutes = m),
                          ),
                        )
                        .toList(),
                  ),
                  FilledButton(onPressed: _start, child: const Text('开始专注')),
                ] else ...[
                  Center(child: Text('正在专注：${running!['category']}')),
                  OutlinedButton(
                    onPressed: _cancel,
                    child: const Text('放弃本次专注'),
                  ),
                ],
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final calendar = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '最近四周',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        FocusCalendar(days: days),
                      ],
                    );
                    final distribution = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '专注时间分布',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (totals.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text('完成一次专注后，这里会显示统计。'),
                          ),
                        if (totals.isNotEmpty) ...[
                          SizedBox(
                            height: 150,
                            width: double.infinity,
                            child: CustomPaint(
                              painter: _PiePainter(
                                totals.values.toList(),
                                colors,
                              ),
                            ),
                          ),
                          ...totals.entries.indexed.map(
                            (entry) => ListTile(
                              key: ValueKey('focus-category-${entry.$2.key}'),
                              dense: true,
                              leading: Icon(
                                Icons.circle,
                                color: colors[entry.$1 % colors.length],
                              ),
                              title: Text(entry.$2.key),
                              trailing: Text('${entry.$2.value} 分钟'),
                            ),
                          ),
                        ],
                      ],
                    );
                    if (constraints.maxWidth >= 760)
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: calendar),
                          const SizedBox(width: 32),
                          Expanded(child: distribution),
                        ],
                      );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        calendar,
                        const SizedBox(height: 24),
                        distribution,
                      ],
                    );
                  },
                ),
                Text(
                  widget.scope == 'local'
                      ? '专注记录和积分保存在本机，可在宠物页面使用。'
                      : '专注记录保存在本机，服务器积分接入正在完善中。',
                ),
              ],
            ),
    );
  }
}

/// Four Monday-aligned calendar weeks, including the current week.
class FocusCalendar extends StatelessWidget {
  const FocusCalendar({super.key, required this.days, this.today});
  final Map<String, int> days;
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final now = today ?? DateTime.now();
    final date = DateTime(now.year, now.month, now.day);
    final start = DateTime(
      date.year,
      date.month,
      date.day - (date.weekday - 1) - 21,
    );
    return Column(
      children: [
        Row(
          children: [
            '一',
            '二',
            '三',
            '四',
            '五',
            '六',
            '日',
          ].map((day) => Expanded(child: Center(child: Text(day)))).toList(),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
          ),
          itemCount: 28,
          itemBuilder: (context, index) {
            final day = DateTime(start.year, start.month, start.day + index);
            final future = day.isAfter(date);
            final amount = days['${day.year}-${day.month}-${day.day}'] ?? 0;
            final description =
                '${day.year} 年 ${day.month} 月 ${day.day} 日，${future ? '未来日期' : '专注 $amount 分钟'}';
            final background = future
                ? Colors.transparent
                : amount == 0
                ? Colors.grey.shade200
                : Colors.teal.withValues(
                    alpha: amount >= 60 ? 1 : .35 + amount / 100,
                  );
            return Semantics(
              label: description,
              child: Tooltip(
                message: description,
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(5),
                    border: DateUtils.isSameDay(day, date)
                        ? Border.all(color: Colors.teal, width: 2)
                        : null,
                  ),
                  child: ExcludeSemantics(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          color: future
                              ? Colors.grey
                              : amount >= 35
                              ? Colors.white
                              : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _PiePainter extends CustomPainter {
  _PiePainter(this.values, this.colors);
  final List<int> values;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: math.min(size.width, size.height) * .43,
    );
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * 2 * math.pi;
      canvas.drawArc(
        rect,
        start,
        sweep,
        true,
        Paint()..color = colors[i % colors.length],
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter oldDelegate) => true;
}
