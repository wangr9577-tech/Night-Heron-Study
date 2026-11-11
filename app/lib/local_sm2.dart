import 'dart:math' as math;

class ReviewSchedule {
  const ReviewSchedule(this.repetitions, this.intervalDays, this.ease);
  final int repetitions;
  final int intervalDays;
  final double ease;
}

/// Same interval and rounding rules as the existing B8 SM-2 implementation.
ReviewSchedule nextReview({
  required int repetitions,
  required int intervalDays,
  required double ease,
  required int quality,
}) {
  if (repetitions < 0 ||
      intervalDays < 0 ||
      !ease.isFinite ||
      ease < 1.3 ||
      quality < 0 ||
      quality > 5) {
    throw ArgumentError('复习参数无效');
  }
  final nextEase = math.max(
    1.3,
    ease + .1 - (5 - quality) * (.08 + (5 - quality) * .02),
  );
  final rounded = double.parse(nextEase.toStringAsFixed(4));
  if (quality < 3) return ReviewSchedule(0, 1, rounded);
  final interval = repetitions == 0
      ? 1
      : repetitions == 1
      ? 6
      : math.max(1, (intervalDays * ease).ceil());
  return ReviewSchedule(repetitions + 1, interval, rounded);
}
