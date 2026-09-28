import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/update/apk_installer.dart';
import 'package:arvend/core/update/update_repository.dart';
import 'package:arvend/core/update/update_service.dart';

import '../../test_utils/fake_api_client.dart';
import 'update_fakes.dart';

void main() {
  late Directory base;
  late Directory updateDir;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('arvend_update_test');
    updateDir = Directory('${base.path}/${UpdateInstallService.dirName}');
  });

  tearDown(() async {
    if (await base.exists()) await base.delete(recursive: true);
  });

  List<String> filesInUpdateDir() {
    if (!updateDir.existsSync()) return const [];
    return updateDir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();
  }

  UpdateInstallService service(FakeDownloader downloader, FakeInstaller installer) => UpdateInstallService(
        downloader: downloader,
        installer: installer,
        baseDirectory: () async => base,
      );

  final apkBytes = List<int>.generate(4096, (i) => (i * 31 + 7) % 256);

  group('SHA-256 doğrulaması', () {
    test('özet tutarsa dosya asıl adına taşınır ve kurulum ekranına verilebilir', () async {
      final downloader = FakeDownloader(bytes: apkBytes);
      final installer = FakeInstaller();
      final s = service(downloader, installer);
      final release = releaseFor(apkBytes);

      final progress = <(int, int)>[];
      var verifying = false;
      final apk = await s.prepare(
        release,
        cancelToken: CancelToken(),
        onProgress: (r, t) => progress.add((r, t)),
        onVerifying: () => verifying = true,
      );

      expect(apk.path, '${updateDir.path}/arvend-3.apk');
      expect(await apk.readAsBytes(), apkBytes);
      expect(filesInUpdateDir(), ['arvend-3.apk'], reason: '.part dosyası kalmamalı');
      expect(downloader.savePaths.single, endsWith('arvend-3.apk.part'));
      expect(downloader.expectedShas.single, release.sha256, reason: 'indirici ETag\'i bu özetle karşılaştırır');
      expect(progress.last, (apkBytes.length, apkBytes.length));
      expect(verifying, isTrue);

      expect(await s.install(apk), ApkInstallResult.opened);
      expect(installer.installedPaths, [apk.path]);
    });

    test('özet TUTMAZSA dosya silinir, hata döner ve kurulum ekranı ASLA açılmaz', () async {
      final downloader = FakeDownloader(bytes: apkBytes);
      final installer = FakeInstaller();
      final s = service(downloader, installer);
      // Sunucu başka bir dosyanın özetini ilan ediyor (ör. dosya yolda bozuldu
      // ya da değiştirildi).
      final release = releaseFor(apkBytes, sha256: sha256Hex([1, 2, 3]));

      await expectLater(
        s.prepare(release, cancelToken: CancelToken()),
        throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', UpdateFailureKind.checksumMismatch)),
      );
      expect(filesInUpdateDir(), isEmpty, reason: 'doğrulanmamış dosya diskte kalmamalı');
      expect(installer.installedPaths, isEmpty);
    });

    test('boyut sunucudakiyle tutmazsa da reddedilir', () async {
      final s = service(FakeDownloader(bytes: apkBytes), FakeInstaller());
      final release = releaseFor(apkBytes, size: apkBytes.length + 1);

      await expectLater(
        s.prepare(release, cancelToken: CancelToken()),
        throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', UpdateFailureKind.checksumMismatch)),
      );
      expect(filesInUpdateDir(), isEmpty);
    });

    test('gerçek sha256OfFile (isolate, akış halinde) crypto ile aynı özeti verir', () async {
      final file = File('${base.path}/x.bin');
      await file.writeAsBytes(apkBytes);
      expect(await sha256OfFile(file.path), sha256Hex(apkBytes));
    });
  });

  group('indirme hataları ve iptal', () {
    test('401 -> loginRequired; yarım dosya silinir', () async {
      final s = service(
        FakeDownloader(
          error: const ApiException(statusCode: 401, message: 'oturum yok', kind: ApiErrorKind.unauthorized),
        ),
        FakeInstaller(),
      );
      await expectLater(
        s.prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
        throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', UpdateFailureKind.loginRequired)),
      );
      expect(filesInUpdateDir(), isEmpty);
    });

    test('404 -> notFound, ağ hatası -> network (ApiClient mesajıyla)', () async {
      final s404 = service(
        FakeDownloader(error: const ApiException(statusCode: 404, message: 'yok', kind: ApiErrorKind.notFound)),
        FakeInstaller(),
      );
      await expectLater(
        s404.prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
        throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', UpdateFailureKind.notFound)),
      );

      final sNet = service(
        FakeDownloader(
          error: const ApiException(statusCode: null, message: 'Bağlantı kurulamadı.', kind: ApiErrorKind.network),
        ),
        FakeInstaller(),
      );
      await expectLater(
        sNet.prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
        throwsA(isA<UpdateFailure>()
            .having((f) => f.kind, 'kind', UpdateFailureKind.network)
            .having((f) => f.message, 'message', 'Bağlantı kurulamadı.')),
      );
    });

    test('iptal edilen indirme UpdateCancelled olur ve dosya bırakmaz', () async {
      final token = CancelToken()..cancel();
      final s = service(FakeDownloader(bytes: apkBytes), FakeInstaller());
      await expectLater(s.prepare(releaseFor(apkBytes), cancelToken: token), throwsA(isA<UpdateCancelled>()));
      expect(filesInUpdateDir(), isEmpty);
    });
  });

  group('eski/yarım dosyalar', () {
    test('indirmeden önce eski APK\'lar ve yarım .part dosyaları silinir', () async {
      await updateDir.create(recursive: true);
      await File('${updateDir.path}/arvend-1.apk').writeAsBytes([1]);
      await File('${updateDir.path}/arvend-2.apk').writeAsBytes([2]);
      await File('${updateDir.path}/arvend-3.apk.part').writeAsBytes([3]);

      await service(FakeDownloader(bytes: apkBytes), FakeInstaller())
          .prepare(releaseFor(apkBytes), cancelToken: CancelToken());

      expect(filesInUpdateDir(), ['arvend-3.apk']);
    });

    test('aynı build zaten indirilip doğrulandıysa yeniden indirilmez', () async {
      await updateDir.create(recursive: true);
      await File('${updateDir.path}/arvend-3.apk').writeAsBytes(apkBytes);
      final downloader = FakeDownloader(bytes: apkBytes);

      final apk = await service(downloader, FakeInstaller()).prepare(releaseFor(apkBytes), cancelToken: CancelToken());

      expect(downloader.calls, 0);
      expect(apk.path, '${updateDir.path}/arvend-3.apk');
    });

    test('önceden inmiş dosyanın özeti tutmuyorsa silinip yeniden indirilir', () async {
      await updateDir.create(recursive: true);
      await File('${updateDir.path}/arvend-3.apk').writeAsBytes(List<int>.filled(apkBytes.length, 0));
      final downloader = FakeDownloader(bytes: apkBytes);

      final apk = await service(downloader, FakeInstaller()).prepare(releaseFor(apkBytes), cancelToken: CancelToken());

      expect(downloader.calls, 1);
      expect(await apk.readAsBytes(), apkBytes);
    });

    test('cleanup: keepBuild dışındaki her şeyi siler; keepBuild yoksa hepsini', () async {
      await updateDir.create(recursive: true);
      await File('${updateDir.path}/arvend-2.apk').writeAsBytes([2]);
      await File('${updateDir.path}/arvend-3.apk').writeAsBytes([3]);
      final s = service(FakeDownloader(), FakeInstaller());

      await s.cleanup(keepBuild: 3);
      expect(filesInUpdateDir(), ['arvend-3.apk']);

      await s.cleanup();
      expect(filesInUpdateDir(), isEmpty);
    });
  });

  group('ApiUpdateDownloader (sahte HTTP adaptörü, gerçek ağ YOK)', () {
    test('/mobile/app-download?platform=android oturum çereziyle diske akıtılır', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/mobile/app-download': [(status: 200, body: apkBytes)],
      });
      final client = await buildFakeApiClient(adapter);
      final s = UpdateInstallService(
        downloader: ApiUpdateDownloader(client),
        installer: FakeInstaller(),
        baseDirectory: () async => base,
      );

      final apk = await s.prepare(releaseFor(apkBytes), cancelToken: CancelToken());

      expect(await apk.readAsBytes(), apkBytes);
      expect(adapter.calls, ['/mobile/app-download']);
      expect(adapter.requestQueries.single, {'platform': 'android'});
    });

    test('erişim çerezi süresi dolmuşsa (401 -> refresh başarılı) indirme kendiliğinden yeniden denenir', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/mobile/app-download': [
          (status: 401, body: {'error': 'yetkisiz'}),
          (status: 200, body: apkBytes),
        ],
        '/auth/refresh': [
          (status: 200, body: {'ok': true}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final s = UpdateInstallService(
        downloader: ApiUpdateDownloader(client),
        installer: FakeInstaller(),
        baseDirectory: () async => base,
      );

      final apk = await s.prepare(releaseFor(apkBytes), cancelToken: CancelToken());

      expect(await apk.readAsBytes(), apkBytes);
      expect(adapter.calls, ['/mobile/app-download', '/auth/refresh', '/mobile/app-download']);
    });

    test('askıya alınmış firma (403) indirmede de merkezi hesap-erişim engelini tetikler', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/mobile/app-download': [
          (status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final issues = <AccountAccessIssue>[];
      client.onAccountAccessBlocked = issues.add;
      final s = UpdateInstallService(
        downloader: ApiUpdateDownloader(client),
        installer: FakeInstaller(),
        baseDirectory: () async => base,
      );

      await expectLater(
        s.prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
        throwsA(isA<UpdateFailure>()
            .having((f) => f.kind, 'kind', UpdateFailureKind.network)
            .having((f) => f.message, 'message', 'firma askıya alınmış veya erişilemiyor')),
      );
      expect(issues, [AccountAccessIssue.organizationBlocked]);
      expect(filesInUpdateDir(), isEmpty);
    });

    group('ETag (= sunucunun sunduğu APK\'nın özeti)', () {
      UpdateInstallService serviceWith(_ApkServerAdapter adapter) {
        final dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl + AppConfig.apiPrefix))..httpClientAdapter = adapter;
        return UpdateInstallService(
          downloader: ApiUpdateDownloader(ApiClient.test(dio)),
          installer: FakeInstaller(),
          baseDirectory: () async => base,
        );
      }

      test('sunucu BAŞKA bir sürüm sunuyorsa gövde indirilmeden kesilir -> releaseChanged', () async {
        // İstem build 3'ü gösterirken sunucuya build 4 yayınlandı: indirme
        // ucu artık başka bir dosya (başka özet) sunuyor.
        final adapter = _ApkServerAdapter(bytes: apkBytes, etag: '"${sha256Hex([9, 9, 9])}"');
        final installer = FakeInstaller();
        final s = serviceWith(adapter);

        await expectLater(
          s.prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
          throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', UpdateFailureKind.releaseChanged)),
        );
        expect(adapter.chunksEmitted, lessThan(adapter.chunkCount), reason: '~60 MB boşuna inmemeli');
        expect(adapter.cancelled, isTrue, reason: 'bağlantı kapatılmalı');
        expect(filesInUpdateDir(), isEmpty);
        expect(installer.installedPaths, isEmpty);
      });

      test('ETag beklenen özetse (zayıf W/ biçimi dahil) normal iner', () async {
        final adapter = _ApkServerAdapter(bytes: apkBytes, etag: 'W/"${sha256Hex(apkBytes).toUpperCase()}"');
        final apk = await serviceWith(adapter).prepare(releaseFor(apkBytes), cancelToken: CancelToken());
        expect(await apk.readAsBytes(), apkBytes);
        expect(adapter.chunksEmitted, adapter.chunkCount);
      });

      test('ETag özet ilan etse bile karar yine indirilen dosyanın özetine aittir', () async {
        // Sunucu doğru özeti ilan ediyor ama yolda başka baytlar geliyor.
        final adapter = _ApkServerAdapter(bytes: List<int>.filled(apkBytes.length, 0), etag: '"${sha256Hex(apkBytes)}"');
        await expectLater(
          serviceWith(adapter).prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
          throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', UpdateFailureKind.checksumMismatch)),
        );
        expect(filesInUpdateDir(), isEmpty);
      });

      test('kullanıcının iptali (gerçek Dio indirmesi) UpdateCancelled olur, "reddedildi" ile karışmaz', () async {
        final adapter = _ApkServerAdapter(bytes: apkBytes, etag: '"${sha256Hex(apkBytes)}"');
        final token = CancelToken();
        await expectLater(
          serviceWith(adapter).prepare(
            releaseFor(apkBytes),
            cancelToken: token,
            onProgress: (received, total) {
              if (!token.isCancelled) token.cancel();
            },
          ),
          throwsA(isA<UpdateCancelled>()),
        );
        expect(adapter.chunksEmitted, lessThan(adapter.chunkCount));
        expect(filesInUpdateDir(), isEmpty);
      });

      test('etagAllows: yok/biçimsiz ETag karar vermez; farklı özet reddedilir', () {
        final sha = sha256Hex(apkBytes);
        expect(etagAllows(null, sha), isTrue);
        expect(etagAllows(['"abc"'], sha), isTrue);
        expect(etagAllows(['"$sha"', '"$sha"'], sha), isTrue);
        expect(etagAllows(['"$sha"'], sha), isTrue);
        expect(etagAllows([sha], sha), isTrue);
        expect(etagAllows(['W/"$sha"'], sha), isTrue);
        expect(etagAllows(['"${'0' * 64}"'], sha), isFalse);
        expect(etagAllows(['W/"${'f' * 64}"'], sha), isFalse);
      });
    });

    test('diske yazma hatası (telefonda yer yok) ağ hatası değil, storage olarak döner', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/mobile/app-download': [(status: 200, body: apkBytes)],
      });
      final client = await buildFakeApiClient(adapter);
      final s = UpdateInstallService(
        downloader: ApiUpdateDownloader(client),
        installer: FakeInstaller(),
        baseDirectory: () async => base,
      );

      // Dio'nun GERÇEK indirme yolu: dosya açılır, yazarken ENOSPC gelir.
      await IOOverrides.runWithIOOverrides(
        () => expectLater(
          s.prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
          throwsA(isA<UpdateFailure>()
              .having((f) => f.kind, 'kind', UpdateFailureKind.storage)
              .having((f) => f.message, 'message', contains('boş alan'))),
        ),
        _DiskFullOverrides(),
      );
      expect(filesInUpdateDir(), isEmpty);
    });

    test('oturum yoksa (401 -> refresh de 401) loginRequired döner', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/mobile/app-download': [
          (status: 401, body: {'error': 'yetkisiz'}),
        ],
        '/auth/refresh': [
          (status: 401, body: {'error': 'oturum yok'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      var sessionExpired = false;
      client.onSessionExpired = () => sessionExpired = true;
      final s = UpdateInstallService(
        downloader: ApiUpdateDownloader(client),
        installer: FakeInstaller(),
        baseDirectory: () async => base,
      );

      await expectLater(
        s.prepare(releaseFor(apkBytes), cancelToken: CancelToken()),
        throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', UpdateFailureKind.loginRequired)),
      );
      expect(sessionExpired, isTrue);
      expect(filesInUpdateDir(), isEmpty);
    });
  });
}

