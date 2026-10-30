import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../projects/data/projects_providers.dart';
import '../domain/ai_image.dart';
import '../domain/ai_studio.dart';
import 'ai_images_repository.dart';
import 'ai_studio_providers.dart';
import 'ai_studio_repository.dart';

final aiImagesRepositoryProvider = Provider<AiImagesRepository>(
  (ref) => AiImagesRepository(ref.watch(apiClientProvider)),
);

/// Sunucu durumu. İzni olmayan (fail-closed: her görsel firmaya para
/// yazar) hiç sormaz; sorulamazsa da kapalı sayılır -- girişler gizlenir,
/// asıl sınır yine backend'de.
final aiImageStatusProvider = FutureProvider.autoDispose<AiImageStatus>((ref) async {
  final user = ref.watch(authControllerProvider).valueOrNull;
  if (!user.canAccess(kAiImagesPermission)) return AiImageStatus.off;
  try {
    return await ref.watch(aiImagesRepositoryProvider).status();
  } on ApiException {
    return AiImageStatus.off;
  }
});

/// Yapay zekâ girişleri görünsün mü: izin var VE sunucuda anahtar ayarlı.
final aiImagesAvailableProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(aiImageStatusProvider).valueOrNull?.available ?? false,
);

/// İlk kullanımdaki bilgilendirmenin (fotoğraf ve metin OpenAI'ye gider,
/// görsel temsilidir) kişi başına bu telefonda kabulü.
class AiConsentStore {
  AiConsentStore({Future<SharedPreferences> Function()? prefs}) : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static String keyFor(String userId) => 'arvend.ai_images.consent_v1.$userId';

  Future<bool> accepted(String userId) async {
    try {
      return (await _prefs()).getBool(keyFor(userId)) ?? false;
    } catch (_) {
      return false; // okunamazsa en kötü ihtimalle bir kez daha sorulur
    }
  }

  Future<void> accept(String userId) async {
    try {
      await (await _prefs()).setBool(keyFor(userId), true);
    } catch (_) {
      // yazılamazsa bir sonraki sefer tekrar sorulur
    }
  }
}

final aiConsentStoreProvider = Provider<AiConsentStore>((ref) => AiConsentStore());

/// Açılan işlerin takibi: sayfa kapansa da (kullanıcı başka ekrana geçse de)
/// uygulama açık kaldıkça birkaç saniyede bir sorar. İş bitince proje
/// fotoğrafları (Stüdyo işinde Görsellerim) tazelenir; "Görsel hazır"
/// bandını AiImageJobWatcher gösterir (durum geçişini bu haritadan okur --
/// bitmiş işler bu yüzden haritada kalır). Stüdyo işleri aynı haritada
/// ([AiImageJob.studio]): bant ve sınırlar tek yerden yönetilsin.
class AiImageJobsController extends Notifier<Map<String, AiImageJob>> {
  static const pollInterval = Duration(seconds: 3);

  /// Bu kadar süredir bitmeyen iş artık sorulmaz (sunucu iş başına en çok
  /// ~5 dk bekler; yeniden başlarsa işi zaten "başarısız" yapar).
  static const maxTracking = Duration(minutes: 10);
  static const _keepFinished = 20;

  Timer? _timer;
  bool _polling = false;
  final _trackedAt = <String, DateTime>{};

  @override
  Map<String, AiImageJob> build() {
    // Başka hesapla girilince öncekinin işleri sorulmasın.
    ref.watch(authControllerProvider.select((a) => a.valueOrNull?.id));
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    _trackedAt.clear();
    return const {};
  }

  AiImagesRepository get _repo => ref.read(aiImagesRepositoryProvider);
  AiStudioRepository get _studio => ref.read(aiStudioRepositoryProvider);

  /// İşi açar ve izlemeye alır. Hata (429 sınır, 503 kapalı, 409 kapalı
  /// proje) ApiException olarak çağırana gider; metni sunucunun Türkçesi.
  Future<AiImageJob> start(
    String projectId, {
    required String kind,
    String prompt = '',
    String? sourcePhotoId,
    Uint8List? mask,
  }) async {
    final res = await _repo.createJob(projectId, kind: kind, prompt: prompt, sourcePhotoId: sourcePhotoId, mask: mask);
    _track(res.job);
    ref.invalidate(aiImageStatusProvider);
    return res.job;
  }

