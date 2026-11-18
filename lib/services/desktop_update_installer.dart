import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:http/http.dart' as http;

import 'update_service.dart';

/// The desktop systems that install a new build by themselves.
enum DesktopUpdatePlatform { macos, windows, linux }

/// Downloads a per-commit build from GitHub and installs it over the running
/// app on macOS, Windows and Linux.
///
/// The running app cannot replace itself, so it writes a small helper script,
/// starts it detached and quits. The helper waits for this process to exit,
/// puts the new build in place and launches it. Nothing is replaced until the
/// download is complete and checked, so a failed download leaves the
/// installed app untouched.
class DesktopUpdateInstaller {
  const DesktopUpdateInstaller._();

  /// This device's desktop system, or null where updates are installed some
  /// other way (Android's package installer, sideloading on Apple devices).
  static DesktopUpdatePlatform? get currentPlatform {
    if (kIsWeb) return null;
    if (Platform.isMacOS) return DesktopUpdatePlatform.macos;
    if (Platform.isWindows) return DesktopUpdatePlatform.windows;
    if (Platform.isLinux) return DesktopUpdatePlatform.linux;
    return null;
  }

  /// The file in [release] that installs on [platform]: the zipped app on
  /// macOS, the installer on Windows, the AppImage on Linux.
  static AppReleaseAsset? assetFor(
    AppRelease release,
    DesktopUpdatePlatform platform,
  ) {
    for (final asset in release.assets) {
      final name = asset.name.toLowerCase();
      final matches = switch (platform) {
        DesktopUpdatePlatform.macos => name.endsWith('-macos.zip'),
        DesktopUpdatePlatform.windows => name.endsWith('-setup.exe'),
        DesktopUpdatePlatform.linux => name.endsWith('-x86_64.appimage'),
      };
      if (matches) return asset;
    }
    return null;
  }

  /// Where the running build lives and would be replaced, or null when it
  /// cannot be replaced in place (a Linux build not run as an AppImage).
  static String? installTarget(DesktopUpdatePlatform platform) {
    switch (platform) {
      case DesktopUpdatePlatform.macos:
        return macosBundleFor(Platform.resolvedExecutable);
      case DesktopUpdatePlatform.windows:
        return Platform.resolvedExecutable;
      case DesktopUpdatePlatform.linux:
        final appImage = Platform.environment['APPIMAGE'];
        return (appImage == null || appImage.isEmpty) ? null : appImage;
    }
  }

  /// `/Applications/Nextup.app` for its `Contents/MacOS/<name>` executable;
  /// null when the executable is not inside an app bundle.
  @visibleForTesting
  static String? macosBundleFor(String executable) {
    final marker = executable.lastIndexOf('.app/Contents/MacOS/');
    if (marker < 0) return null;
    return executable.substring(0, marker + '.app'.length);
  }

  /// Whether [release] can be installed here without leaving the app.
  static bool canInstall(AppRelease release) {
    final platform = currentPlatform;
    if (platform == null) return false;
    return assetFor(release, platform) != null &&
        installTarget(platform) != null;
  }

