import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme.dart';

/// A link a TV cannot open well itself (a web page: an LG or a Samsung TV's browser, where
/// there is one, opens and closes again), shown as a QR code to open on a phone instead.
Future<void> showLinkQr(BuildContext context, String link, {String title = 'Open it on your phone'}) {
  final host = Uri.tryParse(link)?.host ?? '';
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 180,
            height: 180,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: QrImageView(
              data: link,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              semanticsLabel: 'QR code for the link',
            ),
          ),
          if (host.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(host, style: const TextStyle(color: VyseColors.textDim, fontSize: 13)),
          ],
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
    ),
  );
}
