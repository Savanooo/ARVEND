import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/update/apk_installer.dart';
import 'package:arvend/core/update/app_release.dart';
import 'package:arvend/core/update/update_repository.dart';
import 'package:arvend/core/update/update_service.dart';

/// Sözleşme örneği (bkz. HANDOFF / backend app-version handler).
const kSha = 'a3f1c2d4e5b6a7980112233445566778899aabbccddeeff00112233445566778';

Map<String, dynamic> releaseJson({
  int build = 3,
  String version = '1.2.0',
  String sha256 = kSha,
  int size = 62418702,
  String notes = 'Uzaktan güncelleme eklendi.',
  int minBuild = 0,
  String publishedAt = '2026-09-28T09:30:00Z',
}) =>
    {
      'platform': 'android',
      'build': build,
      'version': version,
      'sha256': sha256,
      'size': size,
      'notes': notes,
      'min_build': minBuild,
      'published_at': publishedAt,
    };

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

AppRelease releaseFor(
  List<int> bytes, {
  int build = 3,
  int minBuild = 0,
  String? sha256,
  int? size,
  String version = '1.2.0',
  String notes = 'Yenilikler',
}) =>
    AppRelease(
      platform: 'android',
      build: build,
      version: version,
      sha256: sha256 ?? sha256Hex(bytes),
      size: size ?? bytes.length,
      notes: notes,
      minBuild: minBuild,
    );

/// Gerçek ağ yerine verilen baytları dosyaya yazar (ya da verilen hatayı
/// fırlatır).
class FakeDownloader implements UpdateDownloader {
  FakeDownloader({this.bytes = const [], this.error});

  List<int> bytes;
  Object? error;
  int calls = 0;
  final List<String> savePaths = [];
  final List<String> expectedShas = [];

  @override
  Future<void> download(
    String savePath, {
    required String expectedSha256,
    required void Function(int received, int total) onProgress,
    required CancelToken cancelToken,
  }) async {
    calls++;
    savePaths.add(savePath);
    expectedShas.add(expectedSha256);
    final e = error;
    if (e != null) throw e;
    final half = bytes.length ~/ 2;
    await File(savePath).writeAsBytes(bytes.sublist(0, half));
    onProgress(half, bytes.length);
    if (cancelToken.isCancelled) {
      throw const ApiException(statusCode: null, message: 'iptal', kind: ApiErrorKind.network);
    }
    await File(savePath).writeAsBytes(bytes);
    onProgress(bytes.length, bytes.length);
  }
}

class FakeInstaller implements ApkInstaller {
  FakeInstaller({List<ApkInstallResult>? results}) : results = results ?? [ApkInstallResult.opened];

  final List<ApkInstallResult> results;
  final List<String> installedPaths = [];
  int settingsOpened = 0;

  @override
  Future<ApkInstallResult> install(String apkPath) async {
    installedPaths.add(apkPath);
    return results.length > 1 ? results.removeAt(0) : results.first;
  }

  @override
  Future<void> openInstallPermissionSettings() async => settingsOpened++;
}

/// Widget testleri için: dosya sistemi/isolate kullanmadan UpdateInstallService
/// davranışını senaryolar (FakeAsync içinde gerçek dosya G/Ç tamamlanmaz).
class FakeInstallService implements UpdateInstallService {
  FakeInstallService({this.prepareError, List<Object>? prepareErrors, this.installResults, this.holdDownload = false})
      : prepareErrors = prepareErrors ?? [];

  Object? prepareError;

  /// Sırayla tüketilen hatalar (ilk denemeler); bitince [prepareError].
  final List<Object> prepareErrors;
  List<ApkInstallResult>? installResults;

  /// true: prepare ilerlemeyi yarıda bildirir ve iptal edilene kadar bekler.
  final bool holdDownload;

  int prepareCalls = 0;
  int installCalls = 0;
  int settingsOpened = 0;
  CancelToken? lastToken;

  /// prepare'e verilen sürümler (build'ler), sırayla.
  final List<int> preparedBuilds = [];

  @override
  Future<File> prepare(
    AppRelease release, {
    required CancelToken cancelToken,
    void Function(int received, int total)? onProgress,
    VoidCallback? onVerifying,
  }) async {
    prepareCalls++;
    preparedBuilds.add(release.build);
    lastToken = cancelToken;
    if (holdDownload) {
      onProgress?.call(release.size ~/ 2, release.size);
      await cancelToken.whenCancel;
      throw const UpdateCancelled();
    }
    onProgress?.call(release.size, release.size);
    onVerifying?.call();
    final e = prepareErrors.isNotEmpty ? prepareErrors.removeAt(0) : prepareError;
    if (e != null) throw e;
    return File('/cache/app-update/${UpdateInstallService.fileNameFor(release)}');
  }

  @override
  Future<ApkInstallResult> install(File apk) async {
    installCalls++;
    final results = installResults ?? [ApkInstallResult.opened];
    return results.length > 1 ? results.removeAt(0) : results.first;
  }

  @override
  Future<void> openInstallPermissionSettings() async => settingsOpened++;

  @override
  Future<void> cleanup({int? keepBuild}) async {}
}
