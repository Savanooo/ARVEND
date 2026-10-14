import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_sheet.dart';
import '../../../dashboard/presentation/widgets/project_picker_sheet.dart' show showProjectPickerSheet;
import '../../finance_ledger/data/finance_ledger_providers.dart' show invalidateProjectLedger;
import '../../presentation/expense_form_sheet.dart';
import '../../presentation/form_project_banner.dart' show formProjectLabel;

/// Proje dışından "Masraf Ekle" (Masraflar ekranı ve Ana Sayfa "Masraf Gir",
/// backend migration 0068): önce masrafın nereye gireceği sorulur -- genel
/// (projesiz) ya da bir proje. Proje seçmek projects.read ister (seçici o
/// uçtan beslenir); izni olmayan doğrudan genel masraf girer. Masraf
/// girildiyse true.
Future<bool> startAddExpense(BuildContext context, {void Function(bool loading)? onLoading}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final user = container.read(authControllerProvider).valueOrNull;
  var general = true;
  if (user.can('projects.read')) {
    final choice = await showAppSheet<bool>(
      context: context,
      useSafeArea: true,
      builder: (context) => const _ExpenseTargetSheet(),
    );
    if (choice == null || !context.mounted) return false;
    general = choice;
  }
  if (general) {
    final created = await showExpenseFormSheet(context, '', currency: 'TRY', projectLabel: 'Genel masraf (projesiz)');
    return created != null;
  }
  final project = await showProjectPickerSheet(context, onLoading: onLoading);
  if (project == null || !context.mounted) return false;
  final created = await showExpenseFormSheet(
    context,
    project.id,
    currency: project.currency,
    projectLabel: formProjectLabel(project.projectNo, project.name),
  );
  if (created == null) return false;
  // Projenin Finans ekranı başka sekmede açık kalmış olabilir: yeni masraf
  // orada da görünsün.
  invalidateProjectLedger(container.invalidate, project.id);
  return true;
}

class _ExpenseTargetSheet extends StatelessWidget {
  const _ExpenseTargetSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Masraf nereye girilsin?', style: AppTypography.sectionTitle),
            ),
          ),
          ListTile(
            key: const ValueKey('masraf-hedef-genel'),
            leading: const Icon(Icons.business_outlined),
            title: const Text('Genel masraf (projesiz)'),
            subtitle: const Text('Ofis, yakıt, yemek gibi firma giderleri'),
            onTap: () => Navigator.of(context).pop(true),
          ),
          ListTile(
            key: const ValueKey('masraf-hedef-proje'),
            leading: const Icon(Icons.apartment_outlined),
            title: const Text('Bir projeye'),
            subtitle: const Text('Projenin maliyetine işlenir'),
            onTap: () => Navigator.of(context).pop(false),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}
