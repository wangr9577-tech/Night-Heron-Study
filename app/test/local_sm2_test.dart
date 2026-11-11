import 'package:flutter_test/flutter_test.dart';
import 'package:zhi_ai/local_sm2.dart';

void main() {
  test('SM-2 intervals and ease follow the existing B8 rules', () {
    var state = nextReview(
      repetitions: 0,
      intervalDays: 0,
      ease: 2.5,
      quality: 4,
    );
    expect((state.repetitions, state.intervalDays, state.ease), (1, 1, 2.5));
    state = nextReview(
      repetitions: state.repetitions,
      intervalDays: state.intervalDays,
      ease: state.ease,
      quality: 5,
    );
    expect((state.repetitions, state.intervalDays, state.ease), (2, 6, 2.6));
    state = nextReview(
      repetitions: state.repetitions,
      intervalDays: state.intervalDays,
      ease: state.ease,
      quality: 4,
    );
    expect((state.repetitions, state.intervalDays, state.ease), (3, 16, 2.6));
    state = nextReview(
      repetitions: state.repetitions,
      intervalDays: state.intervalDays,
      ease: state.ease,
      quality: 2,
    );
    expect((state.repetitions, state.intervalDays, state.ease), (0, 1, 2.28));
    expect(
      () => nextReview(repetitions: 0, intervalDays: 0, ease: 2.5, quality: 6),
      throwsArgumentError,
    );
  });
}
