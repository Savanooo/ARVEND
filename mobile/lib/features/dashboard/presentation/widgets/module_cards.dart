import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/segment_bar.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import '../../domain/mobile_routes.dart';
import 'dashboard_nav.dart';
import 'module_card.dart';
import 'my_tasks_card.dart';

/// Standart modül kartları -- modül başına bir oluşturucu (spec §2). FİRMA
/// KAYITLARI modülleri mobilde tek gruplu karttadır (records_group_card).
/// Hiçbiri para toplamaz: değerler sunucudan gelir, burada biçimlenir;
/// birden çok para biriminde `[0]` (birincil) gösterilir, diğerleri
/// "Diğer: …" notudur (spec D13).
Widget buildModuleCard(ModuleKey key, DashCardContext c) {
  final def = kModules[key]!;
  final groups = moduleGroups(c.data, key);
  final Widget body = c.failed(key) ? const SizedBox.shrink() : _body(key, c);
  return ModuleCardFrame(
    key: ValueKey('modul-${key.wire}'),
    def: def,
    groups: groups,
    failed: c.failed(key),
    onRetry: c.onRetry,
    child: body,
  );
}

Widget _body(ModuleKey key, DashCardContext c) => switch (key) {
  ModuleKey.finance => _FinanceBody(c),
  ModuleKey.offers => _OffersBody(c),
  ModuleKey.changeOrders => _ChangeOrdersBody(c),
  ModuleKey.projects => _ProjectsBody(c),
  ModuleKey.tasks => _TasksBody(c),
  ModuleKey.operations => _OperationsBody(c),
  ModuleKey.contracts => _ContractsBody(c),
  ModuleKey.attendance => _AttendanceBody(c),
  ModuleKey.procurement => _ProcurementBody(c),
  ModuleKey.subcontracts => _SubcontractsBody(c),
  ModuleKey.costControl => _CostControlBody(c),
  _ => const SizedBox.shrink(),
};

String _money(double amount, String currency) => Formatters.moneyCompact(amount, currency: currency);
String _n(int value) => Formatters.compactNumber(value);

/// "Diğer: 45.000 $ · 12.000 €" -- birincil dışındaki para birimleri.
/// Tam birime yuvarlanınca sıfır kalanlar gösterilmez (kpi_grid ile aynı kural).
String? _others<T>(List<T> rows, double Function(T row) value, String Function(T row) format) {
  final rest = rows.skip(1).where((r) => value(r).abs() >= 0.5).toList();
  return rest.isEmpty ? null : 'Diğer: ${rest.map(format).join(' · ')}';
}

class _Body extends StatelessWidget {
  const _Body({required this.children});
  final List<Widget?> children;

  @override
  Widget build(BuildContext context) {
    final items = [for (final c in children) ?c];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(height: AppSpacing.md), items[i]],
      ],
    );
  }
}

// ---------- 1. Proje Finansı ----------

class _FinanceBody extends StatelessWidget {
  const _FinanceBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final rows = c.data.sections.finance?.byCurrency ?? const <DashFinanceCurrency>[];
    if (rows.isEmpty) {
      final canCollect = c.user.can('projects.finance.manage');
      return EmptyCardBody(
        text: 'Henüz tahsilat ya da masraf kaydı yok. Kayıtlar proje sayfasındaki Finans sekmesinden girilir.',
        ctaLabel: canCollect ? QuickActionKey.collection.label : null,
        onCta: canCollect ? () => c.onQuickAction(QuickActionKey.collection) : null,
      );
    }
    final f = rows.first;
    // Diğer para birimlerinin AÇIK ALACAĞI -- not istatistik satırının
    // hemen altında durduğu için "Açık alacak" KPI'ıyla aynı değer (spec §2
    // satır 1, web FinanceCard).
    final others = _others(rows, (r) => r.openReceivable, (r) => _money(r.openReceivable, r.currency));
    final pct = f.collectionPct;
    return _Body(
      children: [
        PrimaryMetric(value: _money(f.portfolioValue, f.currency), label: 'Portföy değeri'),
        // Tahsilat oranı hesaplanamıyorsa (portföy 0) çubuk hiç çizilmez.
        if (pct != null)
          CaptionedProgress(
            pct: pct,
            color: AppStatusColors.success,
            caption: '${Formatters.percent(pct)} tahsil edildi',
          ),
        StatsGrid(
          stats: [
            ModuleStat(_money(f.collectedTotal, f.currency), 'Tahsil edilen'),
            ModuleStat(_money(f.openReceivable, f.currency), 'Açık alacak'),
            ModuleStat(_money(f.realizedCost, f.currency), 'Harcanan'),
          ],
        ),
        if (others != null) CardNote(others),
      ],
    );
  }
}

