-- Kişiye özel ayarlar ve rol satırları izne FK ile bağlı: önce onlar.
DELETE FROM user_permission_overrides WHERE permission_code = 'projects.change_orders.approve';
DELETE FROM role_permissions WHERE permission_code = 'projects.change_orders.approve';
DELETE FROM permissions WHERE code = 'projects.change_orders.approve';

-- Personelin kaydettiği kararlar (approved/rejected durumu, tarihleri,
-- sözleşme bedeline etkisi) OLDUĞU GİBİ kalır; yalnızca kimin işaretlediği
-- ve not bilgisi kaybolur.
ALTER TABLE project_change_orders
    DROP COLUMN IF EXISTS decision_note,
    DROP COLUMN IF EXISTS decision_recorded_by;
