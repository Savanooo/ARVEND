import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/quick_action_button.dart';
import '../../../customers/presentation/customer_form_sheet.dart';
import '../../../projects/finance_ledger/data/finance_ledger_providers.dart' show invalidateProjectLedger;
import '../../../projects/presentation/collection_form_sheet.dart';
import '../../../projects/presentation/expense_form_sheet.dart';
import '../../../projects/presentation/note_form_sheet.dart';
import '../../data/dashboard_providers.dart';
import '../../domain/dashboard_registry.dart';
import 'project_picker_sheet.dart';
import '../../../projects/presentation/form_project_banner.dart';
import '../../../../core/widgets/app_sheet.dart';

/// Şu an çalışan hızlı işlem (yoksa null) ve proje listesinin yüklenip
/// yüklenmediği. Aynı anda tek işlem: proje listesi yavaş gelirken ikinci
/// dokunuş ikinci bir seçici/form açmaz (çift tahsilat girişi riski).
/// Liste yüklenirken dokunulan butonda dönen gösterge görünür; seçici ya
/// da form açıkken gösterge yoktur (üstte zaten bir sayfa vardır).
typedef QuickActionRun = ({QuickActionKey action, bool loading});

final quickActionInFlightProvider = StateProvider<QuickActionRun?>((ref) => null);

/// "Hızlı İşlemler" (spec §3.5): izne göre süzülmüş, sabit sıralı işlemler
/// eşit boyutlu bir ızgarada -- hepsi kaydırmadan görünür (bkz.
/// QuickActionGrid). Boşsa hiç çizilmez (çağıran karar verir).
class QuickActionsRow extends ConsumerWidget {
  const QuickActionsRow({super.key, required this.actions, this.inset = 0});

  final List<QuickActionKey> actions;

  /// Sayfanın yatay boşluğu: başlık ve ızgara bu kadar içeriden başlar.
  final double inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(quickActionInFlightProvider);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSectionHeader(title: 'Hızlı İşlemler'),
          const SizedBox(height: AppSpacing.sm),
          QuickActionGrid(
            children: [
              for (final action in actions)
                QuickActionButton(
                  icon: action.icon,
                  label: action.label,
                  busy: running != null && running.action == action && running.loading,
                  onPressed: running == null ? () => runQuickAction(context, action) : null,
                ),
            ],
          ),
        ],
      ),
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

  // Tam sayfa açan işlemlerde kilit sayfa açılınca çözülür; rotanın
  // kapanması BEKLENMEZ. Açılan sayfa kendini go/pushReplacement ile
  // değiştirirse push'un Future'ı hiç tamamlanmıyor ve bütün hızlı işlemler
  // kalıcı olarak pasif kalıyordu. Sayfa üstte olduğu için ikinci dokunuş
  // zaten mümkün değil; özet, sayfadan dönülünce (tamamlanırsa) tazelenir.
  void openPage(String location, {bool refresh = true}) {
    unawaited(context.push<Object?>(location).then((_) {
      if (refresh) invalidate();
    }));
  }

  switch (action) {
    case QuickActionKey.offer:
      openPage('/teklifler/yeni');
      return;
    case QuickActionKey.attendance:
      openPage('/diger/mesai');
      return;
    case QuickActionKey.calc:
      openPage('/diger/metraj', refresh: false);
      return;
    case QuickActionKey.myExpenses:
      openPage('/diger/masraflarim', refresh: false);
      return;
    case QuickActionKey.customer:
      await showAppSheet<void>(
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
      final label = formProjectLabel(project.projectNo, project.name);
      if (await showCollectionFormSheet(context, project.id, currency: project.currency, projectLabel: label) != null) {
        invalidate();
        // Projenin Finans ekranı başka sekmede açık kalmış olabilir: yeni
        // tahsilat orada da görünsün (addProjectCollection ile aynı tazeleme).
        invalidateProjectLedger(container.invalidate, project.id);
      }
    case QuickActionKey.expense:
      final label = formProjectLabel(project.projectNo, project.name);
      if (await showExpenseFormSheet(context, project.id, currency: project.currency, projectLabel: label) != null) {
        invalidate();
        // Masraflarım'ın "+"ı da buradan geçer: projenin Finans ekranı başka
        // sekmede açık kalmış olabilir, yeni masraf orada da görünsün
        // (proje ekranındaki addProjectExpense ile aynı tazeleme).
        invalidateProjectLedger(container.invalidate, project.id);
      }
    case QuickActionKey.note:
      if (await showNoteFormSheet(context, project.id) != null) invalidate();
    case QuickActionKey.purchaseRequest:
      openPage('/projeler/${project.id}/satin-alma/talepler/yeni');
    case QuickActionKey.task:
      openPage('/projeler/${project.id}/gorevler/yeni');
    default:
      break;
  }
}
