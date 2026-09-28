import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/cost_codes_providers.dart';
import '../domain/cost_code.dart';
import 'cost_code_form_sheet.dart';
import 'widgets/cost_code_ui.dart';

/// Maliyet kodu detayı (`GET /organization/cost-codes/{id}`). Web'de ayrı
/// bir sayfa yok (tablo satırı + modal); mobilde uzun ad/açıklama tam
/// okunabilsin diye ayrı ekran. Düzenle/Arşivle/Etkinleştir yalnızca
/// `organization.cost_codes.manage` ile görünür.
class CostCodeDetailScreen extends ConsumerStatefulWidget {
  const CostCodeDetailScreen({super.key, required this.costCodeId});

  final String costCodeId;

  @override
  ConsumerState<CostCodeDetailScreen> createState() => _CostCodeDetailScreenState();
}

class _CostCodeDetailScreenState extends ConsumerState<CostCodeDetailScreen> {
  bool _busy = false;

  Future<void> _refresh() async {
    ref.invalidate(costCodeDetailProvider(widget.costCodeId));
    try {
      await ref.read(costCodeDetailProvider(widget.costCodeId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    const fallbackTitle = Text('Maliyet Kodu');
    if (user == null && auth.isLoading) {
      return const AppPageScaffold(title: fallbackTitle, body: LoadingState());
    }
    if (!user.canAccess(kCostCodesReadPermission)) {
      return const AppPageScaffold(title: fallbackTitle, body: CostCodeNoAccessView());
    }
    final canManage = user.canAccess(kCostCodesManagePermission);
    final detailAsync = ref.watch(costCodeDetailProvider(widget.costCodeId));
    final costCode = detailAsync.valueOrNull;

    return AppPageScaffold(
      title: costCode == null ? fallbackTitle : Text(costCode.code, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (canManage && costCode != null)
          IconButton(
            tooltip: 'Düzenle',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _busy ? null : () => _edit(costCode),
          ),
      ],
      body: detailAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isCostCodeForbidden(e) ? const CostCodeNoAccessView() : ErrorState(error: e, onRetry: _refresh),
        data: (c) => RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      c.code,
                      style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  c.isActive
                      ? const StatusBadge(label: 'Aktif', tone: StatusTone.success)
                      : const StatusBadge(label: 'Arşivlendi', tone: StatusTone.muted),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(c.name, style: AppTypography.pageTitle),
              if (!canManage) ...[const SizedBox(height: AppSpacing.md), const CostCodeReadOnlyNotice()],
              const SizedBox(height: AppSpacing.xl),
              const Text('Bilgiler', style: AppTypography.sectionTitle),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CostCodeInfoRow(label: 'Kod', value: c.code),
                    CostCodeInfoRow(label: 'Ad', value: c.name),
                    CostCodeInfoRow(label: 'Kategori', value: c.category),
                    CostCodeInfoRow(label: 'Durum', value: c.isActive ? 'Aktif' : 'Arşivlendi'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const Text('Açıklama', style: AppTypography.sectionTitle),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: Text(
                  c.description.isEmpty ? 'Açıklama yok.' : c.description,
                  style: c.description.isEmpty ? AppTypography.metadata : AppTypography.body,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                c.isActive
                    ? 'Bütçe kalemleri, taahhütler ve taşeron kalemleri bu kodla sınıflandırılabilir.'
                    : 'Arşivlenmiş kod yeni bütçe/taahhüt kayıtlarında seçilemez; mevcut kayıtlarda görünmeye devam eder.',
                style: AppTypography.helper,
              ),
              if (canManage) ...[
                const SizedBox(height: AppSpacing.xl),
                PrimaryButton(label: 'Düzenle', icon: Icons.edit_outlined, onPressed: _busy ? null : () => _edit(c)),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: c.isActive ? AppColors.danger : AppColors.success),
                  onPressed: _busy ? null : () => _toggleActive(c),
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(c.isActive ? Icons.archive_outlined : Icons.unarchive_outlined, size: 18),
                  label: Text(c.isActive ? 'Arşivle' : 'Etkinleştir'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Kategori çipleri, liste ekranı hâlâ yığında açıksa onun verisinden
  /// gelir; değilse (derin bağlantı) ek bir istek atılmaz, çipsiz açılır.
  List<String> _knownCategories() {
    if (!ref.exists(costCodesListProvider)) return const [];
    return distinctCategories(ref.read(costCodesListProvider).valueOrNull ?? const []);
  }

  Future<void> _edit(OrganizationCostCode c) async {
    final saved = await showCostCodeFormSheet(context, existing: c, categories: _knownCategories());
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Maliyet kodu kaydedildi.')));
    }
  }

  Future<void> _toggleActive(OrganizationCostCode c) async {
    final archiving = c.isActive;
    final ok = await confirmCostCodeAction(
      context,
      title: archiving ? 'Maliyet Kodunu Arşivle' : 'Maliyet Kodunu Etkinleştir',
      message: archiving
          ? '"${c.name}" (${c.code}) arşivlenecek — yeni bütçe/taahhüt kayıtlarında seçilemeyecek, ama mevcut '
              'kayıtlarda görünmeye devam edecek.'
          : '"${c.name}" (${c.code}) yeniden etkinleştirilecek.',
      confirmLabel: archiving ? 'Arşivle' : 'Etkinleştir',
      danger: archiving,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(costCodesRepositoryProvider);
      if (archiving) {
        await repo.archive(c.id);
      } else {
        await repo.reactivate(c.id);
      }
      ref.invalidate(costCodeDetailProvider(c.id));
      ref.invalidate(costCodesListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(archiving ? 'Maliyet kodu arşivlendi.' : 'Maliyet kodu yeniden etkinleştirildi.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(costCodeErrorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