// ---------- 2. Teklifler ----------

class _OffersBody extends StatelessWidget {
  const _OffersBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final o = c.data.sections.offers!;
    if (o.totalActive == 0) {
      final canCreate = c.user.can('offers.create');
      return EmptyCardBody(
        text: 'Henüz teklif yok. İlk teklifini hazırlayıp müşterine bağlantıyla gönderebilirsin.',
        ctaLabel: canCreate ? QuickActionKey.offer.label : null,
        onCta: canCreate ? () => c.onQuickAction(QuickActionKey.offer) : null,
      );
    }
    final oc = o.byCurrency.isEmpty ? null : o.byCurrency.first;
    final others = _others(o.byCurrency, (r) => r.awaitingCustomer.amount, (r) => _money(r.awaitingCustomer.amount, r.currency));
    final accepted = oc?.accepted90d.count ?? 0;
    final rejected = oc?.rejected90d.count ?? 0;
    return _Body(
      children: [
        PrimaryMetric(
          value: oc == null ? '0' : _money(oc.awaitingCustomer.amount, oc.currency),
          label: 'Yanıt bekleyen · ${oc?.awaitingCustomer.count ?? 0} teklif',
        ),
        StatsGrid(
          stats: [
            ModuleStat(_n(oc?.draft.count ?? 0), 'Taslak'),
            ModuleStat(_n(o.viewedByCustomer7d), 'Müşteri inceledi (7${kNbsp}gün)'),
            ModuleStat(
              o.conversionRate90dPct == null ? '–' : Formatters.percent(o.conversionRate90dPct!),
              'Kabul oranı (90${kNbsp}gün)',
            ),
          ],
        ),
        if (accepted + rejected > 0)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('SON 90 GÜN', style: AppTypography.overline),
              const SizedBox(height: 6),
              AppSegmentBar(
                segments: [
                  SegmentData(label: 'Kabul', value: accepted, color: AppColors.success),
                  SegmentData(label: 'Red', value: rejected, color: AppColors.danger),
                ],
              ),
            ],
          ),
        if (o.expiringWithin7d > 0) CardNote('${o.expiringWithin7d} teklifin süresi 7${kNbsp}gün içinde doluyor'),
        if (others != null) CardNote(others),
      ],
    );
  }
}

// ---------- 3. Ek İşler ----------

class _ChangeOrdersBody extends StatelessWidget {
  const _ChangeOrdersBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final rows = c.data.sections.changeOrders?.byCurrency ?? const <DashChangeOrderCurrency>[];
    if (rows.isEmpty) {
      return const EmptyCardBody(
        text:
            'Bekleyen ek iş yok. Sözleşme dışı işler için proje sayfasından ek iş oluşturup müşteriye onaya '
            'gönderebilirsin.',
      );
    }
    final r = rows.first;
    final net = r.approvedNetThisMonth;
    final others = _others(rows, (x) => x.awaitingCustomer.amount, (x) => _money(x.awaitingCustomer.amount, x.currency));
    return _Body(
      children: [
        PrimaryMetric(
          value: '${r.awaitingCustomer.count} · ${_money(r.awaitingCustomer.amount, r.currency)}',
          label: 'Müşteri onayında',
        ),
        StatsGrid(
          stats: [
            ModuleStat('${r.draft.count} · ${_money(r.draft.amount, r.currency)}', 'Taslak'),
            ModuleStat(
              Formatters.signedMoneyCompact(net, currency: r.currency),
              'Bu ay onaylanan (net)',
              color: signedValueColor(net),
            ),
          ],
        ),
        if (others != null) CardNote(others),
      ],
    );
  }
}

