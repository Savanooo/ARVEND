import 'package:flutter/material.dart';

import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_card.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import 'dashboard_nav.dart';
import 'module_card.dart';

/// FİRMA KAYITLARI -- mobilde tek gruplu kart (spec §6.4): Müşteriler,
/// Personel, Ürünler & Zam, Ekip, Metraj, Tedarikçiler, Maliyet Kodları.
/// Mobilde ekranı olanlar (Müşteriler, Metraj) açılır; diğerleri web
/// panelinden yönetilir (spec §9.13). Bu modüllerin dikkat satırları
/// (price_sync_*, users_without_project) Dikkat panelindedir; kurulum
/// modunda Dikkat gizli olduğu için ait oldukları satırın altında
/// gösterilir (ör. Ürünler & Zam altında "Demir Profil fiyat kaynağı hiç
/// senkronlanmadı", spec §8.2).
class RecordsGroupCard extends StatelessWidget {
  const RecordsGroupCard({super.key, required this.modules, required this.cardContext});

  final List<ModuleKey> modules;
  final DashCardContext cardContext;

  @override
  Widget build(BuildContext context) {
    final c = cardContext;
    final rows = [for (final m in modules) _RecordRowData.of(m, c)];
    final anyUnrouted = rows.any((r) => kModules[r.key]!.route == null);
    return AppCard(
      key: const ValueKey('modul-firma-kayitlari'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
            _RecordRow(
              data: rows[i],
              onRetry: c.onRetry,
              groups: c.onboardingActive && !rows[i].failed ? moduleGroups(c.data, rows[i].key) : const [],
              cta: _emptyCta(rows[i], c),
            ),
          ],
          if (anyUnrouted)
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
              child: Text(kCopyRegistryFooter, style: AppTypography.helper),
            ),
        ],
      ),
    );
  }
}

/// Boş satırın CTA'sı (spec §7.4) -- yalnızca mobilde ekranı olan ve izni
/// verilen işlem: Müşteri Ekle (customers.manage). Personel/Kullanıcı Ekle
/// ve Ürünlere git web panelindedir (spec §9.13).
({String label, VoidCallback onPressed})? _emptyCta(_RecordRowData row, DashCardContext c) {
  if (!row.empty) return null;
  if (row.key == ModuleKey.customers && c.user.canAll(QuickActionKey.customer.permissions)) {
    return (label: QuickActionKey.customer.label, onPressed: () => c.onQuickAction(QuickActionKey.customer));
  }
  return null;
}

class _RecordRowData {
  const _RecordRowData({
    required this.key,
    required this.detail,
    this.notes = const [],
    this.failed = false,
    this.empty = false,
  });

  final ModuleKey key;
  final String detail;
  final List<String> notes;
  final bool failed;

  /// Detay bir boş durum cümlesidir (spec §7.4), veri değeri değil --
  /// soluk, normal kalınlıkta çizilir.
  final bool empty;

  static String _n(int v) => Formatters.compactNumber(v);

