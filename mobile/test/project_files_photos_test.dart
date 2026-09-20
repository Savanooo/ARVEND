import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/widgets/status_badge.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/project.dart';

import 'test_utils/fake_api_client.dart';

/// Dosyalar/Fotoğraflar (Project Files & Photos) — backend traced end-to-end
/// (Phase 1): two real domain-specific tables (`project_files`,
/// `project_photos`), local-disk storage behind an abstraction, server-side
/// MIME sniffing (client Content-Type never trusted), 25 MiB cap, UUID-only
/// storage keys (path traversal structurally impossible), soft-delete only
/// (never a hard delete -- safe to expose in mobile), org+project scoping
/// re-verified on every read, `projects.operations.read`/`.manage`
/// permission pair. A concrete mobile bug was found and fixed during this
/// module: photo thumbnails used `Image.network`, which cannot reach this
/// app's httpOnly cookie jar (a separate HTTP client from Dio) and would
/// silently 401 -- fixed by routing all photo/file bytes through
/// `ApiClient.getBytes` (same Dio instance, same cookie jar, same 401-
/// refresh-retry pipeline) and rendering with `Image.memory`.
void main() {
  group('parsing', () {
    test('ProjectPhoto.fromJson reads the exact backend field set', () {
      final p = ProjectPhoto.fromJson({
        'id': 'ph1',
        'original_name': 'saha1.jpg',
        'mime_type': 'image/jpeg',
        'size_bytes': 204800,
        'stage': 'before',
        'description': 'Temel kazısı öncesi',
        'created_at': '2026-01-05T10:00:00Z',
      });
      expect(p.id, 'ph1');
      expect(p.mimeType, 'image/jpeg');
      expect(p.sizeBytes, 204800);
      expect(p.stage, 'before');
      expect(p.description, 'Temel kazısı öncesi');
    });

    test('ProjectPhoto.fromJson defaults stage to progress and description to empty when absent', () {
      final p = ProjectPhoto.fromJson({'id': 'ph1', 'original_name': 'x.jpg'});
      expect(p.stage, 'progress');
      expect(p.description, '');
      expect(p.sizeBytes, 0);
    });

    test('ProjectFile.fromJson reads the exact backend field set', () {
      final f = ProjectFile.fromJson({
        'id': 'f1',
        'original_name': 'sozlesme.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 51200,
        'category': 'contract',
        'description': 'İmzalı sözleşme',
        'created_at': '2026-01-05T10:00:00Z',
      });
      expect(f.id, 'f1');
      expect(f.originalName, 'sozlesme.pdf');
      expect(f.mimeType, 'application/pdf');
      expect(f.category, 'contract');
    });

    test('ProjectFile.fromJson defaults category to other when absent', () {
      final f = ProjectFile.fromJson({'id': 'f1', 'original_name': 'x.pdf'});
      expect(f.category, 'other');
    });
  });

  group('backend-matching enums (kPhotoStages / kFileCategories)', () {
    test('kPhotoStages matches the backend project_photos.stage CHECK constraint exactly', () {
      expect(kPhotoStages, ['before', 'progress', 'after']);
    });

    test('kFileCategories matches the backend project_files.category CHECK constraint exactly', () {
      expect(kFileCategories, ['contract', 'drawing', 'invoice', 'report', 'other']);
    });

    test('StatusRegistry has a badge entry for every stage and category value', () {
      for (final s in kPhotoStages) {
        expect(StatusRegistry.photoStage.containsKey(s), isTrue, reason: 'missing badge for stage "$s"');
      }
      for (final c in kFileCategories) {
        expect(StatusRegistry.fileCategory.containsKey(c), isTrue, reason: 'missing badge for category "$c"');
      }
    });
  });

  group('client-side size pre-check (UX only, backend 25 MiB cap is authoritative)', () {
    test('exceedsMaxUploadBytes: at or under the limit is fine', () {
      expect(exceedsMaxUploadBytes(25 * 1024 * 1024, 25 * 1024 * 1024), isFalse);
      expect(exceedsMaxUploadBytes(100, 25 * 1024 * 1024), isFalse);
    });

    test('exceedsMaxUploadBytes: over the limit is rejected', () {
      expect(exceedsMaxUploadBytes(25 * 1024 * 1024 + 1, 25 * 1024 * 1024), isTrue);
    });
  });

  group('upload request construction (multipart)', () {
    late String tempPath;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('arvend_upload_test');
      final file = File('${dir.path}/test.jpg');
      await file.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      tempPath = file.path;
    });

    test('uploadPhoto sends multipart fields file/stage/description', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos': [(status: 201, body: _photoJson(id: 'ph1', stage: 'after'))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final photo = await repo.uploadPhoto(
        'p1',
        filePath: tempPath,
        fileName: 'test.jpg',
        stage: 'after',
        description: 'Teslim sonrası',
      );

      expect(photo.id, 'ph1');
      final form = adapter.requestBodies.single as FormData;
      final fields = {for (final e in form.fields) e.key: e.value};
      expect(fields['stage'], 'after');
      expect(fields['description'], 'Teslim sonrası');
      expect(form.files.single.key, 'file');
    });

    test('uploadFile sends multipart fields file/category/description', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/files': [(status: 201, body: _fileJson(id: 'f1', category: 'invoice'))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final file = await repo.uploadFile(
        'p1',
        filePath: tempPath,
        fileName: 'fatura.pdf',
        category: 'invoice',
        description: 'Eylül faturası',
      );

      expect(file.id, 'f1');
      final form = adapter.requestBodies.single as FormData;
      final fields = {for (final e in form.fields) e.key: e.value};
      expect(fields['category'], 'invoice');
      expect(fields['description'], 'Eylül faturası');
      expect(form.files.single.key, 'file');
    });

    test('uploadPhoto/uploadFile default stage=progress / category=other when not specified', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos': [(status: 201, body: _photoJson(id: 'ph1'))],
        '/projects/p1/files': [(status: 201, body: _fileJson(id: 'f1'))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.uploadPhoto('p1', filePath: tempPath, fileName: 'test.jpg');
      await repo.uploadFile('p1', filePath: tempPath, fileName: 'test.jpg');

      final photoForm = adapter.requestBodies[0] as FormData;
      final fileForm = adapter.requestBodies[1] as FormData;
      expect({for (final e in photoForm.fields) e.key: e.value}['stage'], 'progress');
      expect({for (final e in fileForm.fields) e.key: e.value}['category'], 'other');
    });
  });

  group('authenticated binary fetch (getBytes / photoBytes / fileBytes)', () {
    // Bu, mobilde bulunan gerçek bir hatayı DOĞRULAR: eski kod
    // `Image.network(photoContentUrl(...))` kullanıyordu -- bu, Dio'nun
    // httpOnly çerez kavanozuna ERİŞEMEYEN AYRI bir HTTP istemcisidir,
    // bu yüzden kimlik doğrulamalı bir uçta sessizce 401 alırdı. Bu
    // testler artık AYNI Dio örneği (ve dolayısıyla çerez kavanozu)
    // üzerinden gittiğini kanıtlar.
    test('photoBytes GETs the exact content endpoint and returns raw bytes', () async {
      final rawBytes = [0xFF, 0xD8, 0xFF, 1, 2, 3, 4, 5];
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos/ph1/content': [(status: 200, body: rawBytes)],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final bytes = await repo.photoBytes('p1', 'ph1');

      expect(adapter.calls, ['/projects/p1/photos/ph1/content']);
      expect(bytes, Uint8List.fromList(rawBytes));
    });

    test('fileBytes GETs the exact download endpoint and returns raw bytes', () async {
      final rawBytes = [0x25, 0x50, 0x44, 0x46]; // "%PDF"
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/files/f1/download': [(status: 200, body: rawBytes)],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final bytes = await repo.fileBytes('p1', 'f1');

      expect(adapter.calls, ['/projects/p1/files/f1/download']);
      expect(bytes, Uint8List.fromList(rawBytes));
    });

    test('photoBytes propagates a 404 (deleted/cross-project photo id) as ApiException', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos/ph1/content': [(status: 404, body: {'error': 'kayıt bulunamadı'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.photoBytes('p1', 'ph1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('deletion (soft-delete on the backend -- safe to expose, never a hard delete)', () {
    test('deletePhoto sends DELETE to /projects/{id}/photos/{photoId}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos/ph1': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.deletePhoto('p1', 'ph1');

      expect(adapter.calls, ['/projects/p1/photos/ph1']);
    });

    test('deleteFile sends DELETE to /projects/{id}/files/{fileId}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/files/f1': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.deleteFile('p1', 'f1');

      expect(adapter.calls, ['/projects/p1/files/f1']);
    });

    test('delete on an unauthorized (operations.manage-less) session surfaces as 403', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/files/f1': [(status: 403, body: {'error': 'bu işlem için yetkiniz yok'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.deleteFile('p1', 'f1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });

  group('backend error mapping', () {
    test('oversized upload rejected server-side surfaces the backend message verbatim', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/files': [(status: 400, body: {'error': 'dosya boyutu 25 MiB sınırını aşıyor'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);
      final dir = await Directory.systemTemp.createTemp('arvend_upload_test_big');
      final file = File('${dir.path}/big.bin');
      await file.writeAsBytes([1, 2, 3]);

      await expectLater(
        repo.uploadFile('p1', filePath: file.path, fileName: 'big.bin'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'dosya boyutu 25 MiB sınırını aşıyor')),
      );
    });

    test('unsupported MIME type rejected server-side surfaces as 400', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos': [(status: 400, body: {'error': 'desteklenmeyen dosya türü'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);
      final dir = await Directory.systemTemp.createTemp('arvend_upload_test_mime');
      final file = File('${dir.path}/x.exe');
      await file.writeAsBytes([1, 2, 3]);

      await expectLater(
        repo.uploadPhoto('p1', filePath: file.path, fileName: 'x.exe'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });

    test('a category with no active recipe items... N/A here -- empty project file/photo lists parse cleanly', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/files': [(status: 200, body: {'files': <Map<String, dynamic>>[]})],
        '/projects/p1/photos': [(status: 200, body: {'photos': <Map<String, dynamic>>[]})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      expect(await repo.files('p1'), isEmpty);
      expect(await repo.photos('p1'), isEmpty);
    });
  });

  group('permissions — exact two-tier model (projects.operations.read / .manage)', () {
    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    test('owner/admin/project_manager-shaped set: read+manage', () {
      final user = userWith(const {'projects.operations.read', 'projects.operations.manage'});
      expect(user.hasPermission('projects.operations.read'), isTrue);
      expect(user.hasPermission('projects.operations.manage'), isTrue);
    });

    test('read-only-shaped set: read but NOT manage -- upload/delete UI must hide', () {
      final user = userWith(const {'projects.operations.read'});
      expect(user.hasPermission('projects.operations.read'), isTrue);
      expect(user.hasPermission('projects.operations.manage'), isFalse);
    });

    test('a role with neither permission cannot see the Dosyalar tab at all', () {
      final user = userWith(const {'projects.finance.read'});
      expect(user.hasPermission('projects.operations.read'), isFalse);
      expect(user.hasPermission('projects.operations.manage'), isFalse);
    });
  });

  group('refresh/invalidation after mutation', () {
    test('invalidating projectPhotosProvider triggers a fresh fetch after upload', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos': [
          (status: 200, body: {'photos': <Map<String, dynamic>>[]}),
          (status: 200, body: {'photos': [_photoJson(id: 'ph1')]}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(projectPhotosProvider('p1').future);
      expect(before, isEmpty);

      container.invalidate(projectPhotosProvider('p1'));
      final after = await container.read(projectPhotosProvider('p1').future);

      expect(after, hasLength(1));
      expect(adapter.calls.where((p) => p == '/projects/p1/photos').length, 2);
    });

    test('invalidating projectFilesProvider triggers a fresh fetch after delete', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/files': [
          (status: 200, body: {'files': [_fileJson(id: 'f1')]}),
          (status: 200, body: {'files': <Map<String, dynamic>>[]}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(projectFilesProvider('p1').future);
      expect(before, hasLength(1));

      container.invalidate(projectFilesProvider('p1'));
      final after = await container.read(projectFilesProvider('p1').future);

      expect(after, isEmpty);
    });

    test('projectPhotoBytesProvider caches per (projectId, photoId) -- viewing the same photo twice does not refetch', () async {
      final rawBytes = [1, 2, 3, 4];
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos/ph1/content': [(status: 200, body: rawBytes)],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      const key = (projectId: 'p1', photoId: 'ph1');
      // autoDispose yalnızca AKTİF bir dinleyici varken önbelleği korur --
      // bu, gerçek kullanımda `ref.watch`'ın ekran/widget yaşam döngüsü
      // boyunca yaptığı ile AYNI (bkz. _FilesTabState/_PhotoViewerScreen'in
      // her ikisi de AYNI provider anahtarını `watch` eder).
      final sub = container.listen(projectPhotoBytesProvider(key), (_, _) {});
      final first = await container.read(projectPhotoBytesProvider(key).future);
      final second = await container.read(projectPhotoBytesProvider(key).future);
      sub.close();

      expect(first, Uint8List.fromList(rawBytes));
      expect(second, Uint8List.fromList(rawBytes));
      expect(adapter.calls.where((p) => p == '/projects/p1/photos/ph1/content').length, 1);
    });
  });
}

Map<String, dynamic> _photoJson({
  String id = 'ph1',
  String stage = 'progress',
}) =>
    {
      'id': id,
      'original_name': 'foto.jpg',
      'mime_type': 'image/jpeg',
      'size_bytes': 102400,
      'stage': stage,
      'description': '',
      'created_at': '2026-01-05T10:00:00Z',
    };

Map<String, dynamic> _fileJson({
  String id = 'f1',
  String category = 'other',
}) =>
    {
      'id': id,
      'original_name': 'dosya.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 51200,
      'category': category,
      'description': '',
      'created_at': '2026-01-05T10:00:00Z',
    };
