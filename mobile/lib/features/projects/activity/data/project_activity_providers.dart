import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_providers.dart';
import '../domain/project_event.dart';
import 'project_activity_repository.dart';

/// Proje olaylarını okumak `projects.read` ister -- proje sayfasının kendisi
/// de bu izinle açılır.
const kProjectActivityReadPermission = 'projects.read';

/// Tutarların görünmesi için gereken izin (web finans bölümleriyle aynı).
const kProjectActivityMoneyPermission = 'projects.finance.read';

final projectActivityRepositoryProvider =
    Provider<ProjectActivityRepository>((ref) => ProjectActivityRepository(ref.watch(apiClientProvider)));

/// Olaylar EN YENİ ÜSTTE (sunucu ASC döndürür). Web listeyi olduğu gibi
/// (en eski üstte) yazar; telefonda uzun bir projenin son hareketine
/// ulaşmak için sona kaydırmamak adına sıra tersine çevrilir.
final projectActivityProvider = FutureProvider.autoDispose.family<List<ProjectEvent>, String>((ref, projectId) async {
  final events = await ref.watch(projectActivityRepositoryProvider).events(projectId);
  return events.reversed.toList(growable: false);
});