  /// Downloads [release]'s build for this system, hands it to the helper and
  /// quits the app. [onProgress] gets 0..1 while the file downloads. Throws
  /// [DesktopUpdateException] when anything fails before the app quits; the
  /// installed build is untouched then.
  static Future<void> install(
    AppRelease release, {
    void Function(double progress)? onProgress,
    http.Client? client,
  }) async {
    final platform = currentPlatform;
    if (platform == null) {
      throw const DesktopUpdateException(
        'This device does not install updates by itself.',
      );
    }
    final asset = assetFor(release, platform);
    if (asset == null) {
      throw const DesktopUpdateException(
        'This build has no download for this system yet.',
      );
    }
    final target = installTarget(platform);
    if (target == null) {
      throw const DesktopUpdateException(
        'Only the AppImage can update itself. Download the new build from '
        'the release page.',
      );
    }

    final workDir = await Directory.systemTemp.createTemp('nextup-update-');
    final download = File('${workDir.path}${Platform.pathSeparator}${asset.name}');
    await downloadAsset(asset, download, onProgress: onProgress, client: client);

    final script = File(
      '${workDir.path}${Platform.pathSeparator}'
      '${platform == DesktopUpdatePlatform.windows ? 'install.ps1' : 'install.sh'}',
    );
    await script.writeAsString(switch (platform) {
      DesktopUpdatePlatform.macos => macosScript(
        pid: pid,
        archive: download.path,
        bundle: target,
        workDir: workDir.path,
      ),
      DesktopUpdatePlatform.windows => windowsScript(
        pid: pid,
        installer: download.path,
        executable: target,
      ),
      DesktopUpdatePlatform.linux => linuxScript(
        pid: pid,
        appImage: download.path,
        target: target,
      ),
    });

    if (platform == DesktopUpdatePlatform.windows) {
      await Process.start('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
      ], mode: ProcessStartMode.detached);
    } else {
      await Process.start('/bin/sh', [
        script.path,
      ], mode: ProcessStartMode.detached);
    }
    // The helper replaces this build once the process is gone.
    exit(0);
  }

  /// Streams [asset] to [file], reporting progress, and checks the size
  /// GitHub published so a cut-off download is never installed.
  @visibleForTesting
  static Future<void> downloadAsset(
    AppReleaseAsset asset,
    File file, {
    void Function(double progress)? onProgress,
    http.Client? client,
  }) async {
    final ownClient = client == null;
    final http.Client c = client ?? http.Client();
    try {
      final request = http.Request('GET', asset.downloadUrl)
        ..headers['User-Agent'] = 'nextup-app'
        ..headers['Accept'] = 'application/octet-stream';
      final response = await c.send(request);
      if (response.statusCode != 200) {
        throw DesktopUpdateException(
          'The download failed (HTTP ${response.statusCode}).',
        );
      }
      final total = asset.sizeBytes > 0
          ? asset.sizeBytes
          : (response.contentLength ?? 0);
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }
      if (asset.sizeBytes > 0 && received != asset.sizeBytes) {
        throw const DesktopUpdateException(
          'The download was incomplete. Please try again.',
        );
      }
      onProgress?.call(1);
    } on DesktopUpdateException {
      rethrow;
    } catch (_) {
      throw const DesktopUpdateException(
        'The download failed. Check your connection and try again.',
      );
    } finally {
      if (ownClient) c.close();
    }
  }

  /// Single-quotes [value] for a POSIX shell.
  static String _sh(String value) => "'${value.replaceAll("'", "'\\''")}'";

  /// Single-quotes [value] for PowerShell.
  static String _ps(String value) => "'${value.replaceAll("'", "''")}'";

  /// Waits for [pid] to exit, unpacks the zipped app, swaps it for [bundle]
  /// (keeping the old copy until the new one is in place) and opens it.
  @visibleForTesting
  static String macosScript({
    required int pid,
    required String archive,
    required String bundle,
    required String workDir,
  }) {
    final unpacked = '$workDir/unpacked';
    return '''#!/bin/sh
set -eu
while kill -0 $pid 2>/dev/null; do sleep 0.5; done
rm -rf ${_sh(unpacked)}
/usr/bin/ditto -x -k ${_sh(archive)} ${_sh(unpacked)}
new=\$(/usr/bin/find ${_sh(unpacked)} -maxdepth 1 -name '*.app' | head -n 1)
if [ -z "\$new" ]; then
  /usr/bin/open ${_sh(bundle)}
  exit 1
fi
/usr/bin/xattr -cr "\$new"
old=${_sh('$bundle.previous')}
rm -rf "\$old"
mv ${_sh(bundle)} "\$old"
if /usr/bin/ditto "\$new" ${_sh(bundle)}; then
  rm -rf "\$old"
else
  rm -rf ${_sh(bundle)}
  mv "\$old" ${_sh(bundle)}
fi
/usr/bin/xattr -cr ${_sh(bundle)} || true
/usr/bin/open ${_sh(bundle)}
rm -rf ${_sh(workDir)}
''';
  }

  /// Waits for [pid] to exit, runs the Inno Setup installer silently over
  /// the existing install and starts [executable] again.
  @visibleForTesting
  static String windowsScript({
    required int pid,
    required String installer,
    required String executable,
  }) {
    return '''\$ErrorActionPreference = 'Continue'
Wait-Process -Id $pid -ErrorAction SilentlyContinue
\$setup = Start-Process -FilePath ${_ps(installer)} -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
Start-Process -FilePath ${_ps(executable)}
Remove-Item -LiteralPath ${_ps(installer)} -Force -ErrorAction SilentlyContinue
exit \$setup.ExitCode
''';
  }

  /// Waits for [pid] to exit, moves the new AppImage over [target] and starts
  /// it. The old file stays until the new one is fully in place.
  @visibleForTesting
  static String linuxScript({
    required int pid,
    required String appImage,
    required String target,
  }) {
    final staged = '$target.new';
    return '''#!/bin/sh
set -eu
while kill -0 $pid 2>/dev/null; do sleep 0.5; done
cp ${_sh(appImage)} ${_sh(staged)}
chmod +x ${_sh(staged)}
mv -f ${_sh(staged)} ${_sh(target)}
rm -f ${_sh(appImage)}
if command -v setsid >/dev/null 2>&1; then
  setsid ${_sh(target)} >/dev/null 2>&1 < /dev/null &
else
  nohup ${_sh(target)} >/dev/null 2>&1 < /dev/null &
fi
''';
  }
}

class DesktopUpdateException implements Exception {
  final String message;
  const DesktopUpdateException(this.message);

  @override
  String toString() => message;
}
