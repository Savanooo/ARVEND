import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../update/play_update.dart';
import '../update/update_controller.dart';
import 'whats_new.dart';
import 'whats_new_sheet.dart';

/// Uygulama güncellendikten sonraki ilk açılışta "Yenilikler" sayfasını BİR
/// KEZ açar (PlayUpdateWatcher gibi açılışta bir kez çalışan bir gözcü).
///
/// AppShell'i sarar, MaterialApp'i değil: kabuk yalnızca oturum açıkken ve
/// zorunlu ekranlar (şifre belirleme, firma kurulumu, hesap engeli)
/// geçildikten sonra kurulur. Böylece sayfa giriş ekranının üstünde hiç
/// açılmaz; giriş yapıldığında kabukla birlikte gelir.
///
/// Sıra:
/// 1. Gösterilecek bir şey var mı (yerel, hızlı). Yoksa hiçbir şey beklenmez.
/// 2. Açılıştaki güncelleme denetiminin kararı beklenir: zorunlu güncelleme
///    varsa bu açılışta gösterilmez ve kaydedilmez -- güncellemeden sonra yeni
///    sürümün notlarıyla birleşip gelir.
/// 3. Sayfa açılır açılmaz build kaydedilir (kapanmasını beklemeden):
///    kullanıcı sayfa açıkken uygulamayı kapatsa da bir daha gösterilmez.
///
/// Herhangi bir adım başarısız olursa sessizce geçilir; uygulamayı hiçbir
/// koşulda bekletmez.
class WhatsNewGate extends ConsumerStatefulWidget {
  const WhatsNewGate({super.key, required this.child});

  final Widget child;

  /// Güncelleme denetiminin kararı en fazla bu kadar beklenir (Play'e ve
  /// sunucuya ulaşılamayan şantiye). Süre dolarsa zorunlu SAYILMAZ --
  /// PlayUpdateController da sunucuya ulaşamayınca öyle yapıyor; o arada
  /// zorunlu çıkarsa Play'in tam ekran güncellemesi zaten bu sayfanın
  /// üstünde açılır.
  static const updateDecisionWait = Duration(seconds: 20);

  @override
  ConsumerState<WhatsNewGate> createState() => _WhatsNewGateState();
}

class _WhatsNewGateState extends ConsumerState<WhatsNewGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _maybeShow() async {
    try {
      if (!mounted) return;
      final user = ref.read(authControllerProvider).valueOrNull;
      if (user == null) return;
      final controller = ref.read(whatsNewControllerProvider);
      final pending = await controller.pending(user);
      if (pending == null || !mounted) return;

      final notes = pending.notes;
      if (notes == null) {
        // Kullanıcının görebileceği madde yok: sessizce görüldü sayılır.
        await controller.markSeen(pending.build);
        return;
      }

      if (!await _updateFlowAllows() || !mounted) return;
      // Kabuğun üstünde bir diyalog açıksa (ör. güncelleme istemi) onun
      // üstüne binilmez; bir sonraki açılışta.
      if (!(ModalRoute.isCurrentOf(context) ?? true)) return;

      final closed = showWhatsNewSheet(context, notes);
      await controller.markSeen(pending.build);
      await closed;
    } catch (e) {
      debugPrint('Yenilikler gösterilemedi: $e');
    }
  }

  /// Zorunlu güncelleme akışı yoksa true. Sideload'da ayrıca açık bir
  /// güncelleme istemi varsa da false (iki pencere üst üste açılmasın).
  Future<bool> _updateFlowAllows() async {
    if (ref.read(playUpdateSupportedProvider)) {
      final play = ref.read(playUpdateControllerProvider);
      await play.firstDecision.timeout(WhatsNewGate.updateDecisionWait, onTimeout: () {});
      if (!mounted || play.mandatoryPending) return false;
    }
    if (ref.read(updateSupportedProvider)) {
      final update = ref.read(updateControllerProvider.notifier);
      await update.whenIdle().timeout(WhatsNewGate.updateDecisionWait, onTimeout: () {});
      if (!mounted || update.isPresenting || ref.read(updateControllerProvider).hasMandatoryUpdate) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