// ---------- 4. Projeler ----------

class _ProjectsBody extends StatelessWidget {
  const _ProjectsBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final p = c.data.sections.projects!;
    final counts = p.counts;
    final viewer = c.data.viewer;
    if (counts.total == 0) {
      if (!viewer.allProjects) {
        return const EmptyCardBody(
          text: 'Henüz bir projeye eklenmedin. Yöneticin seni bir projeye eklediğinde projelerin burada görünür.',
        );
      }
      final canOffers = c.user.can('offers.read');
      return EmptyCardBody(
        text: 'Henüz proje yok. Projeler, kabul edilen tekliflerden oluşturulur.',
        ctaLabel: canOffers ? 'Tekliflere git' : null,
        onCta: canOffers ? () => context.go('/teklifler') : null,
      );
    }
    final open = counts.planned + counts.active + counts.paused;
    // Kart anatomisi (spec §6.4): birincil metrik -> istatistikler -> tek
    // görsel -> liste/alt satır.
    return _Body(
      children: [
        PrimaryMetric(value: _n(counts.active), label: 'Aktif proje · toplam ${_n(counts.total)}'),
        StatsGrid(
          stats: [
            ModuleStat(_n(counts.planned), 'Planlanan'),
            ModuleStat(_n(p.pastEndDate), 'Bitişi geçen'),
            ModuleStat(_n(p.endingWithin30d), '30${kNbsp}günde bitecek'),
          ],
        ),
        AppSegmentBar(
          segments: [
            SegmentData(label: 'Planlandı', value: counts.planned, color: AppColors.textMuted.withValues(alpha: 0.4)),
            SegmentData(label: 'Devam', value: counts.active, color: AppColors.gold),
            SegmentData(label: 'Beklemede', value: counts.paused, color: AppColors.textMuted.withValues(alpha: 0.7)),
            SegmentData(label: 'Tamamlandı', value: counts.completed, color: AppColors.success),
            // Yalnızca açıklamada, renksiz (web legendExtra) -- iptal bir
            // alarm durumu değildir (D7).
            SegmentData(label: 'İptal', value: counts.cancelled, color: AppColors.textMuted, legendOnly: true),
          ],
        ),
        if (open == 0)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CardNote('Açık proje yok · ${_n(counts.completed)} tamamlanan proje'),
              if (counts.completed > 0)
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                  onPressed: () => context.go('/projeler?status=completed'),
                  child: const Text('Tamamlananlar'),
                ),
            ],
          )
        else if (p.top.isNotEmpty)
          Column(
            children: [
              for (var i = 0; i < p.top.length && i < 3; i++) ...[
                if (i > 0) const Divider(height: 1),
                _ProjectRow(row: p.top[i]),
              ],
            ],
          ),
      ],
    );
  }
}

/// Ana sayfa proje satırının durum rozeti: web ve kartın kendi açıklamasıyla
/// AYNI ad ("Beklemede") ve nötr ton -- kart gövdesinde alarm rengi olmaz
/// (spec §1.3 kural 8). Genel `StatusRegistry.project`'teki
/// "Durduruldu"/warning proje ekranlarına özgü kalır. Satırlar yalnızca
/// açık projelerdir (planlandı/aktif/beklemede).
const _kHomeProjectStatus = <String, (String, StatusTone)>{
  'planned': ('Planlandı', StatusTone.muted),
  'active': ('Aktif', StatusTone.info),
  'paused': ('Beklemede', StatusTone.muted),
};

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.row});
  final DashProjectRow row;

  @override
  Widget build(BuildContext context) {
    final days = row.daysToEnd;
    final endText = days != null && days < 0
        ? '${-days}${kNbsp}gün gecikti'
        : (row.endDate == null ? null : 'Bitiş ${Formatters.date(row.endDate)}');
    return CardListRow(
      route: mobileRouteFor(row.ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusRegistry.build(row.status, _kHomeProjectStatus),
            ],
          ),
          const SizedBox(height: 2),
          Text([row.projectNo, ?endText].join(' · '), style: AppTypography.helper),
          const SizedBox(height: 4),
          LabeledBar(label: 'Süre', pct: row.timeProgressPct, color: AppColors.textMuted),
          if (row.taskProgressPct != null) LabeledBar(label: 'Görev', pct: row.taskProgressPct, color: AppColors.gold),
          if (row.collectionPct != null)
            LabeledBar(label: 'Tahsilat', pct: row.collectionPct, color: AppStatusColors.success),
        ],
      ),
    );
  }
}

