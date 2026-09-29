import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../data/budget_providers.dart';
import 'budget_cost_control_tab.dart';
import 'widgets/budget_ui.dart';

/// "Maliyet Kontrolü" merkezinin tam ekran hâli (`/projeler/:id/maliyet`)
/// -- Özet kartı / ana sayfa derin bağlantısı için. Gövde proje detayındaki
/// Finans > Maliyet Kontrolü sekmesiyle AYNI widget'tır.
class BudgetCostControlScreen extends ConsumerWidget {
  const BudgetCostControlScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(budgetProjectProvider(projectId));
    return AppPageScaffold(
      title: const Text('Maliyet Kontrolü'),
      body: projectAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isBudgetForbidden(e)
            ? const BudgetNoAccessView(message: kBudgetModuleNoAccessText)
            : ErrorState(error: e, onRetry: () async => ref.invalidate(budgetProjectProvider(projectId))),
        data: (project) => BudgetCostControlTab(projectId: projectId, project: project, topPadding: AppSpacing.lg),
      ),
    );
  }
}
