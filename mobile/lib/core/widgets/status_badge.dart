import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

enum StatusTone { gold, success, danger, muted, info }

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, required this.tone});

  final String label;
  final StatusTone tone;

  Color get _color => switch (tone) {
        StatusTone.gold => AppColors.gold,
        StatusTone.success => AppColors.success,
        StatusTone.danger => AppColors.danger,
        StatusTone.info => AppColors.info,
        StatusTone.muted => AppColors.textMuted,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(color: _color, fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// bkz. mobile/API_CONTRACT.md - backend'in gerçek Türkçe enum değerleri.
abstract final class StatusRegistry {
  static const offer = {
    'taslak': ('Taslak', StatusTone.muted),
    'gönderildi': ('Gönderildi', StatusTone.info),
    'kabul edildi': ('Kabul Edildi', StatusTone.success),
    'reddedildi': ('Reddedildi', StatusTone.danger),
  };

  static const project = {
    'planned': ('Planlandı', StatusTone.muted),
    'active': ('Aktif', StatusTone.info),
    'paused': ('Durduruldu', StatusTone.gold),
    'completed': ('Tamamlandı', StatusTone.success),
    'cancelled': ('İptal Edildi', StatusTone.danger),
  };

  static const task = {
    'todo': ('Yapılacak', StatusTone.muted),
    'in_progress': ('Devam Ediyor', StatusTone.info),
    'completed': ('Tamamlandı', StatusTone.success),
    'cancelled': ('İptal Edildi', StatusTone.danger),
  };

  static const taskPriority = {
    'low': ('Düşük', StatusTone.muted),
    'normal': ('Normal', StatusTone.info),
    'high': ('Yüksek', StatusTone.gold),
    'urgent': ('Acil', StatusTone.danger),
  };

  static const changeOrder = {
    'draft': ('Taslak', StatusTone.muted),
    'sent': ('Gönderildi', StatusTone.info),
    'approved': ('Onaylandı', StatusTone.success),
    'rejected': ('Reddedildi', StatusTone.danger),
    'cancelled': ('İptal Edildi', StatusTone.danger),
    'superseded': ('Yenilendi', StatusTone.muted),
  };

  static const purchaseRequest = {
    'draft': ('Taslak', StatusTone.muted),
    'submitted': ('Gönderildi', StatusTone.info),
    'approved': ('Onaylandı', StatusTone.success),
    'rejected': ('Reddedildi', StatusTone.danger),
    'cancelled': ('İptal Edildi', StatusTone.danger),
  };

  static const purchaseOrder = {
    'draft': ('Taslak', StatusTone.muted),
    'approved': ('Onaylandı', StatusTone.gold),
    'cancelled': ('İptal Edildi', StatusTone.danger),
    'closed': ('Kapatıldı', StatusTone.success),
  };

  static const subcontract = {
    'draft': ('Taslak', StatusTone.muted),
    'active': ('Aktif', StatusTone.info),
    'completed': ('Tamamlandı', StatusTone.success),
    'cancelled': ('İptal Edildi', StatusTone.danger),
    'terminated': ('Feshedildi', StatusTone.danger),
  };

  static const progressClaim = {
    'draft': ('Taslak', StatusTone.muted),
    'submitted': ('Gönderildi', StatusTone.info),
    'certified': ('Sertifika Edildi', StatusTone.success),
    'rejected': ('Reddedildi', StatusTone.danger),
    'cancelled': ('İptal Edildi', StatusTone.danger),
  };

  static const attendance = {
    'geldi': ('Geldi', StatusTone.success),
    'yarım gün': ('Yarım Gün', StatusTone.gold),
    'gelmedi': ('Gelmedi', StatusTone.danger),
    'izinli': ('İzinli', StatusTone.info),
  };

  static Widget build(String value, Map<String, (String, StatusTone)> registry) {
    final entry = registry[value];
    if (entry == null) return StatusBadge(label: value, tone: StatusTone.muted);
    return StatusBadge(label: entry.$1, tone: entry.$2);
  }
}
