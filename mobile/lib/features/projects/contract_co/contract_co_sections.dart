import 'package:flutter/material.dart';

import '../domain/project.dart';
import 'contract_co_paths.dart';
import 'presentation/change_orders_view.dart';
import 'presentation/contract_view.dart';

/// Proje detayına eklenecek alt görünümlerin tanımı (entegrasyon adımı
/// için). Kayıt (record) tipi yapısaldır -- diğer proje gruplarının aynı
/// alanlı tanımlarıyla tek listede birleşebilir.
///
/// - `group`: `?grup=` değeri (`finans`), `alt`: `?alt=` değeri.
/// - `label`: SegmentedButton etiketi (web ile aynı sözcük).
/// - `permission`: görünürlük izni -- proje detayındaki `_failOpen` /
///   `UserCan.can` (fail-open) ile süzülür; asıl sınır backend `projPerm`.
///   `anyOfPermissions`: bunlardan HERHANGİ biri yeter (burada tek izin).
/// - `replaces`: proje detayında yerini aldığı eski özel widget (yoksa '').
/// - `route`: aynı içeriğin tam ekran yolu (Özet kartı / ana sayfa derin
///   bağlantısı için), `builder`: gruba gömülecek gövde (kendi
///   RefreshIndicator + kaydırılabilir listesiyle; `Expanded` içine konur).
///   Alan adları/tipleri `budgetSections` kaydıyla aynıdır -- iki liste
///   tek listede birleştirilebilir.
///
/// Sıra web ile aynı: Sözleşme, Ek İşler'in ÜSTÜNDE (docs/contracts.md §11
/// -- sözleşme, kendisini değiştiren ek işlerden önce okunur).
///
/// ÖNEMLİ: Sözleşme `projects.contracts.read` ile görünür, Finans
/// grubunun `projects.finance.read` kapısına BAĞLI DEĞİLDİR -- finans izni
/// olmayan ama sözleşme izni olan Proje Yöneticisi de görebilmeli (web'de
/// canlı doğrulamada bulunmuş hata, docs/contracts.md §11). Grup görünürlüğü
/// bu yüzden `contracts.read`'i de kapsamalı.
typedef ContractCoSectionEntry = ({
  String group,
  String alt,
  String label,
  String permission,
  List<String> anyOfPermissions,
  IconData icon,
  String replaces,
  String Function(String projectId) route,
  Widget Function(String projectId, Project project) builder,
});

final List<ContractCoSectionEntry> contractCoSections = [
  (
    group: 'finans',
    alt: 'sozlesme',
    label: 'Sözleşme',
    permission: kContractsReadPermission,
    anyOfPermissions: const [kContractsReadPermission],
    icon: Icons.handshake_outlined,
    replaces: '',
    route: projectContractPath,
    builder: (projectId, project) => ProjectContractTab(projectId: projectId),
  ),
  (
    group: 'finans',
    alt: 'ek-isler',
    label: 'Ek İşler',
    permission: kChangeOrdersReadPermission,
    anyOfPermissions: const [kChangeOrdersReadPermission],
    icon: Icons.post_add_outlined,
    // Eski salt-okunur liste (project_detail_screen.dart); bu tam akışla
    // değiştirilmeli.
    replaces: '_ChangeOrdersTab',
    route: projectChangeOrdersPath,
    builder: (projectId, project) => ProjectChangeOrdersTab(projectId: projectId),
  ),
];
