/// Teklif geçmişi tam ekranının mutlak yolu -- rota teklif detayının
/// (`/teklifler/:id`) ALTINA kaydedilir (bkz. offer_history_routes.dart).
/// [emails]: "Mail Geçmişi" sekmesiyle açılır (`?sekme=eposta`).
String offerHistoryPath(String offerId, {bool emails = false}) =>
    '/teklifler/${Uri.encodeComponent(offerId)}/gecmis${emails ? '?sekme=eposta' : ''}';
