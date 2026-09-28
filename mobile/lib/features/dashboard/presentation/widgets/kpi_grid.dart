import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/utils/formatters.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import 'dashboard_nav.dart';
import 'kpi_tile.dart';

/// Nabız: en çok 4 kutucuk (spec §3.3/§6.4). 2 sütun; 3 kutucukta son
/// kutucuk tam genişlik; dar ekranda (içerik < 300dp, ~332dp telefon) ya
/// da yazı ölçeği >= 1,3 iken tek sütun. 2'den az aday varsa çizilmez.
class KpiGrid extends StatelessWidget {
  const KpiGrid({super.key, required this.data, required this.kpis});

  final Dashboard data;
  final List<KpiKey> kpis;

  @override
  Widget build(BuildContext context) {
    if (kpis.length < 2) return const SizedBox.shrink();
    final items = [for (final k in kpis) (k, kpiTileData(context, data, k))];
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final oneColumn = constraints.maxWidth < 300 || scale >= 1.3;
        final tileWidth = oneColumn ? constraints.maxWidth : (constraints.maxWidth - AppSpacing.sm) / 2;
        final labels = _LabelMetrics(context, tileWidth - KpiTile.horizontalChrome);
        final tiles = <KpiTile>[];
        for (var i = 0; i < items.length; i++) {
          // Yan yana iki kutucuktan birinin etiketi sarıyorsa ikisine de iki
          // satırlık etiket alanı: büyük değerler aynı satırda hizalanır.
          // Tek sütunda ve tam genişlikteki son kutucukta komşu yoktur.
          final alone = oneColumn || (i.isEven && i + 1 >= items.length);
          final equalize =
              !alone && (labels.wraps(items[i].$2.label) || labels.wraps(items[i.isEven ? i + 1 : i - 1].$2.label));
          tiles.add(
            KpiTile(
              key: ValueKey('kpi-${items[i].$1.name}'),
              data: items[i].$2,
              labelMinHeight: equalize ? labels.twoLineHeight : null,
            ),
          );
        }
        if (oneColumn) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(height: AppSpacing.sm), tiles[i]],
            ],
          );
        }
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += 2) {
          if (rows.isNotEmpty) rows.add(const SizedBox(height: AppSpacing.sm));
          if (i + 1 < tiles.length) {
            rows.add(
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: tiles[i]),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: tiles[i + 1]),
                  ],
                ),
              ),
            );
          } else {
            rows.add(tiles[i]);
          }
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      },
    );
  }
}

/// KPI etiketinin verilen genişlikte tek satıra sığıp sığmadığını, Text
/// widget'ının kullandığı AYNI stil ve yazı ölçeğiyle ölçer.
class _LabelMetrics {
  _LabelMetrics(BuildContext context, this.width)
    : _style = DefaultTextStyle.of(context).style.merge(AppTypography.metadata),
      _scaler = MediaQuery.textScalerOf(context);

  final double width;
  final TextStyle _style;
  final TextScaler _scaler;

  TextPainter _paint(String text, {int? maxLines}) => TextPainter(
    text: TextSpan(text: text, style: _style),
    textDirection: TextDirection.ltr,
    textScaler: _scaler,
    maxLines: maxLines,
  )..layout(maxWidth: width.clamp(1.0, double.infinity));

  bool wraps(String label) {
    final painter = _paint(label, maxLines: 1);
    final exceeded = painter.didExceedMaxLines;
    painter.dispose();
    return exceeded;
  }

  late final double twoLineHeight = () {
    final painter = _paint('A\nA');
    final height = painter.height;
    painter.dispose();
    return height;
  }();
}

String _c(double v, String currency) => Formatters.moneyCompact(v, currency: currency);
String _sc(double v, String currency) => Formatters.signedMoneyCompact(v, currency: currency);
String _full(double v, String currency) => Formatters.money(v, currency: currency);
String _n(int v) => Formatters.compactNumber(v);

