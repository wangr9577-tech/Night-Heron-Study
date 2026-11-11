import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The first nine rows of a Codex-style atlas. A custom image is optional.
enum PetMotion {
  idle,
  runningRight,
  runningLeft,
  waving,
  jumping,
  failed,
  waiting,
  running,
  review,
}

const _frameCounts = [6, 8, 8, 4, 5, 8, 6, 6, 6];

/// A small animated night heron, or an optional 8-column sprite atlas.
///
/// The atlas is PNG/WebP bytes of 1536×1872 or 1536×2288 pixels. The caller
/// owns persistence and must validate any remotely supplied content server-side.
/// Invalid images fall back to the built-in bird instead of breaking the page.
class MiniPetAvatar extends StatefulWidget {
  final String avatarKey;
  final PetMotion motion;
  final Uint8List? spriteBytes;
  final double size;
  final VoidCallback? onTap;
  final ValueChanged<String>? onAtlasError;

  const MiniPetAvatar({
    super.key,
    this.avatarKey = 'bird_1',
    this.motion = PetMotion.idle,
    this.spriteBytes,
    this.size = 144,
    this.onTap,
    this.onAtlasError,
  });

  @override
  State<MiniPetAvatar> createState() => _MiniPetAvatarState();
}

class _MiniPetAvatarState extends State<MiniPetAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  ui.Image? atlas;
  int generation = 0;
  bool reduceMotion = false;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _load(widget.spriteBytes);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disabled != reduceMotion) {
      reduceMotion = disabled;
      if (disabled) {
        controller.stop();
        controller.value = 0;
      } else {
        controller.repeat();
      }
    }
  }

  @override
  void didUpdateWidget(covariant MiniPetAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.spriteBytes, widget.spriteBytes))
      _load(widget.spriteBytes);
  }

  Future<void> _load(Uint8List? bytes) async {
    final version = ++generation;
    final previous = atlas;
    atlas = null;
    if (mounted && previous != null) setState(() {});
    previous?.dispose();
    if (bytes == null) {
      if (mounted) setState(() {});
      return;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      if (bytes.isEmpty || bytes.lengthInBytes > 8 * 1024 * 1024) {
        throw const FormatException('图片为空或超过 8 MB');
      }
      final png =
          bytes.length >= 8 &&
          const [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ].asMap().entries.every((e) => bytes[e.key] == e.value);
      final webp =
          bytes.length >= 12 &&
          bytes[0] == 82 &&
          bytes[1] == 73 &&
          bytes[2] == 70 &&
          bytes[3] == 70 &&
          bytes[8] == 87 &&
          bytes[9] == 69 &&
          bytes[10] == 66 &&
          bytes[11] == 80;
      if (!png && !webp) throw const FormatException('图集须为 PNG 或 WebP');
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != 1536 ||
          (descriptor.height != 1872 && descriptor.height != 2288)) {
        throw const FormatException('图集须为 1536×1872 或 1536×2288');
      }
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      if (!mounted || generation != version) {
        frame.image.dispose();
        return;
      }
      setState(() => atlas = frame.image);
    } catch (_) {
      if (mounted && generation == version) {
        setState(() => atlas = null);
        final notify = widget.onAtlasError;
        if (notify != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && generation == version) notify('宠物图集不可用，已显示内置形象');
          });
        }
      }
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  @override
  void dispose() {
    generation++;
    controller.dispose();
    atlas?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '动态宠物',
    button: widget.onTap != null,
    child: GestureDetector(
      onTap: widget.onTap,
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          key: const Key('mini-pet-paint'),
          painter: _PetPainter(
            animation: controller,
            avatarKey: widget.avatarKey,
            motion: widget.motion,
            atlas: atlas,
          ),
        ),
      ),
    ),
  );
}

class _PetPainter extends CustomPainter {
  final Animation<double> animation;
  final String avatarKey;
  final PetMotion motion;
  final ui.Image? atlas;

