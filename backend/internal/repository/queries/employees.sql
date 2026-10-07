-- name: CreateEmployee :one
INSERT INTO employees (organization_id, full_name, phone, position, salary, daily_wage, start_date, description, user_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING *;

-- name: GetEmployeeByID :one
SELECT * FROM employees WHERE id = $1 AND organization_id = $2;

-- name: ListEmployees :many
SELECT * FROM employees
WHERE organization_id = $1
  AND (sqlc.narg('is_active')::boolean IS NULL OR is_active = sqlc.narg('is_active')::boolean)
ORDER BY full_name ASC;

-- name: GetEmployeeForUpdate :one
-- Ücret değişikliğini (eski -> yeni) aynı transaction içinde güvenle
-- karşılaştırmak için satırı kilitler (bkz. EmployeeService.Update).
SELECT * FROM employees WHERE id = $1 AND organization_id = $2 FOR UPDATE;

-- name: UpdateEmployee :one
-- archived_at, is_active ile TUTARLI tutulur: "Pasifleştir" (ArchiveEmployee)
-- archived_at'i dolduruyordu ama formdan yeniden "Aktif" yapılan personelde
-- temizlenmiyor, "Aktif" işareti kaldırılınca da hiç dolmuyordu -- ana sayfa
-- archived_at'e baktığı için aktif bir personel orada arşivli görünüyordu.
-- Pasife alınırken mevcut arşiv zamanı korunur (ilk pasifleştirme anı).
UPDATE employees
SET full_name = $3, phone = $4, position = $5, salary = $6, daily_wage = $7,
    start_date = $8, description = $9, is_active = $10, user_id = $11,
    archived_at = CASE WHEN $10::boolean THEN NULL ELSE COALESCE(archived_at, now()) END
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: ArchiveEmployee :execrows
UPDATE employees SET is_active = false, archived_at = now() WHERE id = $1 AND organization_id = $2;

-- name: GetEmployeeByUserID :one
-- GET /tasks/mine'ın "bana ATANAN görevler" çözümlemesinin TEK kaynağı --
-- giriş yapan kullanıcının bağlı olduğu personel kaydını (varsa) bulur.
-- Bağlantısız bir kullanıcı için 0 satır döner (pgx.ErrNoRows) -- çağıran
-- bunu "hiç göreve atanmamış" olarak ele alır (boş liste, ASLA tüm
-- projelerin görevlerine düşmez).
SELECT * FROM employees WHERE user_id = $1 AND organization_id = $2;

-- ---------- Kişi = tek kayıt (giriş hesabı <-> personel) ----------
-- Ürün kararı (2026-10): "kullanıcı oluşturunca direkt personel de
-- oluştururuz". Giriş hesabı (users) ve personel (employees) aynı kişinin
-- iki ayrı kaydıydı; bağ yalnızca biri employees.user_id'yi elle
-- doldurursa kuruluyordu. Sahada "batu" hesabı ile "Batuhan İnci" personeli
-- bağlanmadığı için görev seçicisinde iki ayrı kişi göründü ve personele
-- atanan görevin bildirimi kimseye gitmedi. Bkz. service/user_employee_link.go.

-- name: ListUnlinkedActiveEmployees :many
-- Yeni giriş hesabı açılırken "aynı adlı bağlantısız personel var mı"
-- aramasının adayları. Ad karşılaştırması Go'da yapılır
-- (domain.NormalizePersonName): Türkçe İ/I katlaması SQL lower()'ın
-- veritabanı yereline bağlı davranışına bırakılmaz. Başka bir hesaba
-- (silinmiş olsa bile) bağlı personel ASLA aday değildir.
SELECT id, full_name, position FROM employees
WHERE organization_id = $1 AND is_active = true AND user_id IS NULL
ORDER BY full_name, id;

-- name: LinkEmployeeToUser :one
-- Personeli bir giriş hesabına bağlar -- YALNIZCA hâlâ bağlantısızsa.
-- "user_id IS NULL" koşulu yarış güvencesidir: aynı anda iki hesap aynı
-- personele bağlanmaya çalışırsa ikincisi satır kilidini bekler, koşulu
-- yeniden değerlendirir ve 0 satır alır (başkasının kaydı ezilmez).
UPDATE employees SET user_id = sqlc.arg(user_id)::uuid
WHERE id = sqlc.arg(id)::uuid AND organization_id = sqlc.arg(organization_id)::uuid AND user_id IS NULL
RETURNING *;

-- name: UpdateEmployeeFullName :exec
-- Kullanıcının adı değişince bağlı personelin adını eşitler (yalnızca
-- ikisi önceden aynı addaysa -- karar Go'da, bkz. UserService.Update).
UPDATE employees SET full_name = $3 WHERE id = $1 AND organization_id = $2;

-- name: DeleteUntouchedAutoEmployee :execrows
-- Hesapla birlikte OTOMATİK açılmış ve hiç kullanılmamış personel kaydını
-- siler: yönetici aynı hesabı açıkça BAŞKA bir personele bağlarken
-- (ör. otomatik açılan "batu" kaydı yerine "Batuhan İnci"ye) sistemin
-- kendi açtığı boş kayıt yönetici kararına yol verir.
--
-- "Otomatik açılmış" işareti created_at eşitliğidir: hesap ve personel tek
-- transaction'da yazılır, ikisinin de created_at'i aynı now() değeridir;
-- elle açılıp sonradan bağlanan bir personelde bu eşitlik oluşmaz.
-- "Hiç kullanılmamış": sonradan hiç düzenlenmemiş (updated_at), ücret
-- tanımlanmamış ve hiçbir geçmiş kayda (mesai, ödeme, ekip, görev, plan)
-- konu olmamış. Bunlardan biri bile varsa SİLİNMEZ (0 satır) ve çağıran
-- eski kuralı uygular: hesap zaten bir personele bağlı -> ret.
DELETE FROM employees e
USING users u
WHERE e.id = sqlc.arg(id)::uuid
  AND e.organization_id = sqlc.arg(organization_id)::uuid
  AND u.id = e.user_id
  AND e.created_at = u.created_at
  AND e.updated_at = e.created_at
  AND e.salary IS NULL AND e.daily_wage IS NULL
  AND NOT EXISTS (SELECT 1 FROM employee_wage_history w
                  WHERE w.employee_id = e.id AND (w.salary IS NOT NULL OR w.daily_wage IS NOT NULL))
  AND NOT EXISTS (SELECT 1 FROM attendance_logs a WHERE a.employee_id = e.id)
  AND NOT EXISTS (SELECT 1 FROM salary_payments sp WHERE sp.employee_id = e.id)
  AND NOT EXISTS (SELECT 1 FROM project_members pm WHERE pm.employee_id = e.id)
  AND NOT EXISTS (SELECT 1 FROM project_tasks t WHERE t.assigned_employee_id = e.id)
  AND NOT EXISTS (SELECT 1 FROM project_schedule_items si WHERE si.assigned_employee_id = e.id);

-- name: ListEmployeeLogins :many
-- Personel listesinde/detayında bağlı giriş hesabını göstermek için
-- (kullanıcı adı + durum). Firma başına tek sorgu; yalnızca bağlı
-- personel döner.
SELECT e.id AS employee_id, u.username, u.is_active,
       (u.deleted_at IS NOT NULL)::boolean AS deleted
FROM employees e
JOIN users u ON u.id = e.user_id
WHERE e.organization_id = $1;

-- name: ListUsersWithoutEmployee :many
-- "Bağlantı önerileri": personel kaydı olmayan (silinmemiş) giriş
-- hesapları. Eşleştirme Go'da, yalnızca birebir aynı normalize adla.
SELECT u.id, u.username, u.full_name FROM users u
WHERE u.organization_id = $1 AND u.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.user_id = u.id)
ORDER BY u.full_name, u.id;
