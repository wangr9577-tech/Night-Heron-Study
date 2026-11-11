import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhi_ai/pet_avatar.dart';

Future<Uint8List> pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('capture')),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    image.dispose();
    return bytes;
  }))!;
}

void main() {
  testWidgets('built-in bird visibly animates and is accessible', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: RepaintBoundary(key: Key('capture'), child: MiniPetAvatar()),
        ),
      ),
    );
    await tester.pump();
    final first = await pixels(tester);
    await tester.pump(const Duration(milliseconds: 450));
    final second = await pixels(tester);
    expect(listEquals(first, second), isFalse);
    expect(find.bySemanticsLabel('动态宠物'), findsOneWidget);
  });

  testWidgets('colour can be changed without image assets', (tester) async {
    Widget pet(String key) => MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: const Key('capture'),
          child: MiniPetAvatar(avatarKey: key),
        ),
      ),
    );
    await tester.pumpWidget(pet('bird_1'));
    await tester.pump();
    final yellow = await pixels(tester);
    await tester.pumpWidget(pet('bird_blue'));
    await tester.pump();
    final blue = await pixels(tester);
    expect(listEquals(yellow, blue), isFalse);
  });

  testWidgets(
    'built-in night heron keeps crown, red eye and grey-white plumage',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: RepaintBoundary(key: Key('capture'), child: MiniPetAvatar()),
          ),
        ),
      );
      await tester.pump();
      final image = await pixels(tester);
      bool contains(int r, int g, int b) {
        for (var i = 0; i < image.length; i += 4) {
          if (image[i] == r &&
              image[i + 1] == g &&
              image[i + 2] == b &&
              image[i + 3] == 255)
            return true;
        }
        return false;
      }

      expect(contains(32, 42, 50), isTrue, reason: 'black crown');
      expect(contains(204, 68, 72), isTrue, reason: 'red eye');
      expect(contains(185, 199, 202), isTrue, reason: 'grey plumage');
      expect(contains(241, 238, 228), isTrue, reason: 'white chest');
    },
  );

  testWidgets('reduced motion preference keeps the built-in pet still', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Center(
            child: RepaintBoundary(key: Key('capture'), child: MiniPetAvatar()),
          ),
        ),
      ),
    );
    await tester.pump();
    final first = await pixels(tester);
    await tester.pump(const Duration(milliseconds: 450));
    expect(listEquals(first, await pixels(tester)), isTrue);
  });

  testWidgets('built-in heron supports directional and expressive states', (
    tester,
  ) async {
    Widget pet(PetMotion motion) => MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: const Key('capture'),
          child: MiniPetAvatar(motion: motion),
        ),
      ),
    );
    await tester.pumpWidget(pet(PetMotion.idle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    final idle = await pixels(tester);
    for (final motion in [
      PetMotion.runningLeft,
      PetMotion.waving,
      PetMotion.jumping,
      PetMotion.failed,
      PetMotion.waiting,
      PetMotion.running,
      PetMotion.review,
    ]) {
      await tester.pumpWidget(pet(motion));
      await tester.pump();
      expect(
        listEquals(idle, await pixels(tester)),
        isFalse,
        reason: '$motion should have a distinct pose',
      );
    }
  });

  testWidgets('invalid atlas falls back safely', (tester) async {
    String? warning;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: MiniPetAvatar(
            spriteBytes: Uint8List.fromList([1, 2, 3]),
            onAtlasError: (message) => warning = message,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();
    expect(warning, contains('内置形象'));
    expect(find.byKey(const Key('mini-pet-paint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('valid atlas advances frames and selects the requested state', (
    tester,
  ) async {
    final atlas = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1536, 1872),
        Paint()..color = Colors.red,
      );
      canvas.drawRect(
        const Rect.fromLTWH(192, 0, 192, 208),
        Paint()..color = Colors.green,
      );
      canvas.drawRect(
        const Rect.fromLTWH(0, 624, 1536, 208),
        Paint()..color = Colors.blue,
      );
      final image = await recorder.endRecording().toImage(1536, 1872);
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      return data;
    }))!;
    Widget pet(PetMotion motion) => MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: const Key('capture'),
          child: MiniPetAvatar(spriteBytes: atlas, motion: motion),
        ),
      ),
    );
    await tester.pumpWidget(pet(PetMotion.idle));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    final idle = await pixels(tester);
    final center = (72 * 144 + 72) * 4;
    expect(idle.sublist(center, center + 4), [244, 67, 54, 255]);
    await tester.pump(const Duration(milliseconds: 450));
    final next = await pixels(tester);
    expect(next.sublist(center, center + 4), [76, 175, 80, 255]);
    await tester.pumpWidget(pet(PetMotion.waving));
    await tester.pump();
    final wave = await pixels(tester);
    expect(wave.sublist(center, center + 4), [33, 150, 243, 255]);
    expect(tester.takeException(), isNull);
  });
}
