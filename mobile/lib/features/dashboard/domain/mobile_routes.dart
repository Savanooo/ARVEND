import 'dashboard.dart';

/// Nötr `DashRef` -> mobil rota (spec §6.6, D3). Sunucu ASLA yol göndermez;
/// satırlar tam kayıt ekranını açar (talep, RFQ, sipariş, hakediş,
/// değişiklik emri, görev, ürün, kullanıcı). Tanınmayan türler null döner
/// -> satır dokunulamaz (çağıran modül rotasına düşebilir).
///
/// Proje sayfasının alt görünümleri `?grup=ozet|finans|operasyon|dokumanlar`
/// ve `&alt=` ile açılır (spec D4; bkz. ProjectDetailScreen).
String? mobileRouteFor(DashRef ref) {
  final id = Uri.encodeComponent(ref.id);
  final p = ref.projectId == null ? null : Uri.encodeComponent(ref.projectId!);
  final parent = ref.parentId == null ? null : Uri.encodeComponent(ref.parentId!);
  // Proje düzeyindeki türlerde id = proje kimliğidir.
  final projectLevel = p ?? id;

  String? inProject(String Function(String project) build) => p == null ? null : build(p);

  switch (ref.kind) {
    case 'project':
      return '/projeler/$projectLevel';
    case 'project_finance':
      return '/projeler/$projectLevel?grup=finans&alt=finans';
    case 'project_cost':
      return '/projeler/$projectLevel?grup=finans&alt=maliyet';
    case 'project_operations':
      return '/projeler/$projectLevel?grup=operasyon&alt=gorevler';
    case 'offer':
      // Dönüştürme (convert) için mobilde ekran yok -- teklif açılır.
      return '/teklifler/$id';
    case 'task':
      return inProject((p) => '/projeler/$p/gorevler/$id');
    case 'milestone':
      return inProject((p) => '/projeler/$p?grup=operasyon&alt=gorevler');
    case 'purchase_request':
      return inProject((p) => '/projeler/$p/satin-alma/talepler/$id');
    case 'rfq':
      return inProject(
        (p) => ref.action == 'award'
            ? '/projeler/$p/satin-alma/rfqlar/$id/karsilastir'
            : '/projeler/$p/satin-alma/rfqlar/$id',
      );
    case 'purchase_order':
      return inProject((p) => '/projeler/$p/satin-alma/siparisler/$id');
    case 'subcontract':
      return inProject((p) => '/projeler/$p/taseronlar/$id');
    case 'progress_claim':
      return inProject(
        (p) => parent == null
            ? '/projeler/$p?grup=operasyon&alt=taseronlar'
            : '/projeler/$p/taseronlar/$parent/hakedisler/$id',
      );
    case 'subcontract_change_order':
      return inProject(
        (p) => parent == null
            ? '/projeler/$p?grup=operasyon&alt=taseronlar'
            : '/projeler/$p/taseronlar/$parent/degisiklik-emirleri/$id',
      );
    case 'change_order':
      return inProject((p) => '/projeler/$p?grup=finans&alt=ek-isler');
    case 'budget_adjustment':
      return inProject((p) => '/projeler/$p?grup=finans&alt=maliyet');
    case 'contract':
    case 'payment_plan_item':
    case 'invoice':
      return inProject((p) => '/projeler/$p?grup=finans&alt=finans');
    case 'customer':
      return '/diger/musteriler/$id';
    case 'product':
      return '/diger/urunler/$id';
    case 'user':
      return '/diger/kullanicilar/$id';
    case 'price_source':
      // Web /admin/urunler'deki kaynak kartları; mobilde kaynak durumu,
      // senkron ve kâr oranı ayrı "Fiyat Kaynakları" ekranındadır.
      return '/diger/urunler/kaynaklar';
    default:
      // Tanınmayan türler (sürüm farkı) -- dokunulamaz.
      return null;
  }
}
