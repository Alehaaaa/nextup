import 'package:flutter/material.dart';

import '../services/desktop_update_installer.dart';
import '../services/update_service.dart';

/// Downloads and installs [release] on macOS, Windows or Linux behind a
/// progress dialog. On success the app quits and the new build opens; on
/// failure the dialog closes and the returned message says why (null when
/// the app is already on its way out).
Future<String?> installDesktopUpdate(
  BuildContext context,
  AppRelease release,
) async {
  final progress = ValueNotifier<double?>(null);
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('Updating to ${release.displayLabel}'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: value),
              const SizedBox(height: 12),
              Text(
                value == null || value < 1
                    ? 'Downloading the new build…'
                    : 'Installing. Nextup will close and reopen.',
              ),
            ],
          ),
        ),
      ),
    ),
  ).whenComplete(() => open = false);
  try {
    await DesktopUpdateInstaller.install(
      release,
      onProgress: (value) => progress.value = value,
    );
    return null;
  } on DesktopUpdateException catch (error) {
    return error.message;
  } catch (_) {
    return 'Could not install the update. Please try again later.';
  } finally {
    if (open && navigator.mounted) navigator.pop();
    progress.dispose();
  }
}
