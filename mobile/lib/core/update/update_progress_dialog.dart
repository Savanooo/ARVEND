import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_status_colors.dart';
import '../theme/app_typography.dart';
import '../utils/formatters.dart';
import '../widgets/app_buttons.dart';
import 'apk_installer.dart';
import 'app_release.dart';
import 'update_controller.dart' show UpdateCheckResult, UpdateCheckStatus;
import 'update_prompt_dialog.dart';
import 'update_service.dart';

/// İndirme diyaloğunun nasıl kapandığı.
enum UpdateFlowResult {
  /// Android'in kurulum ekranı açıldı.
  installerOpened,

  /// Kullanıcı iptal etti / vazgeçti.
  cancelled,

  /// İndirme 401 aldı -- önce giriş yapılmalı.
  loginRequired,

  /// Sürüm bilgisi yeniden sorulunca sunucuda artık daha yeni bir sürüm
  /// olmadığı görüldü (yayın geri çekildi) -- indirilecek bir şey yok.
  noUpdate,
}

enum _Phase { downloading, refreshing, verifying, opening, failed, needsPermission }

/// İndir -> doğrula -> kurulum ekranını aç akışının tamamını yürüten
/// diyalog. Açılır açılmaz indirmeye başlar; geri tuşu işlemez (yalnızca
/// "İptal"). Diyalog herhangi bir yolla kapanırsa indirme iptal edilir ve
/// yarım dosya silinir.
///
/// İndirme ucu her zaman sunucudaki GÜNCEL APK'yı verir; istem açıkken
/// yeni bir sürüm yayınlandıysa elimizdeki kayıt (özet/boyut) eskimiştir.
/// Bu yüzden sunucu başka bir dosya sunuyorsa ya da inen dosya kayıtla
/// tutmazsa [recheck] ile sürüm bilgisi yeniden sorulur ve kayıt
/// değiştiyse güncel sürümle kendiliğinden baştan indirilir. Kayıt aynıysa
/// (dosya gerçekten tutmadı) hata gösterilir -- doğrulanmamış bir dosya
/// her durumda kurulum ekranına VERİLMEZ.
class UpdateProgressDialog extends StatefulWidget {
  const UpdateProgressDialog({super.key, required this.release, required this.service, this.recheck});

  final AppRelease release;
  final UpdateInstallService service;

  /// Sunucuya sürüm bilgisini yeniden sorar (hata fırlatmaz). Verilmezse
  /// kayıt tazelenmez.
  final Future<UpdateCheckResult> Function()? recheck;