/// İndirme ucunu taklit eder: APK'yı parça parça akıtır ve ETag başlığını
/// verir. Kaç parçanın gerçekten gönderildiğini ve bağlantının istemci
/// tarafından kesilip kesilmediğini kaydeder.
class _ApkServerAdapter implements HttpClientAdapter {
  _ApkServerAdapter({required this.bytes, required this.etag});

  static const _chunkSize = 256;

  final List<int> bytes;
  final String etag;
  int chunksEmitted = 0;
  bool cancelled = false;

  int get chunkCount => (bytes.length + _chunkSize - 1) ~/ _chunkSize;

  Stream<Uint8List> _body() async* {
    var completed = false;
    try {
      for (var i = 0; i < bytes.length; i += _chunkSize) {
        await Future<void>.delayed(Duration.zero);
        chunksEmitted++;
        yield Uint8List.fromList(bytes.sublist(i, min(i + _chunkSize, bytes.length)));
      }
      completed = true;
    } finally {
      if (!completed) cancelled = true;
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(_body(), 200, headers: {
      Headers.contentTypeHeader: ['application/vnd.android.package-archive'],
      Headers.contentLengthHeader: ['${bytes.length}'],
      'etag': [etag],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// `.part` dosyası açılabilir ama yazılamaz -- telefonda yer kalmaması
/// (ENOSPC) gibi. Geri kalan her dosya gerçektir.
final class _DiskFullOverrides extends IOOverrides {
  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('.part') ? _DiskFullFile(real) : real;
  }
}

class _DiskFullFile implements File {
  _DiskFullFile(this._real);
  final File _real;

  @override
  String get path => _real.path;

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _real.createSync(recursive: recursive, exclusive: exclusive);

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) => _DiskFullRaf(_real.openSync(mode: mode));

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<bool> exists() => _real.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => _real.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DiskFullRaf implements RandomAccessFile {
  _DiskFullRaf(this._real);
  final RandomAccessFile _real;

  @override
  String get path => _real.path;

  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async =>
      throw FileSystemException('No space left on device', _real.path, const OSError('No space left on device', 28));

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