  factory _RecordRowData.of(ModuleKey key, DashCardContext c) {
    if (c.failed(key)) return _RecordRowData(key: key, detail: kCopySectionError, failed: true);
    final s = c.data.sections;
    switch (key) {
      case ModuleKey.customers:
        final v = s.customers!;
        if (v.active == 0 && v.newThisMonth == 0) {
          return _RecordRowData(key: key, detail: 'Henüz müşteri yok.', empty: true);
        }
        return _RecordRowData(key: key, detail: '${_n(v.active)} aktif · bu ay +${_n(v.newThisMonth)}');
      case ModuleKey.employees:
        final v = s.employees!;
        if (v.active + v.inactive == 0) {
          return _RecordRowData(key: key, detail: 'Henüz personel eklenmedi.', empty: true);
        }
        return _RecordRowData(key: key, detail: '${_n(v.active)} aktif');
      case ModuleKey.products:
        final v = s.products!;
        final notes = <String>[
          for (final src in v.priceSources)
            if (src.lastStatus == 'success' && (src.daysSinceSync ?? 0) > 7)
              '${priceSourceName(src.source)} fiyatları ${src.daysSinceSync}${kNbsp}gündür güncellenmedi',
          if (v.priceSources.isEmpty) 'Fiyat kaynağı bağlı değil.',
        ];
        if (v.total == 0) {
          return _RecordRowData(
            key: key,
            detail: 'Katalog boş. Ulaş veya Demir Profil fiyat kaynağını bağlayarak ürünleri içe aktarabilirsin.',
            notes: notes,
            empty: true,
          );
        }
        final parts = [
          '${_n(v.total)} ürün',
          if (v.productsIncreased > 0) '30${kNbsp}günde ${_n(v.productsIncreased)} zam',
          if (v.avgIncreasePercent != null) 'ort.$kNbsp${Formatters.percent(v.avgIncreasePercent!)}',
        ];
        return _RecordRowData(key: key, detail: parts.join(' · '), notes: notes);
      case ModuleKey.users:
        final v = s.users!;
        final notes = [
          if (v.withoutEmployeeLink > 0)
            '${_n(v.withoutEmployeeLink)} kullanıcının personel kaydı yok; görev listeleri boş görünür.',
        ];
        if (v.active <= 1) {
          return _RecordRowData(
            key: key,
            detail: 'Ekipte yalnızca sen varsın. Ekip arkadaşlarını davet et.',
            empty: true,
          );
        }
        final parts = [
          '${_n(v.active)} aktif',
          if (v.restrictedWithoutProject > 0) '${_n(v.restrictedWithoutProject)} projesiz',
        ];
        return _RecordRowData(key: key, detail: parts.join(' · '), notes: notes);
      case ModuleKey.calculations:
        final v = s.calculations!;
        if (v.groups == 0) return _RecordRowData(key: key, detail: 'Henüz metraj grubu yok.', empty: true);
        return _RecordRowData(
          key: key,
          detail: '${_n(v.groups)} grup · ${_n(v.categories)} kategori',
          notes: [
            if ((v.usedInOfferLines30d ?? 0) > 0)
              'Son 30${kNbsp}günde ${_n(v.usedInOfferLines30d!)} teklif kaleminde kullanıldı',
            if ((v.recipeItemsUnlinked ?? 0) > 0) '${_n(v.recipeItemsUnlinked!)} reçete kalemi ürüne bağlı değil',
          ],
        );
      case ModuleKey.suppliers:
        final v = s.suppliers!;
        if (v.active + v.inactive == 0) return _RecordRowData(key: key, detail: 'Henüz tedarikçi yok.', empty: true);
        return _RecordRowData(
          key: key,
          detail: '${_n(v.active)} aktif',
          notes: [if ((v.orderedThisMonth ?? 0) > 0) 'Bu ay ${_n(v.orderedThisMonth!)} tedarikçiden sipariş verildi'],
        );
      case ModuleKey.costCodes:
        final v = s.costCodes!;
        if (v.active + v.inactive == 0) {
          return _RecordRowData(key: key, detail: 'Henüz maliyet kodu yok.', empty: true);
        }
        return _RecordRowData(
          key: key,
          detail: '${_n(v.active)} aktif',
          notes: [
            if ((v.expensesWithoutCodeMonth ?? 0) > 0)
              'Bu ay ${_n(v.expensesWithoutCodeMonth!)} masrafta maliyet kodu yok',
          ],
        );
      default:
        return _RecordRowData(key: key, detail: '');
    }
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.data, required this.onRetry, this.groups = const [], this.cta});

  final _RecordRowData data;
  final VoidCallback onRetry;

  /// Kurulum modunda bu modülün dikkat satırları (Dikkat gizli, §8.2).
  final List<AttentionGroup> groups;
  final ({String label, VoidCallback onPressed})? cta;

  @override
  Widget build(BuildContext context) {
    final def = kModules[data.key]!;
    final route = data.failed ? null : def.route;
    return InkWell(
      key: ValueKey('kayit-${data.key.wire}'),
      onTap: route == null ? null : () => openModuleRoute(context, route),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(def.icon, size: 20, color: AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(def.title, style: AppTypography.cardTitle),
                    const SizedBox(height: 2),
                    Text(
                      data.detail,
                      style: data.failed
                          ? AppTypography.helper.copyWith(color: AppStatusColors.error)
                          : data.empty
                          // Boş durum cümlesi: EmptyCardBody gibi soluk, normal kalınlık.
                          ? AppTypography.body.copyWith(
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w400,
                              fontSize: 13,
                            )
                          : AppTypography.body.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                    ),
                    for (final note in data.notes)
                      Padding(padding: const EdgeInsets.only(top: 2), child: CardNote(note)),
                    if (cta != null)
                      TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                        onPressed: cta!.onPressed,
                        child: Text(cta!.label),
                      ),
                    if (groups.isNotEmpty) AttentionFooter(groups: groups, quiet: false),
                  ],
                ),
              ),
              if (data.failed)
                TextButton(onPressed: onRetry, child: const Text(kCopyRetry))
              else if (route != null)
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