  @override
  State<UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<UpdateProgressDialog> {
  /// Bir "Güncelle"/"Tekrar Dene" başına en fazla bu kadar kendiliğinden
  /// yeni sürüme geçilir -- sunucu sürekli değişiyorsa döngüye girilmez.
  static const _maxAutoRestarts = 2;

  /// İndirilen/indirilecek sürüm -- kayıt eskiyse güncel olanla değişir.
  late AppRelease _release = widget.release;
  _Phase _phase = _Phase.downloading;
  int _received = 0;
  int _total = 0;
  String? _error;
  CancelToken? _cancelToken;

  /// Doğrulanmış APK -- varsa "Tekrar Dene" yeniden indirmez, yalnızca
  /// kurulum ekranını tekrar açmayı dener.
  File? _apk;
  bool _closed = false;
  bool _started = false;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // Kullanıcı kurulum iznini Ayarlar'dan açıp geri döndüğünde "Tekrar
    // Dene"ye basmasına gerek kalmadan yeniden denenir.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_phase == _Phase.needsPermission && _apk != null) _install();
    });
    _start();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _cancelToken?.cancel();
    super.dispose();
  }

  void _close(UpdateFlowResult result) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(result);
  }

  Future<void> _start() async {
    if (_apk != null) return _install();

    var restarts = 0;
    while (true) {
      final failure = await _downloadOnce();
      if (failure == null || !mounted || _closed) return;
      if (failure.kind == UpdateFailureKind.loginRequired) return _close(UpdateFlowResult.loginRequired);

      // Kayıt eskimiş olabilir (istem açıkken yeni sürüm yayınlandı):
      // sunucuya yeniden sorulur, değiştiyse güncel sürümle baştan başlanır.
      final maybeStale = failure.kind == UpdateFailureKind.releaseChanged ||
          failure.kind == UpdateFailureKind.checksumMismatch;
      if (maybeStale && restarts < _maxAutoRestarts) {
        switch (await _refreshRelease()) {
          case _Refresh.changed:
            restarts++;
            continue;
          case _Refresh.noUpdate:
            return _close(UpdateFlowResult.noUpdate);
          case _Refresh.closed:
            return;
          case _Refresh.unchanged:
          case _Refresh.failed:
            break;
        }
      }
      setState(() {
        _phase = _Phase.failed;
        _error = failure.message;
      });
      return;
    }
  }

  /// Tek bir indir + doğrula denemesi. Başarılıysa kurulum ekranını açar ve
  /// null döner; iptalde de null döner ("İptal" diyaloğu zaten kapattı).
  Future<UpdateFailure?> _downloadOnce() async {
    final token = CancelToken();
    _cancelToken = token;
    // İlk çağrı initState'ten gelir (henüz build yok); sonrakilerde ekran
    // indirme durumuna geri döner.
    void reset() {
      _phase = _Phase.downloading;
      _received = 0;
      _total = _release.size;
      _error = null;
    }

    if (_started) {
      setState(reset);
    } else {
      reset();
      _started = true;
    }
    try {
      final file = await widget.service.prepare(
        _release,
        cancelToken: token,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
        onVerifying: () {
          if (mounted) setState(() => _phase = _Phase.verifying);
        },
      );
      if (!mounted) return null;
      _apk = file;
      await _install();
      return null;
    } on UpdateCancelled {
      return null;
    } on UpdateFailure catch (f) {
      return f;
    } catch (e) {
      debugPrint('Güncelleme indirilemedi: $e');
      return const UpdateFailure(UpdateFailureKind.network);
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
    }
  }

  /// Sürüm bilgisini sunucuya yeniden sorar; değiştiyse [_release]'i
  /// günceller.
  Future<_Refresh> _refreshRelease() async {
    final recheck = widget.recheck;
    if (recheck == null) return _Refresh.failed;
    setState(() => _phase = _Phase.refreshing);
    UpdateCheckResult result;
    try {
      result = await recheck();
    } catch (e) {
      debugPrint('Güncelleme: sürüm bilgisi yenilenemedi: $e');
      result = const UpdateCheckResult(UpdateCheckStatus.failed);
    }
    if (!mounted || _closed) return _Refresh.closed;
    switch (result.status) {
      case UpdateCheckStatus.upToDate:
        return _Refresh.noUpdate;
      case UpdateCheckStatus.available:
        final next = result.release!;
        if (next.build == _release.build && next.sha256 == _release.sha256) return _Refresh.unchanged;
        _release = next;
        return _Refresh.changed;
      case UpdateCheckStatus.failed:
      case UpdateCheckStatus.unsupported:
        return _Refresh.failed;
    }
  }

  Future<void> _install() async {
    final apk = _apk;
    if (apk == null || _phase == _Phase.opening) return;
    setState(() => _phase = _Phase.opening);
    final result = await widget.service.install(apk);
    if (!mounted) return;
    switch (result) {
      case ApkInstallResult.opened:
        _close(UpdateFlowResult.installerOpened);
      case ApkInstallResult.permissionRequired:
        setState(() => _phase = _Phase.needsPermission);
      case ApkInstallResult.failed:
        setState(() {
          _phase = _Phase.failed;
          _error = 'Kurulum ekranı açılamadı. Tekrar dene; sorun sürerse telefonu yeniden başlatıp yeniden dene.';
        });
    }
  }

  void _cancel() {
    _cancelToken?.cancel();
    _close(UpdateFlowResult.cancelled);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: switch (_phase) {
        _Phase.downloading => _buildProgress(
            title: 'Güncelleme indiriliyor',
            helper: 'Uygulamayı açık tut. İndirme bitince dosya doğrulanıp kurulum ekranı açılacak.',
            determinate: true,
          ),
        _Phase.refreshing => _buildProgress(
            title: 'Sürüm bilgisi yenileniyor',
            helper: 'Sunucudaki güncel sürüm bilgisi yeniden alınıyor.',
          ),
        _Phase.verifying => _buildProgress(
            title: 'Dosya doğrulanıyor',
            helper: 'İndirilen dosyanın sunucudaki kayıtla birebir aynı olduğu kontrol ediliyor.',
          ),
        _Phase.opening => _buildProgress(
            title: 'Kurulum ekranı açılıyor',
            helper: 'Android\'in kurulum ekranında "Güncelle"ye dokunman yeterli.',
          ),
        _Phase.failed => _buildFailed(),
        _Phase.needsPermission => _buildNeedsPermission(),
      },
    );
  }

  Widget _buildProgress({required String title, required String helper, bool determinate = false}) {
    final total = _total > 0 ? _total : _release.size;
    final fraction = determinate && total > 0 ? (_received / total).clamp(0.0, 1.0) : null;
    const tabular = [FontFeature.tabularFigures()];
    return UpdateDialogFrame(
      icon: Icons.downloading_rounded,
      title: title,
      subtitle: 'Sürüm ${_release.displayVersion}',
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.badge),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            color: AppColors.gold,
            backgroundColor: AppColors.border,
            semanticsLabel: title,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Text(
              fraction == null ? '' : '%${(fraction * 100).floor()}',
              style: AppTypography.cardTitle.copyWith(fontFeatures: tabular),
            ),
            const Spacer(),
            if (determinate && total > 0)
              Text(
                '${Formatters.decimal(_received / 1000000)} / ${formatUpdateSize(total)}',
                style: AppTypography.metadata.copyWith(fontFeatures: tabular),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(helper, style: AppTypography.helper),
        const SizedBox(height: AppSpacing.xl),
        SecondaryButton(
          label: 'İptal',
          // Doğrulama/kurulum ekranını açma birkaç saniye sürer ve yarıda
          // kesilemez -- yalnızca indirme (ve sürüm bilgisi yenilenirken)
          // iptal edilebilir.
          onPressed: _phase == _Phase.downloading || _phase == _Phase.refreshing ? _cancel : null,
        ),
      ],
    );
  }

  Widget _buildFailed() {
    return UpdateDialogFrame(
      icon: Icons.error_outline,
      iconColor: AppStatusColors.error,
      iconBackground: AppStatusColors.error.withValues(alpha: 0.1),
      title: 'Güncelleme tamamlanamadı',
      subtitle: 'Sürüm ${_release.displayVersion}',
      children: [
        UpdateNotice(icon: Icons.info_outline, color: AppStatusColors.error, text: _error ?? ''),
        const SizedBox(height: AppSpacing.xl),
        PrimaryButton(label: 'Tekrar Dene', icon: Icons.refresh_rounded, onPressed: _start),
        const SizedBox(height: AppSpacing.sm),
        SecondaryButton(label: 'Kapat', onPressed: () => _close(UpdateFlowResult.cancelled)),
      ],
    );
  }

  Widget _buildNeedsPermission() {
    return UpdateDialogFrame(
      icon: Icons.shield_outlined,
      title: 'Kurulum izni gerekli',
      subtitle: 'Sürüm ${_release.displayVersion} indirildi ve doğrulandı',
      children: [
        const Text(
          'Android, ARVEND\'in güncelleme yüklemesine henüz izin vermiyor. Bir kereye mahsus şu izni açman gerekiyor:',
          style: AppTypography.body,
        ),
        const SizedBox(height: AppSpacing.md),
        const UpdateNotice(
          icon: Icons.settings_outlined,
          color: AppStatusColors.info,
          // Android'in (AOSP Türkçe) ayar sayfasındaki anahtarın BİREBİR
          // adı -- kullanıcı ekranda tam bu yazıyı arar.
          text: 'Ayarlar → Bu kaynaktan izin ver',
        ),
        const SizedBox(height: AppSpacing.md),
        const _Steps(steps: [
          '"Ayarları Aç"a dokun.',
          '"Bu kaynaktan izin ver" seçeneğini aç.',
          'Geri dön ve "Tekrar Dene"ye dokun.',
        ]),
        const SizedBox(height: AppSpacing.xl),
        PrimaryButton(
          label: 'Ayarları Aç',
          icon: Icons.open_in_new_rounded,
          onPressed: () => unawaited(widget.service.openInstallPermissionSettings()),
        ),
        const SizedBox(height: AppSpacing.sm),
        SecondaryButton(label: 'Tekrar Dene', icon: Icons.refresh_rounded, onPressed: _install),
        const SizedBox(height: AppSpacing.xs),
        TextButton(
          onPressed: () => _close(UpdateFlowResult.cancelled),
          style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
          child: const Text('Vazgeç'),
        ),
      ],
    );
  }
}

/// Sürüm bilgisi yeniden sorulunca ne çıktı.
enum _Refresh {
  /// Sunucuda başka (daha yeni) bir sürüm var -- onunla baştan başlanır.
  changed,

  /// Kayıt aynı -- dosya gerçekten tutmadı, hata gösterilir.
  unchanged,

  /// Artık güncelleme yok -- diyalog kapanır.
  noUpdate,

  /// Sorulamadı -- eldeki hata gösterilir.
  failed,

  /// Beklerken diyalog kapatıldı.
  closed,
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: AppColors.navDark, shape: BoxShape.circle),
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(color: AppColors.gold, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(steps[i], style: AppTypography.body.copyWith(fontSize: 13.5))),
              ],
            ),
          ),
      ],
    );
  }
}