// ---------- 5. Görevler ----------

class _TasksBody extends StatelessWidget {
  const _TasksBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final t = c.data.sections.tasks!;
    final linked = t.mine.linkedEmployee;
    return _Body(
      children: [
        linked
            ? PrimaryMetric(value: _n(t.mine.open), label: 'Açık görevim')
            : PrimaryMetric(value: _n(t.team.open), label: 'Ekipte açık görev'),
        StatsGrid(
          stats: [
            if (linked) ModuleStat(_n(t.mine.overdue), 'Gecikmiş'),
            if (linked) ModuleStat(_n(t.mine.dueToday), 'Bugün'),
            ModuleStat(_n(t.team.unassigned), 'Atanmamış'),
            ModuleStat(_n(t.team.completed7d), 'Son 7${kNbsp}günde tamamlanan'),
          ],
        ),
        if (linked && t.mine.open == 0) const CardNote('Sana atanmış açık görev yok.'),
        if (!linked && !c.data.viewer.isAdmin)
          const CardNote(
            'Hesabın bir personel kaydına bağlı değil; sana atanan görevler burada görünmez. '
            'Yöneticinden bağlamasını iste.',
          ),
        if (linked && !c.hideTaskList && t.mine.items.isNotEmpty)
          Column(
            children: [
              for (var i = 0; i < t.mine.items.length && i < 3; i++) ...[
                if (i > 0) const Divider(height: 1),
                MyTaskRow(task: t.mine.items[i], today: c.data.today),
              ],
            ],
          ),
      ],
    );
  }
}

// ---------- 6. Şantiye ----------

class _OperationsBody extends StatelessWidget {
  const _OperationsBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final o = c.data.sections.operations!;
    if (o.activeCrew == 0 && o.milestonesDue7d == 0 && o.milestonesOverdue == 0 && o.photos7d == 0) {
      return const EmptyCardBody(text: 'Son 7 günde şantiye kaydı yok.');
    }
    return _Body(
      children: [
        PrimaryMetric(value: '${_n(o.activeCrew)}${kNbsp}kişi', label: 'Sahadaki ekip'),
        StatsGrid(
          stats: [
            ModuleStat(_n(o.milestonesDue7d), '7${kNbsp}günde biten iş kalemi'),
            ModuleStat(_n(o.milestonesOverdue), 'Geciken iş kalemi'),
            ModuleStat(_n(o.photos7d), 'Fotoğraf (7${kNbsp}gün)'),
          ],
        ),
      ],
    );
  }
}

// ---------- 7. Sözleşmeler ----------

class _ContractsBody extends StatelessWidget {
  const _ContractsBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final k = c.data.sections.contracts!;
    final total = k.draft + k.active + k.completed + k.cancelled + k.terminated;
    if (total == 0 && k.activeProjectsWithoutContract == 0) {
      return const EmptyCardBody(
        text: 'Henüz sözleşme kaydı yok. Sözleşmeler proje sayfasındaki Finans sekmesinden açılır.',
      );
    }
    return _Body(
      children: [
        PrimaryMetric(value: _n(k.active), label: 'Aktif sözleşme'),
        StatsGrid(
          stats: [
            ModuleStat(_n(k.draft), 'Taslak'),
            ModuleStat(_n(k.activeProjectsWithoutContract), 'Sözleşmesiz aktif proje'),
            ModuleStat(_n(k.pastPlannedCompletion), 'Bitişi geçen'),
          ],
        ),
        if (total > 0)
          AppSegmentBar(
            segments: [
              SegmentData(label: 'Taslak', value: k.draft, color: AppColors.textMuted.withValues(alpha: 0.4)),
              SegmentData(label: 'Aktif', value: k.active, color: AppColors.gold),
              SegmentData(label: 'Tamamlandı', value: k.completed, color: AppColors.success),
              SegmentData(label: 'İptal/Fesih', value: k.cancelled + k.terminated, color: AppColors.danger),
            ],
          ),
      ],
    );
  }
}

