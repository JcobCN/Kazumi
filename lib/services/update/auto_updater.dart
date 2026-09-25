import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/update/windows_portable_updater.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/date_time.dart';
import 'package:kazumi/utils/crypto.dart';
import 'package:kazumi/utils/version.dart';

enum InstallationType {
  windowsMsix,
  windowsPortable,
  linuxDeb,
  linuxTar,
  macosDmg,
  androidApk,
  ios,
  unknown,
}

class UpdateInfo {
  final String version;
  final String description;
  final String downloadUrl;
  final String releaseNotes;
  final String publishedAt;
  final InstallationType? installationType;
  final List<InstallationType> availableInstallationTypes;
  final List<dynamic> assets;

  UpdateInfo({
    required this.version,
    required this.description,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.publishedAt,
    this.installationType,
    this.availableInstallationTypes = const [],
    this.assets = const [],
  });
  InstallationType get recommendedInstallationType {
    if (availableInstallationTypes.isNotEmpty) {
      return availableInstallationTypes.first;
    }
    return installationType ?? InstallationType.unknown;
  }
}

Map<String, dynamic>? getUpdateAssetForType(
    List<dynamic> assets, InstallationType type) {
  final patterns = getUpdateFilePatterns(type).map((p) => p.toLowerCase());

  try {
    final asset = assets.cast<Map<String, dynamic>>().firstWhere((asset) {
      final name = (asset['name'] as String?)?.toLowerCase() ?? '';
      return patterns.every((pattern) => name.contains(pattern));
    });
    return asset;
  } catch (_) {
    return null;
  }
}

String getUpdateDownloadUrlFromAsset(Map<String, dynamic>? asset) {
  if (asset == null) {
    return '';
  }
  final mirrorUrl = asset['mirror_download_url'] as String? ?? '';
  if (mirrorUrl.isNotEmpty) {
    return mirrorUrl;
  }
  return asset['browser_download_url'] as String? ?? '';
}

String getUpdateFileHashFromAsset(Map<String, dynamic> asset) {
  final digest = asset['digest'] as String? ?? '';
  if (digest.startsWith('sha256:')) {
    return digest.substring(7);
  }
  return '';
}

List<String> getUpdateFilePatterns(InstallationType installationType) {
  switch (installationType) {
    case InstallationType.windowsMsix:
      return ['windows', '.msix'];
    case InstallationType.windowsPortable:
      return ['windows', '.zip'];
    case InstallationType.macosDmg:
      return ['macos', '.dmg'];
    case InstallationType.androidApk:
      return ['android', '.apk'];
    case InstallationType.linuxDeb:
    case InstallationType.linuxTar:
    case InstallationType.ios:
    case InstallationType.unknown:
      return [];
  }
}

class AutoUpdater {
  static final AutoUpdater _instance = AutoUpdater._internal();

  factory AutoUpdater() => _instance;

  AutoUpdater._internal();

  final DownloadHttpClient _downloadClient = DownloadHttpClient.instance;
  final WindowsPortableUpdater _windowsPortableUpdater =
      const WindowsPortableUpdater();
  bool _isAutoUpdating = false;

  bool _isPortableWindowsInstallation() {
    // A debug/profile process is commonly Dart/Flutter itself rather than the
    // bundled Kazumi executable, so never hand it to the release updater.
    if (!kReleaseMode || !Platform.isWindows) return false;

    final executablePath =
        Platform.resolvedExecutable.replaceAll('\\', '/').toLowerCase();
    final segments = executablePath.split('/');
    // MSIX applications are installed below WindowsApps and cannot be
    // replaced by a portable bundle updater. Unpacked/ZIP builds can be
    // replaced in place after the running process exits.
    return !segments.contains('windowsapps');
  }

  bool _hasPortableWindowsUpdateAsset(UpdateInfo updateInfo) {
    final asset = getUpdateAssetForType(
      updateInfo.assets,
      InstallationType.windowsPortable,
    );
    if (asset == null) return false;
    return getUpdateDownloadUrlFromAsset(asset).isNotEmpty &&
        getUpdateFileHashFromAsset(asset).isNotEmpty;
  }