  _PetPainter({
    required this.animation,
    required this.avatarKey,
    required this.motion,
    this.atlas,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final image = atlas;
    final phase = animation.value;
    if (image != null) {
      final row = motion.index;
      final frame = (phase * _frameCounts[row]).floor().clamp(
        0,
        _frameCounts[row] - 1,
      );
      final source = Rect.fromLTWH(frame * 192.0, row * 208.0, 192, 208);
      final fitted = applyBoxFit(BoxFit.contain, const Size(192, 208), size);
      final dest = Alignment.center.inscribe(
        fitted.destination,
        Offset.zero & size,
      );
      canvas.drawImageRect(
        image,
        source,
        dest,
        Paint()..filterQuality = FilterQuality.none,
      );
      return;
    }
    _paintNightHeron(canvas, size, phase);
  }

  void _paintNightHeron(Canvas canvas, Size size, double phase) {
    const outline = Color(0xff29343a);
    const crown = Color(0xff202a32);
    const plumage = Color(0xffb9c7ca);
    const wing = Color(0xff8b9da3);
    const chest = Color(0xfff1eee4);
    const eye = Color(0xffcc4448);
    const legs = Color(0xffb99e69);
    final scarf = switch (avatarKey) {
      'bird_mint' => const Color(0xff84cba5),
      'bird_blue' => const Color(0xff9cc5df),
      'bird_rose' => const Color(0xffeeb5bf),
      _ => const Color(0xffeac778),
    };
    final unit = math.min(size.width / 24, size.height / 26);
    final walking =
        motion == PetMotion.runningRight || motion == PetMotion.runningLeft;
    final bob = motion == PetMotion.jumping
        ? -math.sin(phase * math.pi).abs() * 1.5
        : walking
        ? -math.sin(phase * 2 * math.pi).abs() * .45
        : math.sin(phase * 2 * math.pi) * .45;
    canvas.save();
    canvas.translate(
      (size.width - 24 * unit) / 2,
      (size.height - 26 * unit) / 2 + bob * unit,
    );
    canvas.scale(unit);
    if (motion == PetMotion.runningLeft) {
      canvas.translate(24, 0);
      canvas.scale(-1, 1);
    }
    if (motion == PetMotion.failed || motion == PetMotion.review) {
      canvas.translate(12, 13);
      canvas.rotate(
        motion == PetMotion.failed
            ? -.07
            : math.sin(phase * 2 * math.pi) * .035,
      );
      canvas.translate(-12, -13);
    }
    void pixel(double x, double y, double w, double h, Color color) {
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), Paint()..color = color);
    }

    // A compact side profile: white plume, black crown, grey wings, long bill,
    // red eye and slender legs. Outfit colour is independent of plumage.
    pixel(4, 2, 5, 1, chest);
    pixel(6, 3, 3, 1, chest);
    pixel(8, 3, 8, 1, crown);
    pixel(7, 4, 10, 2, crown);
    pixel(7, 6, 11, 4, outline);
    pixel(8, 6, 9, 4, plumage);
    pixel(10, 9, 7, 2, chest);
    // The black tapered bill extends well beyond the face.
    pixel(17, 7, 5, 2, outline);
    pixel(22, 8, 1, 1, outline);
    pixel(18, 7, 3, .6, plumage);
    final blink = motion == PetMotion.waiting || phase > .91;
    pixel(13, 6, 2, blink ? .6 : 2, eye);
    if (!blink) pixel(14, 6, .7, .7, chest);

    // Short neck and rounded body are pale, with a slate-grey folded wing.
    pixel(8, 10, 9, 2, outline);
    pixel(6, 12, 13, 7, outline);
    pixel(7, 13, 11, 5, plumage);
    pixel(13, 12, 4, 6, chest);
    pixel(7, 18, 10, 2, outline);
    pixel(9, 18, 7, 1, plumage);
    final wingLift = motion == PetMotion.waving && phase < .5
        ? -1.0
        : motion == PetMotion.running && phase < .5
        ? -.65
        : 0.0;
    pixel(5, 13 + wingLift, 6, 4, wing);
    pixel(6, 17 + wingLift, 4, 1, wing);

    // Four colours customise a little scarf while keeping the bird identifiable.
    pixel(9, 10, 8, 2, scarf);
    pixel(8, 11, 3, 4, scarf);
    pixel(8, 14, 2, 1, outline);

    final step = walking && phase >= .5 ? 1.0 : 0.0;
    pixel(9, 19, 1, 5 - step, outline);
    pixel(14, 19, 1, 4 + step, outline);
    pixel(10, 20, .6, 3 - step, legs);
    pixel(15, 20, .6, 2 + step, legs);
    pixel(8, 24 - step, 4, 1, outline);
    pixel(13, 23 + step, 4, 1, outline);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PetPainter oldDelegate) =>
      oldDelegate.avatarKey != avatarKey ||
      oldDelegate.motion != motion ||
      oldDelegate.atlas != atlas;
}
