import '../../../../core/widgets/status_badge.dart';

/// Proje Sözleşmesi (Contract) -- projenin GELİR tarafı; Bütçe/Maliyet
/// Kontrolü (maliyet tarafı) İLE KARIŞTIRILMAMALI. backend
/// `contractResponse` (project_contract_handler.go) ile birebir.
///
/// Durum makinesi (docs/contracts.md §3, domain/project_contract.go):
///
///     draft -> active -> completed   (normal tamamlanma)
///     draft -> cancelled             (yalnızca taslaktan, gerekçe zorunlu)
///     active -> terminated           (yalnızca aktiften, gerekçe zorunlu)
///
/// completed/cancelled/terminated ÜÇÜ DE terminaldir. Aşağıdaki `can*`
/// getter'ları yalnızca UX içindir -- her geçişi backend ayrıca reddeder
/// (409), ekran bu durumda sunucunun mesajını gösterip veriyi tazeler.
class ProjectContract {
  const ProjectContract({
    required this.id,
    required this.currency,
    required this.status,
    this.scope = '',
    this.paymentTerms = '',
    this.retentionTerms = '',
    this.advanceTerms = '',
    this.effectiveDate,
    this.plannedCompletionDate,
    this.internalNotes = '',
    this.createdAt = '',
    this.updatedAt = '',
    this.activatedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancelReason = '',
    this.terminatedAt,
    this.terminationReason = '',
  });

  static const statusDraft = 'draft';
  static const statusActive = 'active';
  static const statusCompleted = 'completed';
  static const statusCancelled = 'cancelled';
  static const statusTerminated = 'terminated';

  final String id;
  final String currency;
  final String status;

  /// "Ticari temel" (baseline) alanları -- aktivasyonla KİLİTLENİR.
  final String scope;
  final String paymentTerms;
  final String retentionTerms;
  final String advanceTerms;

  /// "YYYY-MM-DD" (backend `dateStrPtr`).
  final String? effectiveDate;
  final String? plannedCompletionDate;

  /// Ticari OLMAYAN dahili not -- taslak VE aktifte düzenlenebilir.
  final String internalNotes;

  final String createdAt;
  final String updatedAt;
  final String? activatedAt;
  final String? completedAt;
  final String? cancelledAt;
  final String cancelReason;
  final String? terminatedAt;
  final String terminationReason;

  factory ProjectContract.fromJson(Map<String, dynamic> json) => ProjectContract(
        id: json['id'] as String,
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String? ?? statusDraft,
        scope: json['scope'] as String? ?? '',
        paymentTerms: json['payment_terms'] as String? ?? '',
        retentionTerms: json['retention_terms'] as String? ?? '',
        advanceTerms: json['advance_terms'] as String? ?? '',
        effectiveDate: _nonEmpty(json['effective_date']),
        plannedCompletionDate: _nonEmpty(json['planned_completion_date']),
        internalNotes: json['internal_notes'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
        activatedAt: _nonEmpty(json['activated_at']),
        completedAt: _nonEmpty(json['completed_at']),
        cancelledAt: _nonEmpty(json['cancelled_at']),
        cancelReason: json['cancel_reason'] as String? ?? '',
        terminatedAt: _nonEmpty(json['terminated_at']),
        terminationReason: json['termination_reason'] as String? ?? '',
      );

  bool get isDraft => status == statusDraft;
  bool get isActive => status == statusActive;
  bool get isTerminal => !isDraft && !isActive;

  /// Kapsam/koşullar/tarihler yalnızca taslakta düzenlenir
  /// (ErrContractNotEditable).
  bool get termsEditable => isDraft;

  /// Dahili not taslak VE aktifte düzenlenir (ErrContractNotesNotEditable).
  bool get notesEditable => isDraft || isActive;

  bool get canActivate => isDraft;
  bool get canCancel => isDraft;
  bool get canComplete => isActive;
  bool get canTerminate => isActive;

  /// Web ContractSection'daki durum açıklamasıyla aynı metin.
  String get statusExplanation => switch (status) {
        statusDraft => 'Taslak — şartlar serbestçe düzenlenebilir.',
        statusActive => 'Aktif — ticari şartlar kilitli, değişiklikler Ek İş ile yapılır.',
        statusCompleted => 'Tamamlandı.',
        statusCancelled => cancelReason.isEmpty ? 'İptal edildi.' : 'İptal edildi — $cancelReason.',
        statusTerminated => terminationReason.isEmpty ? 'Feshedildi.' : 'Feshedildi — $terminationReason.',
        _ => status,
      };

  static String? _nonEmpty(Object? v) {
    final s = v as String?;
    return (s == null || s.isEmpty) ? null : s;
  }
}

/// `PUT /projects/{id}/contract` gövdesi -- YALNIZCA ticari temel alanları
/// (dahili not ayrı uçtadır, farklı kilit kuralı taşır). Tarih boşsa
/// `null` gönderilir (web ile aynı: `effective_date || null`).
class ContractDraftInput {
  const ContractDraftInput({
    required this.scope,
    required this.paymentTerms,
    required this.retentionTerms,
    required this.advanceTerms,
    this.effectiveDate,
    this.plannedCompletionDate,
  });

  final String scope;
  final String paymentTerms;
  final String retentionTerms;
  final String advanceTerms;
  final String? effectiveDate;
  final String? plannedCompletionDate;

  Map<String, dynamic> toJson() => {
        'scope': scope,
        'payment_terms': paymentTerms,
        'retention_terms': retentionTerms,
        'advance_terms': advanceTerms,
        'effective_date': (effectiveDate == null || effectiveDate!.isEmpty) ? null : effectiveDate,
        'planned_completion_date':
            (plannedCompletionDate == null || plannedCompletionDate!.isEmpty) ? null : plannedCompletionDate,
      };
}

/// Sözleşme durum rozetleri -- web `CONTRACT_STATUS` ile aynı etiket/ton
/// (aktif = gold marka vurgusu: yürürlükteki ticari taban).
const kContractStatusRegistry = <String, (String, StatusTone)>{
  ProjectContract.statusDraft: ('Taslak', StatusTone.muted),
  // Mobil kuralı (StatusTone): gold marka vurgusudur, durum değil -- proje,
  // taşeron ve taahhüt "Aktif"iyle aynı info tonu.
  ProjectContract.statusActive: ('Aktif', StatusTone.info),
  ProjectContract.statusCompleted: ('Tamamlandı', StatusTone.success),
  ProjectContract.statusCancelled: ('İptal Edildi', StatusTone.danger),
  ProjectContract.statusTerminated: ('Feshedildi', StatusTone.danger),
};