// ---------- 8. Mesai / Puantaj ----------

class _AttendanceBody extends StatelessWidget {
  const _AttendanceBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final a = c.data.sections.attendance!;
    if (a.activeEmployees == 0) {
      return const _Body(
        children: [
          EmptyCardBody(text: 'Mesai takibi için önce personel ekle.'),
          CardNote('Firma geneli'),
        ],
      );
    }
    final recorded = a.present + a.halfDay + a.absent + a.onLeave;
    final canEnter = c.user.canAll(QuickActionKey.attendance.permissions);
    return _Body(
      children: [
        PrimaryMetric(value: '${_n(a.onSite)} / ${_n(a.activeEmployees)}', label: 'Bugün sahada'),
        const CardNote('Firma geneli'),
        AppSegmentBar(
          segments: [
            SegmentData(label: 'Geldi', value: a.present, color: AppColors.success),
            SegmentData(label: 'Yarım gün', value: a.halfDay, color: AppColors.gold),
            SegmentData(label: 'Gelmedi', value: a.absent, color: AppColors.danger),
            SegmentData(label: 'İzinli', value: a.onLeave, color: AppColors.textMuted.withValues(alpha: 0.4)),
            SegmentData(label: 'Girilmedi', value: a.notRecorded, color: AppColors.border, dashed: true),
          ],
        ),
        StatsGrid(
          stats: [
            ModuleStat(_n(a.absent), 'Gelmedi'),
            ModuleStat(_n(a.onLeave), 'İzinli'),
            ModuleStat(_n(a.notRecorded), 'Girilmedi'),
            ModuleStat('${Formatters.decimal(a.monthWorkHours)}${kNbsp}sa', 'Bu ay toplam'),
          ],
        ),
        if (!c.data.isWorkday)
          const CardNote('Bugün Pazar — mesai beklenmiyor.')
        else if (recorded == 0)
          EmptyCardBody(
            text: 'Bugün için mesai kaydı girilmedi.',
            ctaLabel: canEnter ? QuickActionKey.attendance.label : null,
            onCta: canEnter ? () => c.onQuickAction(QuickActionKey.attendance) : null,
          ),
      ],
    );
  }
}

// ---------- 9. Satın Alma ----------

class _ProcurementBody extends StatelessWidget {
  const _ProcurementBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final p = c.data.sections.procurement!;
    final allZero =
        p.prDraft + p.prSubmitted + p.rfqIssued + p.poDraft + p.poApprovedOpen == 0 && p.approvedThisMonth.isEmpty;
    if (allZero) {
      return const EmptyCardBody(
        text: 'Açık satın alma kaydı yok. Malzeme ihtiyacı proje sayfasındaki Satın Alma sekmesinden talep edilir.',
      );
    }
    final month = p.approvedThisMonth.isEmpty ? null : p.approvedThisMonth.first;
    return _Body(
      children: [
        PrimaryMetric(value: _n(p.prSubmitted), label: 'Onay bekleyen talep'),
        StatsGrid(
          stats: [
            ModuleStat(_n(p.rfqIssued), 'Açık RFQ'),
            ModuleStat(_n(p.poApprovedOpen), 'Açık sipariş'),
            ModuleStat(_n(p.poLateDelivery), 'Geciken teslimat'),
          ],
        ),
        _FlowRow(
          steps: [
            'Talep ${_n(p.prSubmitted)} onayda',
            'RFQ ${_n(p.rfqIssued)} açık',
            'Sipariş ${_n(p.poApprovedOpen)} açık',
          ],
        ),
        if (month != null)
          CardNote('Bu ay onaylanan: ${month.count} sipariş · ${_money(month.amount, month.currency)}'),
      ],
    );
  }
}