  List<InstallationType> _detectAvailableInstallationTypes() {
    if (Platform.isWindows) {
      // A portable bundle can be replaced in place by the detached updater.
      // Keep MSIX first for packaged installations because Windows owns their
      // files and they must be updated through the package installer.
      return _isPortableWindowsInstallation()
          ? [InstallationType.windowsPortable, InstallationType.windowsMsix]
          : [InstallationType.windowsMsix, InstallationType.windowsPortable];
    }
    if (Platform.isLinux) {
      return [InstallationType.linuxDeb, InstallationType.linuxTar];
    }
    if (Platform.isMacOS) return [InstallationType.macosDmg];
    if (Platform.isIOS) return [InstallationType.ios];
    if (Platform.isAndroid) return [InstallationType.androidApk];
    return [InstallationType.unknown];
  }

  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final data = await _latestRelease();

      if (!data.containsKey('tag_name')) {
        throw Exception('无效的响应数据');
      }

      final remoteVersion = data['tag_name'] as String;
      final currentVersion = ApiEndpoints.version;

      if (needUpdate(currentVersion, remoteVersion)) {
        final availableTypes = _detectAvailableInstallationTypes();

        return UpdateInfo(
          version: remoteVersion,
          description: data['body'] ?? '发现新版本',
          downloadUrl: '',
          releaseNotes: data['html_url'] ?? '',
          publishedAt: data['published_at'] ?? '',
          installationType: availableTypes.first,
          availableInstallationTypes: availableTypes,
          assets: data['assets'] ?? [],
        );
      }

