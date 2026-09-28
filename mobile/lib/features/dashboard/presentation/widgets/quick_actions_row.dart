import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/quick_action_button.dart';
import '../../../customers/presentation/customer_form_sheet.dart';
import '../../../projects/presentation/collection_form_sheet.dart';
import '../../../projects/presentation/expense_form_sheet.dart';
import '../../../projects/presentation/note_form_sheet.dart';
import '../../data/dashboard_providers.dart';
import '../../domain/dashboard_registry.dart';
import 'project_picker_sheet.dart';

/// Şu an çalışan hızlı işlem (yoksa null) ve proje listesinin yüklenip
/// yüklenmediği. Aynı anda tek işlem: proje listesi yavaş gelirken ikinci
/// dokunuş ikinci bir seçici/form açmaz (çift tahsilat girişi riski).
/// Liste yüklenirken dokunulan butonda dönen gösterge görünür; seçici ya
/// da form açıkken gösterge yoktur (üstte zaten bir sayfa vardır).
typedef QuickActionRun = ({QuickActionKey action, bool loading});

final quickActionInFlightProvider = StateProvider<QuickActionRun?>((ref) => null);

/// "Hızlı İşlemler" (spec §3.5): izne göre süzülmüş, sabit sıralı yatay
/// buton satırı. Boşsa hiç çizilmez (çağıran karar verir).
class QuickActionsRow extends ConsumerWidget {
  const QuickActionsRow({super.key, required this.actions, this.inset = 0});

  final List<QuickActionKey> actions;

  /// Şerit ekran kenarına kadar uzanır; başlık ve ilk/son kutucuk bu
  /// kadar içeriden başlar (sayfanın yatay boşluğu). Böylece kısmen
  /// görünen kutucuk içerik kenarında kesilmez, ekranın altından kayar.
  final double inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(quickActionInFlightProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: const AppSectionHeader(title: 'Hızlı İşlemler'),
        ),
        const SizedBox(height: AppSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: inset),
          // Butonlar eşit boyda (iki satırlık etiket diğerlerini uzatır).
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.sm),
                  QuickActionButton(
                    icon: actions[i].icon,
                    label: actions[i].label,
                    busy: running != null && running.action == actions[i] && running.loading,
                    onPressed: running == null ? () => runQuickAction(context, actions[i]) : null,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Hızlı işlemi çalıştırır. Projeye bağlı işlemler önce proje seçtirir
/// (tek açık projede seçici atlanır); bir kayıt oluşunca ana sayfa
/// verisi tazelenir. Bir işlem sürerken (proje listesi, seçici, form) yeni
/// dokunuşlar yok sayılır -- boş kart ve kurulum CTA'ları da buradan geçer.
Future<void> runQuickAction(BuildContext context, QuickActionKey action) async {
  // Kilit widget'a değil ProviderContainer'a bağlıdır: işlem bitmeden
  // çağıran kart ağaçtan kalksa da kilit güvenle çözülür.
  final container = ProviderScope.containerOf(context, listen: false);
  final lock = container.read(quickActionInFlightProvider.notifier);
  if (lock.state != null) return;
  lock.state = (action: action, loading: false);
  try {
    await _runQuickAction(context, container, action, (loading) => lock.state = (action: action, loading: loading));
  } finally {
    lock.state = null;
  }
}

Future<void> _runQuickAction(
  BuildContext context,
  ProviderContainer container,
  QuickActionKey action,
  void Function(bool loading) onLoading,
) async {
  void invalidate() => container.invalidate(dashboardProvider);

  switch (action) {
    case QuickActionKey.offer:
      await context.push('/teklifler/yeni');
      invalidate();
      return;
    case QuickActionKey.attendance:
      await context.push('/diger/mesai');
      invalidate();
      return;
    case QuickActionKey.calc:
      await context.push('/diger/metraj');
      return;
    case QuickActionKey.customer:
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const CustomerFormSheet(),
      );
      invalidate();
      return;
    case QuickActionKey.collection:
    case QuickActionKey.expense:
    case QuickActionKey.purchaseRequest:
    case QuickActionKey.task:
    case QuickActionKey.note:
      break;
  }

  if (!context.mounted) return;
  final project = await showProjectPickerSheet(context, onLoading: onLoading);
  if (project == null || !context.mounted) return;
  switch (action) {
    case QuickActionKey.collection:
      if (await showCollectionFormSheet(context, project.id, currency: project.currency) != null) invalidate();
    case QuickActionKey.expense:
      if (await showExpenseFormSheet(context, project.id, currency: project.currency) != null) invalidate();
    case QuickActionKey.note:
      if (await showNoteFormSheet(context, project.id) != null) invalidate();
    case QuickActionKey.purchaseRequest:
      await context.push('/projeler/${project.id}/satin-alma/talepler/yeni');
      invalidate();
    case QuickActionKey.task:
      await context.push('/projeler/${project.id}/gorevler/yeni');
      invalidate();
    default:
      break;
  }
}
