import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';
import '../widgets/app_list_card.dart';
import 'play_update.dart';
import 'update_controller.dart';
import 'update_presenter.dart';

/// "Güncellemeleri denetle" satırı (Hakkında ekranı). Yalnızca Android'de
/// görünür; denetim sürerken satır kilitlenir ve dönen gösterge çıkar.
/// Sideload yapısında sunucuya, Play yapısında Google Play'e sorar.
/// Sonuç: güncelse bilgi mesajı, yeni sürüm varsa doğrudan istem.
class UpdateCheckTile extends ConsumerStatefulWidget {
  const UpdateCheckTile({super.key});

  @override
  ConsumerState<UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends ConsumerState<UpdateCheckTile> {
  bool _checking = false;

  void _unlock() {
    if (mounted && _checking) setState(() => _checking = false);
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      // İstem açılırsa satırın dönen göstergesi arkada kalmasın diye
      // sunucu cevap verir vermez kilit açılır; istemin kendisi presenter'da.
      await UpdatePresenter.of(context).checkManually(onChecked: _unlock);
    } finally {
      _unlock();
    }
  }

  Future<void> _checkPlay() async {
    if (_checking) return;
    setState(() => _checking = true);
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(playUpdateControllerProvider);
    try {
      // Play'in penceresi açılmadan kilit açılır; indirme arka planda sürer.
      final status = await controller.run(manual: true, onChecked: _unlock);
      void show(String text) => messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
      switch (status) {
        case PlayUpdateStatus.upToDate:
          final installed = ref.read(installedVersionProvider).valueOrNull;
          show(installed == null ? kUpdateUpToDateMessage : '$kUpdateUpToDateMessage · ${installed.label}');
        case PlayUpdateStatus.failed:
          show(kPlayUpdateCheckFailedMessage);
        case PlayUpdateStatus.downloading:
          show(kPlayUpdateDownloadingMessage);
        case PlayUpdateStatus.readyToInstall:
          showPlayRestartPrompt(controller);
        case PlayUpdateStatus.unsupported:
        case PlayUpdateStatus.postponed:
        case PlayUpdateStatus.denied:
        case PlayUpdateStatus.started:
          break;
      }
    } finally {
      _unlock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final play = ref.watch(playUpdateSupportedProvider);
    if (!play && !ref.watch(updateSupportedProvider)) return const SizedBox.shrink();
    return AppListCard(
      title: 'Güncellemeleri denetle',
      subtitle: play ? "Google Play'deki en son sürümü kontrol et" : 'Sunucudaki en son sürümü kontrol et',
      leading: const Icon(Icons.system_update_outlined, color: AppColors.gold),
      trailing: _checking
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2))
          : const Icon(Icons.chevron_right, color: AppColors.textMuted),
      onTap: _checking ? null : (play ? _checkPlay : _check),
    );
  }
}
