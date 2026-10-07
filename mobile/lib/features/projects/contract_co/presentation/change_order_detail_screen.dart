import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/event_labels.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_lifecycle_actions.dart';
import '../../../../core/widgets/app_list_card.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../data/projects_providers.dart';
import '../../presentation/destructive_action_button.dart';
import '../contract_co_paths.dart';
import '../data/contract_co_providers.dart';
import '../domain/project_change_order.dart';
import 'change_order_email_sheet.dart';
import 'widgets/contract_co_ui.dart';

/// Ek iş detayı (`/projeler/:id/ek-isler/:coId`) -- web `ChangeOrderCard`'ın
/// genişletilmiş hali: kalemler + toplamlar, müşteri kararı, notlar,
/// dahili kârlılık ve olay geçmişi. Yaşam döngüsü (web ile aynı):
///
/// - Taslak:      Gönder · Düzenle · İptal
/// - Gönderildi:  Mail Gönder · Linki Kopyala · Revize Et · İptal
///                + "Müşteri onayladı/reddetti olarak işaretle"
/// - Reddedildi:  Revize Et
/// - Onaylandı / İptal / Yenilendi: aksiyon yok (final)
///
/// Onay/red MÜŞTERİNİNDİR: normalde paylaşım linkinden verir. Müşteri
/// telefonla/yazılı yanıt verdiyse `projects.change_orders.approve` sahibi
/// (varsayılan Sahip/Yönetici) kararı onay penceresi + isteğe bağlı notla
/// kaydeder -- sunucuda linkle aynı kurallar ve aynı etki. Diğer aksiyonlar
/// `projects.finance.manage` ister. Hepsi proje kapalıyken gizlenir; 409
/// (durum başka yerde değişti, ör. müşteri az önce onayladı) sunucu
/// mesajıyla gösterilip ekran tazelenir.
class ChangeOrderDetailScreen extends ConsumerStatefulWidget {
  const ChangeOrderDetailScreen({super.key, required this.projectId, required this.changeOrderId});

  final String projectId;
  final String changeOrderId;

  @override
  ConsumerState<ChangeOrderDetailScreen> createState() => _ChangeOrderDetailScreenState();
}

class _ChangeOrderDetailScreenState extends ConsumerState<ChangeOrderDetailScreen> {
  bool _busy = false;

  ChangeOrderKey get _key => (projectId: widget.projectId, changeOrderId: widget.changeOrderId);

  /// Eşzamanlı yerlerde (pull-to-refresh). Yazmalar kapsayıcının ilk
  /// await'ten önce alınmış `invalidate`'ini kullanır: istek sürerken geri
  /// basılıp ekran kapansa da liste/detay/değer özeti tazelenir.
  void _invalidateWith(void Function(ProviderOrFamily provider) invalidate) =>
      invalidateChangeOrders(invalidate, widget.projectId, changeOrderId: widget.changeOrderId);