      return null;
    } catch (e) {
      KazumiLogger().e('Update: check for updates failed', error: e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _latestRelease() async {
    // The update endpoint is intentionally the configured fork repository;
    // keep all release metadata and assets on the same source.
    final raw = await _downloadClient.getPlain(ApiEndpoints.latestApp);
    final data = json.decode(raw);
    if (data is! Map) {
      throw Exception('Invalid update response');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<void> autoCheckForUpdates() async {
    final autoUpdate = GStorage.getSetting(SettingsKeys.autoUpdate);
    if (!autoUpdate) return;

    try {
      final updateInfo = await checkForUpdates();
      if (updateInfo == null) return;

      // Portable Windows builds cannot update their own executable while it is
      // running. Download the ZIP silently, hand it to a detached updater,
      // then let that updater replace the complete bundle after this process
      // exits. Packaged/MSIX installations still use the normal installer UI.
      if (Platform.isWindows &&
          _isPortableWindowsInstallation() &&
          _hasPortableWindowsUpdateAsset(updateInfo)) {
        await _autoInstallWindowsPortableUpdate(updateInfo);
      } else {
        _showUpdateDialog(updateInfo, isAutoCheck: true);
      }
    } catch (e) {
      KazumiLogger().w('Update: auto check for updates failed', error: e);
    }
  }

  Future<void> manualCheckForUpdates() async {
    try {
      final updateInfo = await checkForUpdates();
      if (updateInfo != null) {
        _showUpdateDialog(updateInfo, isAutoCheck: false);
      } else {
        KazumiDialog.showToast(message: '当前已经是最新版本！');
      }
    } catch (e) {
      KazumiDialog.showToast(message: '检查更新失败');
    }
  }

  Future<void> _autoInstallWindowsPortableUpdate(UpdateInfo updateInfo) async {
    if (_isAutoUpdating) return;
    _isAutoUpdating = true;

    try {
      final asset = getUpdateAssetForType(
          updateInfo.assets, InstallationType.windowsPortable);
      final downloadUrl = getUpdateDownloadUrlFromAsset(asset);
      if (asset == null || downloadUrl.isEmpty) {
        throw StateError('没有找到 Windows 便携版 ZIP 更新包');
      }

      final expectedHash = getUpdateFileHashFromAsset(asset);
      if (expectedHash.isEmpty) {
        throw StateError('更新包缺少 SHA-256 校验值');
      }
      final archivePath = await _downloadFile(
        downloadUrl,
        updateInfo.version,
        expectedHash,
        CancelToken(),
      );
      final executablePath = Platform.resolvedExecutable;

      await _windowsPortableUpdater.schedule(
        archivePath: archivePath,
        executablePath: executablePath,
      );

      KazumiLogger().i(
        'Update: portable Windows update is ready; handing off to detached updater',
      );
      KazumiDialog.showToast(message: '新版本已下载，正在自动安装并重启应用');

      // Give the toast a frame to render and the detached process time to
      // receive its arguments before this process exits.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e, stackTrace) {
      _isAutoUpdating = false;
      KazumiLogger().w(
        'Update: automatic portable Windows installation failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void _showUpdateDialog(UpdateInfo updateInfo, {bool isAutoCheck = false}) {
    KazumiDialog.show(
      builder: (context) {
        return AlertDialog(
          title: Text('发现新版本 ${updateInfo.version}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(updateInfo.description),
                if (updateInfo.publishedAt.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '发布时间: ${formatDate(updateInfo.publishedAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                if (!Platform.isLinux && !Platform.isIOS) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '选择安装类型:',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 8),
                        ...updateInfo.availableInstallationTypes.map((type) {
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () {
                                  KazumiDialog.dismiss();
                                  _downloadUpdateWithType(updateInfo, type);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline
                                          .withValues(alpha: 0.3),
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.download,
                                        size: 16,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _getInstallationTypeDescription(type),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ),
                                      Icon(
                                        Icons.arrow_forward_ios,
                                        size: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (isAutoCheck)
              TextButton(
                onPressed: () {
                  GStorage.putSetting(SettingsKeys.autoUpdate, false);
                  KazumiDialog.dismiss();
                  KazumiDialog.showToast(message: '已关闭自动更新');
                },
                child: Text(
                  '关闭自动更新',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            TextButton(
              onPressed: () => KazumiDialog.dismiss(),
              child: Text(
                '稍后提醒',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            if (updateInfo.releaseNotes.isNotEmpty)
              TextButton(
                onPressed: () {
                  launchUrl(Uri.parse(updateInfo.releaseNotes),
                      mode: LaunchMode.externalApplication);
                },
                child: const Text('查看详情'),
              ),
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss();
                if (updateInfo.availableInstallationTypes.isNotEmpty) {
                  _downloadUpdateWithType(
                      updateInfo, updateInfo.availableInstallationTypes.first);
                }
              },
              child: const Text('立即更新'),
            ),
          ],
        );
      },
    );
  }

  String _getInstallationTypeDescription(InstallationType type) {
    switch (type) {
      case InstallationType.windowsMsix:
        return 'Windows MSIX 包';
      case InstallationType.windowsPortable:
        return 'Windows 便携版 (ZIP)';
      case InstallationType.linuxDeb:
        return 'Linux DEB 包';
      case InstallationType.linuxTar:
        return 'Linux TAR 包';
      case InstallationType.macosDmg:
        return 'macOS DMG 镜像';
      case InstallationType.androidApk:
        return 'Android APK';
      case InstallationType.ios:
        return 'iOS ipa';
      case InstallationType.unknown:
        return '未知安装类型';
    }
  }

  Future<void> _downloadUpdateWithType(
      UpdateInfo updateInfo, InstallationType selectedType) async {
    try {
      if (selectedType == InstallationType.ios ||
          selectedType == InstallationType.linuxDeb ||
          selectedType == InstallationType.linuxTar) {
        String releaseUrl = updateInfo.releaseNotes;
        if (releaseUrl.isEmpty) {
          releaseUrl = ApiEndpoints.latestApp;
        }
        launchUrl(Uri.parse(releaseUrl), mode: LaunchMode.externalApplication);
        return;
      }

      final asset = getUpdateAssetForType(updateInfo.assets, selectedType);
      final downloadUrl = getUpdateDownloadUrlFromAsset(asset);
      if (asset == null || downloadUrl.isEmpty) {
        KazumiDialog.showToast(
            message:
                '没有找到 ${_getInstallationTypeDescription(selectedType)} 的下载链接');
        return;
      }

      final expectedHash = getUpdateFileHashFromAsset(asset);
      final downloadInfo = UpdateInfo(
        version: updateInfo.version,
        description: updateInfo.description,
        downloadUrl: downloadUrl,
        releaseNotes: updateInfo.releaseNotes,
        publishedAt: updateInfo.publishedAt,
        installationType: selectedType,
        availableInstallationTypes: [selectedType],
        assets: updateInfo.assets,
      );

      unawaited(_downloadUpdate(downloadInfo, expectedHash));
    } catch (e) {
      KazumiDialog.showToast(message: '下载失败: ${e.toString()}');
      KazumiLogger().e('Update: download update failed', error: e);
    }
  }

  Future<void> _downloadUpdate(
      UpdateInfo updateInfo, String expectedHash) async {
    if (_downloadDialogs.isRunning) return;
    await _downloadDialogs.run((task) async {
      _downloadProgress.value = 0;
      final cancelToken = CancelToken();
      final downloadPath = await task.loading(
        action: () => _downloadFile(updateInfo.downloadUrl, updateInfo.version,
            expectedHash, cancelToken),
        onCancel: cancelToken.cancel,
        builder: (context) {
          return AlertDialog(
            title: const Text('正在下载更新'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _downloadProgress,
                  builder: (context, value, child) {
                    return Column(
                      children: [
                        LinearProgressIndicator(value: value),
                        const SizedBox(height: 8),
                        Text('${(value * 100).toStringAsFixed(1)}%'),
                      ],
                    );
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => KazumiDialog.dismiss(context: context),
                child: const Text('取消'),
              ),
            ],
          );
        },
      );

      _showDownloadCompleteDialog(downloadPath, updateInfo);
    }, onError: (e, _) {
      String errorMessage = '下载失败';
      if (e.toString().contains('Permission denied') ||
          e.toString().contains('Operation not permitted')) {
        errorMessage = '权限不足，文件已保存到应用临时目录';
      } else if (e.toString().contains('No space left')) {
        errorMessage = '磁盘空间不足';
      } else if (e.toString().contains('Network')) {
        errorMessage = '网络连接错误';
      } else if (e.toString().contains('文件完整性验证失败')) {
        errorMessage = '文件完整性验证失败，可能是网络传输错误';
      }

      KazumiDialog.show(
        builder: (context) {
          return AlertDialog(
            title: const Text('下载失败'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(errorMessage),
                const SizedBox(height: 8),
                Text(
                  '错误详情: ${e.toString()}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => KazumiDialog.dismiss(context: context),
                child: const Text('确定'),
              ),
              TextButton(
                onPressed: () {
                  KazumiDialog.dismiss(context: context);
                  _downloadUpdate(updateInfo, expectedHash);
                },
                child: const Text('重试'),
              ),
            ],
          );
        },
      );

      KazumiLogger().e('Update: download update failed', error: e);
    });
  }

  final ValueNotifier<double> _downloadProgress = ValueNotifier(0.0);
  final _downloadDialogs = KazumiDialogController();

  void _showDownloadCompleteDialog(String filePath, UpdateInfo updateInfo) {
    KazumiDialog.show(
      builder: (context) {
        return AlertDialog(
          title: const Text('下载完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('新版本 ${updateInfo.version} 已下载完成'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '安装过程中应用将会退出',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '文件位置:',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      filePath,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => KazumiDialog.dismiss(),
              child: Text(
                '稍后安装',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            if (isDesktop())
              TextButton(
                onPressed: () {
                  KazumiDialog.dismiss(context: context);
                  _revealInFileManager(filePath);
                },
                child: const Text('打开文件夹'),
              ),
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss();
                _installUpdate(
                    filePath, updateInfo.recommendedInstallationType);
              },
              child: const Text('立即安装'),
            ),
          ],
        );
      },
    );
  }

  Future<String> _downloadFile(String url, String version, String expectedHash,
      CancelToken cancelToken) async {
    // Dio cancellation does not cover filesystem preparation or hash checks.
    void checkCancelled() {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    }

    checkCancelled();
    final fileName = _getFileNameFromUrl(url, version);
    final tempDir = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}akari',
    );
    await tempDir.create(recursive: true);
    checkCancelled();
    final filePath = '${tempDir.path}/$fileName';
    final file = File(filePath);
    if (await file.exists()) {
      try {
        final localHash = await calculateFileHash(file);
        checkCancelled();
        if (localHash == expectedHash) {
          KazumiLogger().i(
              'Update: file already exists and hash verified, skipping download: $filePath');
          _downloadProgress.value = 1.0;
          return filePath;
        } else {
          KazumiLogger().i(
              'Update: file hash mismatch detected (local: $localHash, expected: $expectedHash), deleting and re-downloading');
          await file.delete();
        }
      } catch (e) {
        checkCancelled();
        KazumiLogger().w(
            'Update: file verification failed, deleting and re-downloading',
            error: e);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }

    checkCancelled();

    await _downloadClient.download(
      url,
      filePath,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (!cancelToken.isCancelled && total > 0) {
          _downloadProgress.value = received / total;
        }
      },
    );
    final downloadedHash = await calculateFileHash(file);
    checkCancelled();
    if (downloadedHash != expectedHash) {
      await file.delete();
      throw Exception('文件完整性验证失败: 期望 $expectedHash，实际 $downloadedHash');
    }
    KazumiLogger().i('Update: file downloaded and hash verified: $filePath');

    return filePath;
  }

  void _installUpdate(
      String filePath, InstallationType installationType) async {
    try {
      KazumiDialog.showToast(message: '准备安装更新，应用即将退出...');

      await Future.delayed(const Duration(seconds: 2));

      if (Platform.isWindows) {
        if (installationType == InstallationType.windowsMsix) {
          final Uri fileUri = Uri.file(filePath);
          if (await canLaunchUrl(fileUri)) {
            await launchUrl(fileUri);
          } else {
            throw 'Could not launch $fileUri';
          }
        } else if (installationType == InstallationType.windowsPortable &&
            _isPortableWindowsInstallation()) {
          await _windowsPortableUpdater.schedule(
            archivePath: filePath,
            executablePath: Platform.resolvedExecutable,
          );
        } else {
          // A portable ZIP selected from an MSIX installation is just a
          // different distribution package; do not try to replace the
          // protected WindowsApps directory.
          await Process.start('explorer.exe', [filePath], runInShell: true);
        }
        await Future.delayed(const Duration(seconds: 1));
        exit(0);
      } else if (Platform.isMacOS) {
        if (filePath.endsWith('.dmg')) {
          await Process.start('open', [filePath]);
          exit(0);
        }
      } else if (Platform.isAndroid) {
        final result = await OpenFilex.open(filePath);
        if (result.type != ResultType.done) {
          KazumiDialog.showToast(message: '无法打开安装文件: ${result.message}');
          return;
        }
      }
    } catch (e) {
      KazumiDialog.showToast(message: '启动安装程序失败: ${e.toString()}');
      KazumiLogger().e('Update: launch installer failed', error: e);
    }
  }

  void _revealInFileManager(String filePath) async {
    try {
      final type = await FileSystemEntity.type(filePath);
      String targetDirOrFile;
      if (type == FileSystemEntityType.notFound) {
        KazumiDialog.showToast(message: '文件或目录不存在');
        return;
      } else if (type == FileSystemEntityType.directory) {
        targetDirOrFile = filePath;
      } else {
        targetDirOrFile = File(filePath).parent.path;
      }

      if (Platform.isWindows) {
        if (type == FileSystemEntityType.file) {
          final arg = '/select,${filePath.replaceAll('/', r'\')}';
          await Process.start('explorer.exe', [arg], runInShell: true);
        } else {
          await Process.start(
              'explorer.exe', [targetDirOrFile.replaceAll('/', r'\')],
              runInShell: true);
        }
      } else if (Platform.isMacOS) {
        if (type == FileSystemEntityType.file) {
          await Process.start('open', ['-R', filePath]);
        } else {
          await Process.start('open', [targetDirOrFile]);
        }
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [targetDirOrFile]);
      } else {
        KazumiDialog.showToast(message: '此平台不支持通过此方法打开文件管理器');
      }
    } catch (e) {
      KazumiDialog.showToast(message: '无法打开文件管理器');
      KazumiLogger().w('Update: reveal in file manager failed', error: e);
    }
  }

  String _getFileNameFromUrl(String url, String version) {
    final uri = Uri.parse(url);
    final fileName = uri.pathSegments.last;

    if (fileName.isNotEmpty) {
      return fileName;
    }
    String extension = '';
    if (Platform.isWindows) {
      extension = '.msix';
    } else if (Platform.isMacOS) {
      extension = '.dmg';
    } else if (Platform.isLinux) {
      extension = '.deb';
    } else if (Platform.isAndroid) {
      extension = '.apk';
    }
    return 'Kazumi-$version$extension';
  }
}
