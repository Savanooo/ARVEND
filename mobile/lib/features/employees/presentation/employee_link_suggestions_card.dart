import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_card.dart';
import '../../access/data/access_providers.dart';
import '../../access/presentation/widgets/access_state_views.dart';
import '../data/employees_providers.dart';
import '../domain/employee_record.dart';

/// Personel listesinin üstünde: personel kaydı olmayan giriş hesapları ile
/// BİREBİR aynı adı taşıyan bağlantısız personel ("kişi = tek kayıt" öncesi
/// açılmış kayıtlar). Sunucu hiçbirini kendiliğinden bağlamaz -- "batu" ile
/// "Batuhan İnci" gibi farklı yazılmış adlar burada çıkmaz, onlar personel
/// formundan elle bağlanır. Öneri yoksa (ya da alınamazsa) ekran bu kartı
/// hiç çizmez: liste ekranının asıl işini bölmez.
class EmployeeLinkSuggestionsCard extends ConsumerStatefulWidget {
  const EmployeeLinkSuggestionsCard({super.key, required this.suggestions});

  final List<EmployeeLinkSuggestion> suggestions;

  @override
  ConsumerState<EmployeeLinkSuggestionsCard> createState() => _EmployeeLinkSuggestionsCardState();
}

class _EmployeeLinkSuggestionsCardState extends ConsumerState<EmployeeLinkSuggestionsCard> {
  String? _linkingId;

  Future<void> _link(EmployeeLinkSuggestion s) async {
    setState(() => _linkingId = s.employeeId);
    final container = ProviderScope.containerOf(context, listen: false);
    final repo = container.read(employeesRepositoryProvider);
    try {
      // PUT tam-güncellemedir: kayıt taze okunur (ücretler dolu, bu kart
      // yalnızca "Personeli düzenleme" ile görünür) ve yalnızca bağ
      // değişerek geri yazılır.
      final fresh = await repo.get(s.employeeId);
      await repo.update(fresh.id, EmployeeInput.fromRecord(fresh, userId: s.userId));
      invalidateEmployeesWith(container.invalidate, id: fresh.id);
      container.invalidate(orgUsersProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${s.employeeFullName} personeli ${s.username} hesabına bağlandı.')));
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _linkingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = widget.suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Bağlanmamış hesaplar (${suggestions.length})', style: AppTypography.cardTitle),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Bu giriş hesaplarıyla aynı adı taşıyan personel kayıtları var. Bağlarsan kişi tek kayıt olur: '
            'göreve atandığında bildirim alır.',
            style: AppTypography.helper,
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final s in suggestions)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Row(
                children: [
                  InitialsAvatar(name: s.employeeFullName, size: 32),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [s.employeeFullName, if (s.employeePosition.isNotEmpty) s.employeePosition].join(' · '),
                          style: AppTypography.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            const Icon(Icons.key_outlined, size: 12, color: AppColors.textMuted),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                s.username,
                                style: AppTypography.metadata,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _linkingId == null ? () => _link(s) : null,
                    child: _linkingId == s.employeeId
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Bağla'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