/// "Talep 3 onayda → RFQ 2 açık → Sipariş 4 açık" (dar ekranda sarar).
class _FlowRow extends StatelessWidget {
  const _FlowRow({required this.steps});
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) const Icon(Icons.chevron_right, size: 16, color: AppColors.textMuted),
          Text(steps[i], style: AppTypography.helper.copyWith(color: AppColors.textPrimary)),
        ],
      ],
    );
  }
}

// ---------- 10. Taşeron ----------

class _SubcontractsBody extends StatelessWidget {
  const _SubcontractsBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final s = c.data.sections.subcontracts!;
    if (s.activeCount == 0 && s.byCurrency.isEmpty) {
      return const EmptyCardBody(text: 'Henüz taşeron sözleşmesi yok.');
    }
    final r = s.byCurrency.isEmpty ? null : s.byCurrency.first;
    final claims = s.claims;
    final others = _others(s.byCurrency, (x) => x.currentValue, (x) => _money(x.currentValue, x.currency));
    return _Body(
      children: [
        PrimaryMetric(
          value: r == null ? _n(s.activeCount) : '${_n(s.activeCount)} · ${_money(r.currentValue, r.currency)}',
          label: 'Aktif sözleşme',
        ),
        if (r?.paidPct != null)
          CaptionedProgress(
            pct: r!.paidPct,
            color: AppStatusColors.success,
            caption: '${Formatters.percent(r.paidPct!)} ödendi',
            trailing: const Tooltip(
              message: "Hakedişe bağlanmamış avans ödemeleri 'ödenmemiş' tutarını azaltmaz.",
              triggerMode: TooltipTriggerMode.tap,
              child: Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.info_outline, size: 14, color: AppColors.textMuted),
              ),
            ),
          ),
        StatsGrid(
          stats: [
            if (claims != null) ModuleStat(_n(claims.submitted.count), 'Onayda hakediş'),
            if (claims?.certifiedUnpaid != null) ModuleStat(_n(claims!.certifiedUnpaid!.count), 'Onaylı, ödenmemiş'),
            ModuleStat(_n(s.changeOrdersSubmitted.count), 'Değişiklik emri (onayda)'),
          ],
        ),
        if (others != null) CardNote(others),
      ],
    );
  }
}

// ---------- 11. Bütçe & Maliyet ----------

class _CostControlBody extends StatelessWidget {
  const _CostControlBody(this.c);
  final DashCardContext c;

  @override
  Widget build(BuildContext context) {
    final k = c.data.sections.costControl!;
    final b = k.budgets;
    final noBudgets = b != null && b.draft + b.baselined == 0;
    if (noBudgets && (k.overBudget?.count ?? 0) == 0 && (k.committedActive?.isEmpty ?? true)) {
      return const EmptyCardBody(text: 'Henüz bütçe oluşturulmadı. Bütçe, maliyet kontrolünün temelidir.');
    }
    final over = k.overBudget;
    final committed = k.committedActive;
    return _Body(
      children: [
        if (over != null)
          PrimaryMetric(value: _n(over.count), label: 'Bütçeyi aşan proje')
        else if (b != null)
          PrimaryMetric(value: '${_n(b.baselined)} / ${_n(b.openProjects)} proje', label: 'Onaylı bütçe'),
        StatsGrid(
          stats: [
            if (k.pendingAdjustments != null) ModuleStat(_n(k.pendingAdjustments!.count), 'Onayda revizyon'),
            if (committed != null)
              ModuleStat(
                committed.isEmpty
                    ? _money(0, c.data.primaryCurrency)
                    : _money(committed.first.amount, committed.first.currency),
                'Aktif taahhüt',
              ),
            if (b != null) ModuleStat(_n(b.none), 'Bütçesiz açık proje'),
          ],
        ),
        if (b != null && b.openProjects > 0)
          AppSegmentBar(
            segments: [
              SegmentData(label: 'Bütçesiz', value: b.none, color: AppColors.textMuted.withValues(alpha: 0.4)),
              SegmentData(label: 'Taslak', value: b.draft, color: AppColors.gold),
              SegmentData(label: 'Onaylı', value: b.baselined, color: AppColors.success),
            ],
          ),
        if (_others(committed ?? const [], (m) => m.amount, (m) => _money(m.amount, m.currency)) case final note?)
          CardNote(note),
      ],
    );
  }
}