/// "Diğer: 45.000 $" -- birincil dışındaki para birimleri (düz metin).
/// Tam birime yuvarlanınca sıfır kalan para birimleri gösterilmez
/// ("Diğer: 0 $" bilgi taşımaz); web lib/dashboard.ts othersLine ile aynı kural.
String? _others<T>(List<T> rows, double Function(T) value, String Function(T) format) {
  final rest = rows.skip(1).where((r) => value(r).abs() >= 0.5).toList();
  return rest.isEmpty ? null : 'Diğer: ${rest.map(format).join(' · ')}';
}

/// Ekran okuyucu metni: görünen HER bilgi, tutarlar tam haliyle (spec §6.4
/// "Semantics(label: full values)") -- kutucuk içeriği ExcludeSemantics.
String _spoken(List<String?> parts) => [for (final p in parts) ?p].join(', ');

/// KPI anahtarı -> kutucuk içeriği (etiketler spec §7.2).
KpiTileData kpiTileData(BuildContext context, Dashboard d, KpiKey key) {
  final s = d.sections;
  switch (key) {
    case KpiKey.receivable:
      final rows = s.finance!.byCurrency;
      final f = rows.first;
      final pct = f.collectionPct;
      return KpiTileData(
        label: 'Açık alacak',
        value: _c(f.openReceivable, f.currency),
        icon: Icons.account_balance_wallet_outlined,
        progressPct: pct,
        progressColor: AppStatusColors.success,
        subs: [
          if (pct != null) '${Formatters.percent(pct)} tahsil edildi',
          ?_others(rows, (r) => r.openReceivable, (r) => _c(r.openReceivable, r.currency)),
        ],
        semantics: _spoken([
          'Açık alacak ${_full(f.openReceivable, f.currency)}',
          if (pct != null) '${Formatters.percent(pct)} tahsil edildi',
          _others(rows, (r) => r.openReceivable, (r) => _full(r.openReceivable, r.currency)),
        ]),
        onTap: () => context.go('/projeler'),
      );
    case KpiKey.netCash:
      final rows = s.finance!.byCurrency;
      final f = rows.first;
      final m = f.month;
      return KpiTileData(
        label: 'Bu ay net nakit',
        value: _sc(m.netCash, f.currency),
        valueColor: signedValueColor(m.netCash),
        icon: Icons.swap_vert,
        subs: [
          'Giriş ${_c(m.collections, f.currency)}',
          'Çıkış ${_c(m.outflows, f.currency)}',
          ?_others(rows, (r) => r.month.netCash, (r) => _sc(r.month.netCash, r.currency)),
        ],
        semantics: _spoken([
          'Bu ay net nakit ${Formatters.signedMoney(m.netCash, currency: f.currency)}',
          'giriş ${_full(m.collections, f.currency)}',
          'çıkış ${_full(m.outflows, f.currency)}',
          _others(rows, (r) => r.month.netCash, (r) => Formatters.signedMoney(r.month.netCash, currency: r.currency)),
        ]),
      );
    case KpiKey.pipeline:
      final o = s.offers!;
      final r = o.byCurrency.first;
      return KpiTileData(
        label: 'Teklif hattı',
        value: _c(r.awaitingCustomer.amount, r.currency),
        icon: Icons.request_quote_outlined,
        subs: [
          '${_n(r.awaitingCustomer.count)} teklif yanıt bekliyor',
          if (o.conversionRate90dPct != null)
            'Kabul oranı ${Formatters.percent(o.conversionRate90dPct!)} · 90${kNbsp}gün',
          ?_others(o.byCurrency, (x) => x.awaitingCustomer.amount, (x) => _c(x.awaitingCustomer.amount, x.currency)),
        ],
        semantics: _spoken([
          'Teklif hattı ${_full(r.awaitingCustomer.amount, r.currency)}',
          '${r.awaitingCustomer.count} teklif yanıt bekliyor',
          if (o.conversionRate90dPct != null) 'kabul oranı ${Formatters.percent(o.conversionRate90dPct!)}, 90 gün',
          _others(o.byCurrency, (x) => x.awaitingCustomer.amount, (x) => _full(x.awaitingCustomer.amount, x.currency)),
        ]),
        onTap: () => context.go('/teklifler'),
      );
    case KpiKey.cashBalance:
      final rows = s.finance!.byCurrency;
      final f = rows.first;
      return KpiTileData(
        label: 'Proje nakit dengesi',
        value: _sc(f.cashBalance, f.currency),
        valueColor: signedValueColor(f.cashBalance),
        icon: Icons.account_balance_outlined,
        subs: [
          'Tahsilat ${_c(f.collectedTotal, f.currency)} · Harcama ${_c(f.realizedCost, f.currency)}',
          ?_others(rows, (r) => r.cashBalance, (r) => _sc(r.cashBalance, r.currency)),
        ],
        semantics: _spoken([
          'Proje nakit dengesi ${Formatters.signedMoney(f.cashBalance, currency: f.currency)}',
          'tahsilat ${_full(f.collectedTotal, f.currency)}',
          'harcama ${_full(f.realizedCost, f.currency)}',
          _others(rows, (r) => r.cashBalance, (r) => Formatters.signedMoney(r.cashBalance, currency: r.currency)),
        ]),
      );
    case KpiKey.activeProjects:
      final c = s.projects!.counts;
      return KpiTileData(
        label: 'Aktif proje',
        value: _n(c.active),
        icon: Icons.apartment_outlined,
        subs: ['${_n(c.planned)} planlanan · ${_n(c.paused)} beklemede'],
        semantics: 'Aktif proje ${c.active}, ${c.planned} planlanan, ${c.paused} beklemede',
        onTap: () => context.go('/projeler'),
      );
    case KpiKey.myTasks:
      final m = s.tasks!.mine;
      return KpiTileData(
        label: 'Açık görevim',
        value: _n(m.open),
        icon: Icons.checklist,
        subs: ['${_n(m.overdue)} gecikmiş · ${_n(m.dueToday)} bugün'],
        semantics: 'Açık görevim ${m.open}, ${m.overdue} gecikmiş, ${m.dueToday} bugün',
        onTap: () => context.go('/gorevler'),
      );
    case KpiKey.teamOverdue:
      final t = s.tasks!.team;
      return KpiTileData(
        label: 'Ekipte geciken görev',
        value: _n(t.overdue),
        valueColor: t.overdue > 0 ? AppStatusColors.error : null,
        icon: Icons.alarm,
        subs: ['${_n(t.unassigned)} görev atanmamış'],
        semantics: 'Ekipte geciken görev ${t.overdue}, ${t.unassigned} görev atanmamış',
        onTap: () => context.go('/gorevler'),
      );
    case KpiKey.onSite:
      final a = s.attendance!;
      return KpiTileData(
        label: 'Bugün sahada',
        value: '${_n(a.onSite)} / ${_n(a.activeEmployees)}',
        icon: Icons.engineering_outlined,
        subs: ['Firma geneli · ${_n(a.notRecorded)} kişi girilmedi'],
        semantics: 'Bugün sahada ${a.onSite} / ${a.activeEmployees}, firma geneli, ${a.notRecorded} kişi girilmedi',
        onTap: () => context.push('/diger/mesai'),
      );
    case KpiKey.unread:
      final nt = s.notifications!;
      return KpiTileData(
        label: 'Okunmamış bildirim',
        value: _n(nt.unread),
        icon: Icons.notifications_outlined,
        subs: [if (nt.latest.isNotEmpty) nt.latest.first.title],
        semantics: _spoken(['Okunmamış bildirim ${nt.unread}', if (nt.latest.isNotEmpty) nt.latest.first.title]),
        onTap: () => context.push('/diger/bildirimler'),
      );
  }
}
