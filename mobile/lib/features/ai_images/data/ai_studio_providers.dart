import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../projects/data/projects_providers.dart' show projectPhotoCacheProvider;
import '../domain/ai_studio.dart';
import 'ai_studio_repository.dart';

final aiStudioRepositoryProvider = Provider<AiStudioRepository>(
  (ref) => AiStudioRepository(ref.watch(apiClientProvider)),
);

/// Stüdyo görselinin baytları: ızgara kutucuğu ve tam ekran görüntüleyici
/// aynı isteği paylaşır. Proje fotoğraflarının cihaz önbelleği kullanılır
/// (bkz. ProjectPhotoCache): içerik kimliğe bağlı ve değişmez, kimlikler
/// UUID (proje fotoğrafıyla çakışmaz) ve çıkışta o dizin zaten silinir --
/// ayrı bir dizin çıkış temizliğine de eklenmek zorunda kalırdı.
final aiStudioImageBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, id) async {
  final cache = ref.watch(projectPhotoCacheProvider);
  final cached = await cache.read(id);
  if (cached != null) return cached;
  final bytes = await ref.watch(aiStudioRepositoryProvider).imageBytes(id);
  unawaited(cache.write(id, bytes));
  return bytes;
});

class AiStudioList {
  const AiStudioList({
    required this.images,
    required this.pendingJobs,
    this.nextBefore,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<AiStudioImage> images;

  /// Sunucuda hâlâ süren işler ("Hazırlanıyor…" kutucukları).
  final List<AiStudioJob> pendingJobs;
  final String? nextBefore;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get hasMore => nextBefore != null && nextBefore!.isNotEmpty;

  AiStudioList copyWith({
    List<AiStudioImage>? images,
    String? nextBefore,
    bool clearNext = false,
    bool? loadingMore,
    Object? loadMoreError,
    bool clearError = false,
  }) =>
      AiStudioList(
        images: images ?? this.images,
        pendingJobs: pendingJobs,
        nextBefore: clearNext ? null : (nextBefore ?? this.nextBefore),
        loadingMore: loadingMore ?? this.loadingMore,
        loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
      );
}

/// Görsellerim: en yenisi önce, kaydırdıkça next_before ile devamı. Bir iş
/// bitince (bkz. AiImageJobsController) sağlayıcı tazelenir; tazelenirken
/// eski liste görünür kalır. Nesil sayacı: tazeleme sırasında uçan eski
/// "devamı" isteği listeyi geri yazmasın.
class AiStudioImagesNotifier extends AutoDisposeFamilyAsyncNotifier<AiStudioList, AiStudioScope> {
  int _generation = 0;
  bool _alive = true;

  AiStudioRepository get _repo => ref.read(aiStudioRepositoryProvider);

  @override
  Future<AiStudioList> build(AiStudioScope scope) async {
    _generation++;
    _alive = true;
    ref.onDispose(() => _alive = false);
    final page = await _repo.images(scope: scope);
    return AiStudioList(images: page.images, pendingJobs: page.pendingJobs, nextBefore: page.nextBefore);
  }

  /// [auto]: kaydırmadan gelen çağrı -- son istek hata verdiyse kendiliğinden
  /// yeniden denemez (yalnızca "Tekrar Dene").
  Future<void> loadMore({bool auto = false}) async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore || !current.hasMore || state.isLoading) return;
    if (auto && current.loadMoreError != null) return;
    final generation = _generation;
    bool stale() => !_alive || generation != _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final next = await _repo.images(scope: arg, before: current.nextBefore);
      if (stale()) return;
      final seen = {for (final i in current.images) i.id};
      state = AsyncData(AiStudioList(
        images: [...current.images, for (final i in next.images) if (seen.add(i.id)) i],
        pendingJobs: current.pendingJobs,
        nextBefore: next.nextBefore,
      ));
    } catch (e) {
      if (stale()) return;
      state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: e));
    }
  }

  /// Silinen görsel listeden hemen düşer (tazelemeyi beklemeden).
  void removeLocal(String id) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(images: [for (final i in current.images) if (i.id != id) i]));
  }

  /// Projeye eklenen görselin "Projede" bilgisi hemen görünsün.
  void replaceLocal(AiStudioImage image) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(images: [for (final i in current.images) i.id == image.id ? image : i]));
  }
}

final aiStudioImagesProvider =
    AsyncNotifierProvider.autoDispose.family<AiStudioImagesNotifier, AiStudioList, AiStudioScope>(
  AiStudioImagesNotifier.new,
);
