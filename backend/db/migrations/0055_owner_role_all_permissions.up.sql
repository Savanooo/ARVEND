-- Sahip rolünün izin kümesi webden düzenlenebiliyordu (Roller & Yetkiler);
-- Sahip'ten ve Yönetici'den "Firma Yönetimi" kaldırılınca rolleri
-- düzeltebilecek kimse kalmıyordu. Artık rol kilitli ve Sahip etkin olarak
-- TÜM izinlere sahip (GetUserPermissions); bu migration daha önce kısılmış
-- Sahip rollerinin EKRANDA da tam görünmesi için eksik satırları geri ekler.
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT r.id, p.code
FROM organization_roles r
CROSS JOIN permissions p
WHERE r.code = 'owner'
ON CONFLICT DO NOTHING;