  /// Stüdyo işi açar (kaynak: telefondan dosya, önceki bir stüdyo görseli
  /// ya da hiçbiri) ve izlemeye alır. Hata ApiException olarak çağırana gider.
  Future<AiStudioJob> startStudio({
    required String kind,
    String prompt = '',
    String? imagePath,
    String? imageName,
    String? sourceStudioImageId,
    Uint8List? mask,
  }) async {
    final res = await _studio.createJob(
      kind: kind,
      prompt: prompt,
      imagePath: imagePath,
      imageName: imageName,
      sourceStudioImageId: sourceStudioImageId,
      mask: mask,
    );
    _track(res.job.toTracked());
    ref.invalidate(aiImageStatusProvider);
    return res.job;
  }

  /// Görsellerim'deki sunucu tarafında süren işler (uygulama yeniden
  /// açılmış olabilir): bitince liste tazelensin ve bant çıksın.
  void trackStudio(Iterable<AiStudioJob> jobs) {
    for (final j in jobs.where((j) => j.isActive && !state.containsKey(j.id))) {
      _track(j.toTracked());
    }
  }

  /// Uygulama yeniden açıldıysa sunucuda hâlâ süren işleri izlemeye alır.
  Future<void> resume(String projectId) async {
    try {
      final jobs = await _repo.jobs(projectId);
      for (final j in jobs.where((j) => j.isActive && !state.containsKey(j.id))) {
        _track(j);
      }
    } on ApiException {
      // Liste gelmezse yalnızca bu oturumda açılanlar izlenir.
    }
  }

  List<AiImageJob> activeFor(String projectId) =>
      state.values.where((j) => j.projectId == projectId && j.isActive).toList();

  void _track(AiImageJob job) {
    _trackedAt[job.id] = DateTime.now();
    final next = {...state, job.id: job};
    // Bitmiş işlerin en eskileri düşer (harita büyümesin).
    final finished = next.values.where((j) => !j.isActive).toList();
    if (finished.length > _keepFinished) {
      for (final old in finished.take(finished.length - _keepFinished)) {
        next.remove(old.id);
        _trackedAt.remove(old.id);
      }
    }
    state = next;
    _ensureTimer();
  }

  void _ensureTimer() {
    if (_timer?.isActive ?? false) return;
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final active = state.values.where((j) => j.isActive).toList();
      for (final job in active) {
        final since = _trackedAt[job.id];
        if (since != null && DateTime.now().difference(since) > maxTracking) {
          state = {...state}..remove(job.id);
          continue;
        }
        try {
          final fresh =
              job.studio ? (await _studio.job(job.id)).toTracked() : await _repo.job(job.projectId, job.id);
          if (fresh.status == job.status) continue;
          state = {...state, fresh.id: fresh};
          if (!fresh.isActive) {
            ref.invalidate(aiImageStatusProvider);
            if (fresh.studio) {
              // Başarısız iş de "Hazırlanıyor…" kutucuğundan düşsün.
              ref.invalidate(aiStudioImagesProvider);
            } else if (fresh.isDone) {
              ref.invalidate(projectPhotosProvider(fresh.projectId));
            }
          }
        } on ApiException catch (e) {
          // İş artık görülemiyor (proje silindi, yetki kalktı): bırak.
          if (e.kind == ApiErrorKind.notFound || e.kind == ApiErrorKind.forbidden) {
            state = {...state}..remove(job.id);
          }
          // Ağ hatası: bir sonraki turda yeniden sorulur.
        }
      }
    } finally {
      _polling = false;
      if (!state.values.any((j) => j.isActive)) {
        _timer?.cancel();
        _timer = null;
      }
    }
  }
}

final aiImageJobsProvider = NotifierProvider<AiImageJobsController, Map<String, AiImageJob>>(
  AiImageJobsController.new,
);