  Future<void> _refresh() async {
    _invalidateWith(ref.invalidate);
    try {
      await ref.read(projectChangeOrderDetailProvider(_key).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  /// Yazma aksiyonu: başarıda mesaj + tazele; hatada sunucu mesajı, 409'da
  /// ayrıca tazele (güncel duruma göre düğmeler yeniden hesaplansın).
  Future<T?> _run<T>(Future<T> Function() action, {String? success}) async {
    setState(() => _busy = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      final result = await action();
      _invalidateWith(invalidate);
      if (mounted && success != null) showContractCoSnack(context, success);
      return result;
    } catch (e) {
      if (isConflictError(e)) _invalidateWith(invalidate);
      if (mounted) showContractCoSnack(context, contractCoErrorText(e));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send(ProjectChangeOrder co) async {
    final ok = await showContractCoConfirm(
      context,
      title: 'Ek İşi Gönder',
      message: '${co.changeOrderNo} müşteriye gönderilsin mi? Gönderildikten sonra düzenlenemez; müşteri '
          'paylaşım linkinden onaylayabilir veya reddedebilir.',
      confirmLabel: 'Gönder',
    );
    if (!ok) return;
    await _run(
      () => ref.read(contractCoRepositoryProvider).sendChangeOrder(widget.projectId, co.id),
      success: '${co.changeOrderNo} müşteriye gönderildi.',
    );
  }

  Future<void> _cancel(ProjectChangeOrder co) async {
    final ok = await showContractCoConfirm(
      context,
      title: 'Ek İşi İptal Et',
      message: 'Bu ek işi iptal etmek istediğine emin misin? Paylaşım linki de geçersiz olur.',
      confirmLabel: 'İptal Et',
      danger: true,
    );
    if (!ok) return;
    await _run(
      () => ref.read(contractCoRepositoryProvider).cancelChangeOrder(widget.projectId, co.id),
      success: '${co.changeOrderNo} iptal edildi.',
    );
  }

  Future<void> _revise(ProjectChangeOrder co) async {
    final ok = await showContractCoConfirm(
      context,
      title: 'Revize Et',
      message: 'Aynı içerikle yeni bir taslak açılır. ${co.changeOrderNo} "Yenilendi" durumuna geçer ve '
          'paylaşım linki iptal edilir.',
      confirmLabel: 'Revize Et',
    );
    if (!ok) return;
    final revised = await _run(
      () => ref.read(contractCoRepositoryProvider).reviseChangeOrder(widget.projectId, co.id),
      success: 'Yeni revizyon (taslak) oluşturuldu.',
    );
    if (revised != null && mounted) {
      context.pushReplacement(projectChangeOrderPath(widget.projectId, revised.id));
    }
  }

  Future<void> _email(ProjectChangeOrder co, String defaultTo) async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    final sent = await showChangeOrderEmailSheet(context, projectId: widget.projectId, changeOrder: co, defaultTo: defaultTo);
    // Deneme (başarılı/başarısız) olay geçmişine yazılır -- her durumda tazele.
    invalidate(changeOrderEventsProvider(widget.projectId));
    if (sent == true && mounted) showContractCoSnack(context, 'Mail gönderildi.');
  }

  /// "Müşteri onayladı/reddetti olarak işaretle": onay penceresi + isteğe
  /// bağlı not ("telefonla onay"). Sunucu reddederse (ör. eksiltme proje
  /// bedelini negatife düşürür, müşteri az önce linkten yanıt verdi) sebebi
  /// olduğu gibi gösterilir.
  Future<void> _recordDecision(ProjectChangeOrder co, {required bool approved}) async {
    final effect = Formatters.signedMoney(co.signedTotal, currency: co.currency);
    final note = await showOptionalNoteDialog(
      context,
      title: approved ? 'Müşteri Onayını Kaydet' : 'Müşteri Reddini Kaydet',
      message: approved
          ? '${co.changeOrderNo} müşteri tarafından onaylandı olarak işaretlensin mi? Sonuç müşterinin linkten '
              'onaylamasıyla aynıdır: ek iş kesinleşir ve proje bedeli $effect değişir. Bu işlem geri alınamaz.'
          : '${co.changeOrderNo} müşteri tarafından reddedildi olarak işaretlensin mi? Proje bedeli değişmez; '
              'gerekirse revize ederek yeni bir taslak açabilirsin.',
      confirmLabel: approved ? 'Onaylandı Olarak İşaretle' : 'Reddedildi Olarak İşaretle',
      noteHint: approved ? 'ör. telefonla onay' : 'ör. müşteri yazılı olarak reddetti',
      danger: !approved,
    );
    if (note == null || !mounted) return;
    await _run(
      () => ref
          .read(contractCoRepositoryProvider)
          .recordChangeOrderDecision(widget.projectId, co.id, approved: approved, note: note),
      success: approved
          ? '${co.changeOrderNo} müşteri onayladı olarak işaretlendi.'
          : '${co.changeOrderNo} müşteri reddetti olarak işaretlendi.',
    );
  }

  Future<void> _copyLink(ProjectChangeOrder co) async {
    final token = co.activeShareToken;
    if (token == null) return;
    await Clipboard.setData(ClipboardData(text: changeOrderShareUrl(token)));
    if (mounted) showContractCoSnack(context, 'Link kopyalandı.');
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (isAuthPending(auth)) return const AppPageScaffold(title: Text('Ek İş'), body: LoadingState());
    final user = auth.valueOrNull;
    if (!user.can(kChangeOrdersReadPermission)) {
      return const AppPageScaffold(title: Text('Ek İş'), body: ContractCoNoAccess(message: kChangeOrdersNoAccessText));
    }
    final detailAsync = ref.watch(projectChangeOrderDetailProvider(_key));
    // Kârlılık ve revizyon bağlantıları yalnızca liste ucunda -- detay
    // ekranı listenin (genelde zaten yüklü) aynı kaydını kullanır.
    final list = ref.watch(projectChangeOrderListProvider(widget.projectId)).valueOrNull ?? const [];
    final project = ref.watch(projectDetailProvider(widget.projectId)).valueOrNull;
    final locked = isProjectLocked(project);
    final canManage = user.can(kChangeOrdersManagePermission) && !locked;
    final canRecordDecision = user.can(kChangeOrdersApprovePermission) && !locked;

    return AppPageScaffold(
      title: Text(detailAsync.valueOrNull?.changeOrderNo ?? 'Ek İş'),
      body: detailAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isForbiddenError(e)
            ? const ContractCoNoAccess(message: kChangeOrdersNoAccessText)
            : ErrorState(error: e, onRetry: _refresh),
        data: (detail) {
          ProjectChangeOrder? byId(String? id) =>
              id == null ? null : list.where((c) => c.id == id).firstOrNull;
          final co = detail.withProfitability(byId(detail.id)?.profitability);
          final previous = byId(co.supersedesChangeOrderId);
          final next = list.where((c) => c.supersedesChangeOrderId == co.id).firstOrNull;

          final actions = <AppLifecycleAction>[
            if (canManage && co.canSend)
              AppLifecycleAction(
                label: 'Gönder',
                icon: Icons.send_outlined,
                primary: true,
                loading: _busy,
                onPressed: _busy ? null : () => _send(co),
              ),
            if (canManage && co.canEmail)
              AppLifecycleAction(
                label: 'Mail Gönder',
                icon: Icons.mail_outline,
                primary: true,
                loading: _busy,
                onPressed: _busy ? null : () => _email(co, project?.customerEmail ?? ''),
              ),
            if (canManage && co.status == ProjectChangeOrder.statusRejected)
              AppLifecycleAction(
                label: 'Revize Et',
                icon: Icons.edit_note_outlined,
                primary: true,
                loading: _busy,
                onPressed: _busy ? null : () => _revise(co),
              ),
            if (canManage && co.isEditable)
              AppLifecycleAction(
                label: 'Düzenle',
                icon: Icons.edit_outlined,
                loading: _busy,
                onPressed: _busy ? null : () => context.push(projectChangeOrderEditPath(widget.projectId, co.id)),
              ),
            if (canManage && co.hasShareLink)
              AppLifecycleAction(
                label: 'Linki Kopyala',
                icon: Icons.link,
                loading: _busy,
                onPressed: _busy ? null : () => _copyLink(co),
              ),
            if (canManage && co.status == ProjectChangeOrder.statusSent)
              AppLifecycleAction(
                label: 'Revize Et',
                icon: Icons.edit_note_outlined,
                loading: _busy,
                onPressed: _busy ? null : () => _revise(co),
              ),
          ];
          final canCancel = canManage && co.canCancel;

          final isOpen = co.status == ProjectChangeOrder.statusDraft ||
              co.status == ProjectChangeOrder.statusSent ||
              co.status == ProjectChangeOrder.statusRejected;
          final String? notice = !isOpen
              ? null
              : locked
                  ? kProjectLockedText
                  : !user.can(kChangeOrdersManagePermission)
                      ? kChangeOrdersReadOnlyText
                      : null;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
              children: [
                _HeaderCard(changeOrder: co),
                const SizedBox(height: AppSpacing.md),
                _DecisionNote(
                  changeOrder: co,
                  // Paylaşım linki müşteri adına onay/red verdirir: metni
                  // yalnızca "Linki Kopyala"yı görebilen (finans yönetimi)
                  // kişi görür -- aksi halde o düğmenin kapısı anlamsızdı.
                  showShareUrl: canManage,
                  next: next,
                  onOpenNext: next == null ? null : () => context.push(projectChangeOrderPath(widget.projectId, next.id)),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  AppLifecycleActions(actions: actions),
                ],
                if (canRecordDecision && co.canRecordDecision) ...[
                  const SizedBox(height: AppSpacing.md),
                  _RecordDecisionPanel(
                    busy: _busy,
                    onApproved: () => _recordDecision(co, approved: true),
                    onRejected: () => _recordDecision(co, approved: false),
                  ),
                ],
                // Geri alınamaz iptal çubuktan ayrı, kırmızı.
                if (canCancel) ...[
                  SizedBox(height: actions.isEmpty ? AppSpacing.lg : AppSpacing.sm),
                  DestructiveActionButton(
                    label: 'İptal Et',
                    loading: _busy,
                    onPressed: _busy ? null : () => _cancel(co),
                  ),
                ],
                if (notice != null) ...[const SizedBox(height: AppSpacing.md), ReadOnlyNotice(notice)],
                if (previous != null || co.supersedesChangeOrderId != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  AppListCard(
                    leading: const Icon(Icons.history, color: AppColors.textMuted, size: 20),
                    title: previous == null ? 'Önceki revizyon' : 'Önceki revizyon: ${previous.changeOrderNo}',
                    subtitle: previous?.title,
                    trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
                    onTap: () => context.push(projectChangeOrderPath(widget.projectId, co.supersedesChangeOrderId!)),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                const AppSectionHeader(title: 'Kalemler'),
                const SizedBox(height: AppSpacing.sm),
                if (co.items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Text('Kalem yok.', style: AppTypography.metadata),
                  )
                else
                  for (final item in co.items) _ItemCard(item: item, currency: co.currency),
                const SizedBox(height: AppSpacing.sm),
                _TotalsCard(changeOrder: co),
                if (co.customerNotes.isNotEmpty || co.internalNotes.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  ContractCoCard(
                    title: 'Notlar',
                    children: [
                      if (co.customerNotes.isNotEmpty) ContractCoInfoRow(label: 'Müşteri Notu', value: co.customerNotes),
                      if (co.internalNotes.isNotEmpty)
                        ContractCoInfoRow(label: 'Dahili Not (yalnızca ekip görür)', value: co.internalNotes),
                    ],
                  ),
                ],
                if (co.profitability != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _ProfitabilityCard(profitability: co.profitability!, currency: co.currency),
                ],
                _EventsSection(projectId: widget.projectId, changeOrder: co),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.changeOrder});

  final ProjectChangeOrder changeOrder;

  @override
  Widget build(BuildContext context) {
    final co = changeOrder;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(co.title, style: AppTypography.sectionTitle, maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusRegistry.build(co.status, StatusRegistry.changeOrder),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${co.typeLabel} · ${co.isAddition ? 'proje bedelini artırır' : 'proje bedelini azaltır'}',
            style: AppTypography.metadata,
          ),
          if (co.description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(co.description, style: AppTypography.body.copyWith(height: 1.4)),
          ],
          const SizedBox(height: AppSpacing.md),
          const Text('Proje bedeline etkisi (KDV dahil)', style: AppTypography.helper),
          const SizedBox(height: 2),
          SignedMoneyText(co.signedTotal, currency: co.currency, style: AppTypography.metricPrimary),
        ],
      ),
    );
  }
}

/// Kararı müşteri linkten değil ekip kaydettiyse: kim ve hangi notla.
List<String> _recordedLines(ProjectChangeOrder co) => [
      if (co.decisionRecordedByStaff)
        co.decisionRecordedByName.isEmpty
            ? 'Müşterinin yanıtını ekip kaydetti.'
            : 'Müşterinin yanıtını ${co.decisionRecordedByName} kaydetti.',
      if (co.decisionNote.isNotEmpty) 'Not: ${co.decisionNote}',
    ];

/// Gönderilmiş ek işte, müşteri telefonla/yazılı yanıt verdiyse kararı
/// kaydetme -- linkteki yanıtla aynı sonucu doğurur (sunucu aynı kod yolu).
class _RecordDecisionPanel extends StatelessWidget {
  const _RecordDecisionPanel({required this.busy, required this.onApproved, required this.onRejected});

  final bool busy;
  final VoidCallback onApproved;
  final VoidCallback onRejected;

  @override
  Widget build(BuildContext context) {
    return ContractCoCard(
      title: 'Müşteri yanıtını kaydet',
      children: [
        const Text(
          'Müşteri telefonla ya da yazılı yanıt verdiyse buradan kaydedebilirsin; sonuç müşterinin linkten '
          'yanıt vermesiyle aynıdır.',
          style: AppTypography.metadata,
        ),
        const SizedBox(height: AppSpacing.md),
        SecondaryButton(
          label: 'Müşteri onayladı olarak işaretle',
          icon: Icons.check_circle_outline,
          loading: busy,
          onPressed: busy ? null : onApproved,
        ),
        const SizedBox(height: AppSpacing.sm),
        SecondaryButton(
          label: 'Müşteri reddetti olarak işaretle',
          icon: Icons.highlight_off,
          loading: busy,
          onPressed: busy ? null : onRejected,
        ),
      ],
    );
  }
}

/// Müşteri kararı / belge durumu -- "ne oldu, sırada ne var" tek notta.
class _DecisionNote extends StatelessWidget {
  const _DecisionNote({required this.changeOrder, required this.showShareUrl, this.next, this.onOpenNext});

  final ProjectChangeOrder changeOrder;

  /// Müşteri paylaşım linkinin metni gösterilsin mi (yalnızca finans
  /// yönetimi izniyle, açık projede -- "Linki Kopyala" ile aynı kapı).
  final bool showShareUrl;
  final ProjectChangeOrder? next;
  final VoidCallback? onOpenNext;

  @override
  Widget build(BuildContext context) {
    final co = changeOrder;
    switch (co.status) {
      case ProjectChangeOrder.statusDraft:
        return const ContractCoStatusNote(
          icon: Icons.edit_note_outlined,
          color: AppColors.textMuted,
          title: 'Taslak',
          lines: ['Müşteriye henüz gönderilmedi. Gönderildiğinde müşteri paylaşım linkinden onaylayabilir veya reddedebilir.'],
        );
      case ProjectChangeOrder.statusSent:
        final token = co.activeShareToken;
        return ContractCoStatusNote(
          icon: Icons.hourglass_top,
          color: AppColors.info,
          title: 'Müşteri yanıtı bekleniyor',
          lines: [
            if (co.sentAt != null) 'Gönderildi: ${formatDateTimeTr(co.sentAt)}',
            if (token == null) 'Aktif paylaşım linki yok.',
            if (token != null && !showShareUrl) 'Müşteri paylaşım linki aktif.',
          ],
          child: token == null || !showShareUrl
              ? null
              : SelectableText(
                  changeOrderShareUrl(token),
                  style: AppTypography.helper.copyWith(color: AppColors.textPrimary),
                  maxLines: 2,
                ),
        );
      case ProjectChangeOrder.statusApproved:
        return ContractCoStatusNote(
          icon: Icons.check_circle_outline,
          color: AppColors.success,
          title: 'Müşteri onayladı',
          lines: [
            if (co.approvedAt != null) 'Onay: ${formatDateTimeTr(co.approvedAt)}',
            ..._recordedLines(co),
            'Onaylanan ek iş kesindir; etkisini geri almak için yeni bir eksiltme oluşturulur.',
          ],
        );
      case ProjectChangeOrder.statusRejected:
        return ContractCoStatusNote(
          icon: Icons.highlight_off,
          color: AppColors.danger,
          title: 'Müşteri reddetti',
          lines: [
            if (co.rejectedAt != null) 'Red: ${formatDateTimeTr(co.rejectedAt)}',
            ..._recordedLines(co),
            'Revize ederek aynı içerikle yeni bir taslak açabilirsin.',
          ],
        );
      case ProjectChangeOrder.statusCancelled:
        return ContractCoStatusNote(
          icon: Icons.block,
          color: AppColors.textMuted,
          title: 'İptal edildi',
          lines: [if (co.cancelledAt != null) 'İptal: ${formatDateTimeTr(co.cancelledAt)}'],
        );
      case ProjectChangeOrder.statusSuperseded:
        return ContractCoStatusNote(
          icon: Icons.history,
          color: AppColors.textMuted,
          title: 'Yerine yeni revizyon oluşturuldu',
          lines: const ['Bu kayıt artık geçerli değil; paylaşım linki iptal edildi.'],
          child: next == null
              ? null
              : Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    onPressed: onOpenNext,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: Text('${next!.changeOrderNo} revizyonunu aç'),
                  ),
                ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.currency});

  final ProjectChangeOrderItem item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final qty = formatQuantity(item.quantity);
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.description, style: AppTypography.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  '$qty ${item.unit} × ${Formatters.money(item.unitPrice, currency: currency)}',
                  style: AppTypography.metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            Formatters.money(item.lineTotal, currency: currency),
            style: AppTypography.body.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.changeOrder});

  final ProjectChangeOrder changeOrder;

  @override
  Widget build(BuildContext context) {
    final co = changeOrder;
    final c = co.currency;
    return AppCard(
      child: Column(
        children: [
          ContractCoValueRow(label: 'Ara Toplam', value: Formatters.money(co.subtotal, currency: c)),
          ContractCoValueRow(
            label: 'KDV (${Formatters.percent(co.vatRate)})',
            value: Formatters.money(co.vatAmount, currency: c),
          ),
          const Divider(height: AppSpacing.lg),
          ContractCoValueRow(label: 'Toplam', value: Formatters.money(co.grandTotal, currency: c), emphasize: true),
        ],
      ),
    );
  }
}

/// Web "Kârlılık (dahili)" -- liste ucundaki sunucu hesabı; müşteri
/// paylaşım sayfası bunu ASLA görmez.
class _ProfitabilityCard extends StatelessWidget {
  const _ProfitabilityCard({required this.profitability, required this.currency});

  final ChangeOrderProfitability profitability;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final p = profitability;
    Color? tone(double v) => v < 0 ? AppColors.danger : (v > 0 ? AppColors.success : null);
    return ContractCoCard(
      title: 'Kârlılık (dahili)',
      trailing: const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
      children: [
        ContractCoValueRow(
          label: 'Gelir Etkisi',
          value: Formatters.signedMoney(p.revenueEffect, currency: currency),
          valueColor: tone(p.revenueEffect),
        ),
        ContractCoValueRow(label: 'Gerçekleşen Maliyet', value: Formatters.money(p.realizedCost, currency: currency)),
        ContractCoValueRow(
          label: 'Gerçekleşen Kâr',
          value: Formatters.signedMoney(p.realizedProfit, currency: currency),
          valueColor: tone(p.realizedProfit),
        ),
        ContractCoValueRow(label: 'Marj', value: Formatters.percent(p.realizedMarginPercent)),
      ],
    );
  }
}

/// "Aktivite / Zaman Çizelgesi" -- proje olaylarından bu ek işe ait
/// olanlar (web teklif ActivityTimeline'ın aynı düzeni: görüntülenme
/// özeti + zaman damgalı satırlar; e-posta satırlarında alıcı). Olaylar
/// okunamazsa (izin/ağ) bölüm sessizce gizlenir.
class _EventsSection extends ConsumerWidget {
  const _EventsSection({required this.projectId, required this.changeOrder});

  final String projectId;
  final ProjectChangeOrder changeOrder;

  String _label(ChangeOrderEvent e) {
    if (e.eventType == 'change_order_superseded' && e.newChangeOrderId == changeOrder.id) {
      return 'Revizyon olarak oluşturuldu';
    }
    if (e.isStaffDecision && e.eventType == 'change_order_approved') return 'Müşteri onayı ekip tarafından kaydedildi';
    if (e.isStaffDecision && e.eventType == 'change_order_rejected') return 'Müşteri reddi ekip tarafından kaydedildi';
    if (e.eventType == 'change_order_superseded') return 'Revize edildi (yeni taslak açıldı)';
    return kProjectEventLabels[e.eventType] ?? kUnknownEventLabel;
  }

  Color? _tone(String type) => switch (type) {
        'change_order_approved' => AppColors.success,
        'change_order_rejected' || 'change_order_email_failed' || 'change_order_cancelled' => AppColors.danger,
        'change_order_viewed' => AppColors.gold,
        _ => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(changeOrderEventsProvider(projectId)).valueOrNull;
    if (events == null) return const SizedBox.shrink();
    final mine = events.where((e) => e.changeOrderIds.contains(changeOrder.id)).toList();
    final views = mine.where((e) => e.isView).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        const AppSectionHeader(title: 'Aktivite / Zaman Çizelgesi'),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (views.isNotEmpty) ...[
                Text(
                  views.length == 1
                      ? '1 görüntülenme · ${formatDateTimeTr(views.first.createdAt)}'
                      : '${views.length} görüntülenme · ilk ${formatDateTimeTr(views.first.createdAt)} · '
                          'son ${formatDateTimeTr(views.last.createdAt)}',
                  style: AppTypography.helper.copyWith(height: 1.35),
                ),
                const Divider(height: AppSpacing.lg),
              ],
              if (mine.isEmpty)
                const Text('Henüz kayıtlı bir olay yok.', style: AppTypography.metadata)
              else
                // Mobildeki tüm zaman çizelgeleri gibi en yeni üstte (proje
                // Aktivite, teklif geçmişi); depo eskiden yeniye sıralar.
                for (final e in mine.reversed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _label(e),
                          style: AppTypography.body.copyWith(fontSize: 13.5, color: _tone(e.eventType)),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          [formatDateTimeTr(e.createdAt), ?e.recipient, ?e.note].join(' · '),
                          style: AppTypography.helper,
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}
