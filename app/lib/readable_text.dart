import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Readable, selectable learning text without changing the source string.
///
/// It intentionally leaves the platform text scaler in control and lets
/// Flutter wrap at the available width, including on narrow devices.
class ReadingText extends StatelessWidget {
  const ReadingText(
    this.data, {
    super.key,
    this.style,
    this.selectable = false,
    this.textAlign = TextAlign.start,
    this.rich = false,
  });

  final String data;
  final TextStyle? style;
  final bool selectable;
  final TextAlign textAlign;

  /// Only enable for content produced as Markdown, not raw OCR quotations.
  final bool rich;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final baseStyle = style ?? theme.bodyLarge ?? const TextStyle(fontSize: 16);
    // Keep any semantic emphasis the caller provides while giving text room to
    // breathe. No source whitespace or formula characters are rewritten.
    final effectiveStyle = baseStyle.copyWith(
      height: style?.height ?? 1.6,
      letterSpacing: baseStyle.letterSpacing ?? 0.1,
    );
    if (rich) {
      final content = GptMarkdown(
        data,
        style: effectiveStyle,
        textAlign: textAlign,
        useDollarSignsForLatex: true,
        isStreaming: false,
        autolink: false,
        // Imported documents and model replies must not load remote images
        // implicitly; attachments will need a dedicated local image resolver.
        imageBuilder: (context, imageUrl, width, height) =>
            const Text('[图片暂不可用]'),
      );
      return selectable ? SelectionArea(child: content) : content;
    }
    if (selectable) {
      return SelectableText(data, style: effectiveStyle, textAlign: textAlign);
    }
    return Text(
      data,
      style: effectiveStyle,
      textAlign: textAlign,
      softWrap: true,
    );
  }
}
