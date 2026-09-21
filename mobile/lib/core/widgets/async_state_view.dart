import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/api_exception.dart';
import '../theme/app_colors.dart';

/// Her network ekranının ortak loading/empty/error/data iskeleti. `onRetry`
/// verildiğinde hata durumunda bir "Tekrar Dene" butonu gösterilir.
class AsyncStateView<T> extends StatelessWidget {
  const AsyncStateView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
    this.isEmpty,
    this.emptyBuilder,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) data;
  final Future<void> Function()? onRetry;
  final bool Function(T data)? isEmpty;
  final Widget Function(BuildContext context)? emptyBuilder;

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: (d) {
        if (isEmpty != null && isEmpty!(d)) {
          return emptyBuilder?.call(context) ?? const EmptyStateView();
        }
        return data(context, d);
      },
      loading: () => const LoadingState(),
      error: (err, st) => ErrorState(error: err, onRetry: onRetry),
    );
  }
}

/// Tam-ekran/tam-bölüm yükleniyor göstergesi -- `AsyncStateView` bunu
/// otomatik kullanır; bağımsız bir yükleniyor durumu gerektiğinde
/// (ör. yeni bir bileşim) doğrudan da kullanılabilir.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.gold),
      ),
    );
  }
}

/// Tam-ekran/tam-bölüm hata durumu -- ham backend hata metni yerine
/// güvenli bir mesaj + isteğe bağlı "Tekrar Dene" gösterir.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.onRetry});

  final Object error;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final err = error; // yerel değişken: promotable (field promotion yalnız private final alanlarda çalışır)
    final message = err is ApiException ? err.message : 'Beklenmeyen bir hata oluştu.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyStateView extends StatelessWidget {
  const EmptyStateView({super.key, this.message = 'Kayıt bulunamadı.', this.icon = Icons.inbox_outlined});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.textMuted, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }
}
