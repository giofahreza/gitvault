import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<bool> copyTextWithFeedback(
  BuildContext context, {
  required String text,
  required String successMessage,
  String? failureMessage,
  Duration duration = const Duration(seconds: 2),
  EdgeInsetsGeometry? margin,
}) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return true;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(successMessage),
          duration: duration,
          behavior:
              margin == null ? SnackBarBehavior.fixed : SnackBarBehavior.floating,
          margin: margin,
        ),
      );
    return true;
  } catch (_) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            failureMessage ??
                (kIsWeb
                    ? 'Clipboard is blocked by this browser. Copy manually instead.'
                    : 'Could not copy to clipboard. Try again.'),
          ),
          duration: const Duration(seconds: 4),
          behavior:
              margin == null ? SnackBarBehavior.fixed : SnackBarBehavior.floating,
          margin: margin,
        ),
      );
    return false;
  }
}

Future<void> clearClipboardSilently() async {
  try {
    await Clipboard.setData(const ClipboardData(text: ''));
  } catch (_) {}
}
