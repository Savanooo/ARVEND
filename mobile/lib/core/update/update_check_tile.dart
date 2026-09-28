import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';
import '../widgets/app_list_card.dart';
import 'update_controller.dart';
import 'update_presenter.dart';

/// "Güncellemeleri denetle" satırı (Hakkında ekranı). Yalnızca Android'de
/// görünür; denetim sürerken satır kilitlenir ve dönen gösterge çıkar.
/// Sonuç: güncelse bilgi mesajı, yeni sürüm varsa doğrudan istem.
class UpdateCheckTile extends ConsumerStatefulWidget {
  const UpdateCheckTile({super.key});

  @override
  ConsumerState<UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends ConsumerState<UpdateCheckTile> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    void unlock() {
      if (mounted && _checking) setState(() => _checking = false);
    }

    try {
      // İstem açılırsa satırın dönen göstergesi arkada kalmasın diye
      // sunucu cevap verir vermez kilit açılır; istemin kendisi presenter'da.
      await UpdatePresenter.of(context).checkManually(onChecked: unlock);
    } finally {
      unlock();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(updateSupportedProvider)) return const SizedBox.shrink();
    return AppListCard(
      title: 'Güncellemeleri denetle',
      subtitle: 'Sunucudaki en son sürümü kontrol et',
      leading: const Icon(Icons.system_update_outlined, color: AppColors.gold),
      trailing: _checking
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2))
          : const Icon(Icons.chevron_right, color: AppColors.textMuted),
      onTap: _checking ? null : _check,
    );
  }
}
