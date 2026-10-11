import type { Employee, User } from "./types";

/*
 * Kişi = tek kayıt (giriş hesabı + personel). Kurallar:
 * mobile/API_CONTRACT.md "Person = one record"; mobil karşılığı
 * mobile/lib/features/access/presentation/user_form_screen.dart ve
 * mobile/lib/features/employees/domain/person_name.dart (web = mobil).
 */

/**
 * Backend `domain.NormalizePersonName` ile BİREBİR aynı kural: iki ad
 * soyadın "aynı kişi adı" olup olmadığını karşılaştırma anahtarı (gösterim
 * için değil). Türkçe harfler ASCII'ye katlanır (İ/I/ı/i -> i, ş -> s ...),
 * büyük/küçük harf ve fazla boşluk yok sayılır.
 *
 * Neden web'de de var: "Yeni Kullanıcı" formu, sunucunun hesabı hangi
 * personele bağlayacağını kaydetmeden ÖNCE gösterir (aynı adlı bağlantısız
 * personel önceden seçili gelir). Kural sunucuyla ayrışırsa form bir şey,
 * sunucu başka bir şey yapardı.
 */
export function normalizePersonName(s: string): string {
  return s
    .trim()
    .split(/\s+/)
    .filter((w) => w.length > 0)
    .map((word) =>
      Array.from(word)
        // "i + birleşik nokta" (U+0307): bazı klavyelerin "İ" için ürettiği biçim.
        .filter((ch) => ch !== "̇")
        .map(foldTurkish)
        .join("")
    )
    .join(" ");
}

/** İki ad aynı kişi adı mı (boş ad hiçbir adla eşleşmez). */
export function samePersonName(a: string, b: string): boolean {
  const na = normalizePersonName(a);
  return na !== "" && na === normalizePersonName(b);
}

function foldTurkish(ch: string): string {
  switch (ch) {
    case "İ":
    case "I":
    case "ı":
    case "i":
    case "Î":
    case "î":
      return "i";
    case "Ş":
    case "ş":
      return "s";
    case "Ğ":
    case "ğ":
      return "g";
    case "Ü":
    case "ü":
    case "Û":
    case "û":
      return "u";
    case "Ö":
    case "ö":
      return "o";
    case "Ç":
    case "ç":
      return "c";
    case "Â":
    case "â":
      return "a";
  }
  return ch.toLowerCase();
}

/** "Personel kaydı" seçicisinde "yeni kayıt aç" seçeneğinin değeri (diğerleri personel kimlikleri). */
export const NEW_EMPLOYEE_CHOICE = "";

/** `POST /users` gövdesinin personel alanları; olmayan alan gönderilmez = backend varsayılanı. */
export interface PersonnelFields {
  create_employee?: boolean;
  employee_id?: string;
  link_same_name?: boolean;
}

export type PersonnelEmployee = Pick<Employee, "id" | "full_name" | "position">;

export interface PersonnelDecision<E extends PersonnelEmployee = PersonnelEmployee> {
  /** Aynı adlı bağlantısız personel (seçicide başta). */
  matches: E[];
  /** Seçicinin sırası: aynı adlılar, sonra diğerleri ada göre. */
  ordered: E[];
  /** Geçerli seçim: NEW_EMPLOYEE_CHOICE, bir personel kimliği ya da null (aynı adlı birden çok kayıt; seçilmeli). */
  selected: string | null;
  body: PersonnelFields;
}

/**
 * "Yeni Kullanıcı" formunun personel kararı -> `POST /users` alanları.
 * Mobil `_personnelChoice` ile aynı:
 * - Personeli düzenleme izni yoksa alan gönderilmez (backend adımı atlar).
 * - Anahtar kapalıysa `create_employee:false`.
 * - [unlinked] null = liste bilinmiyor (yükleniyor/hata/görme izni yok):
 *   seçim yapılamaz, backend varsayılanı uygulanır (yeni kayıt ya da aynı
 *   adlı TEK kayda bağla).
 * - Dokunulmadıysa ([choice] null): aynı adlı TEK kayıt önceden seçili
 *   (sunucu varsayılanıyla aynı); birden çoksa yönetici seçmeli; yoksa yeni.
 * - "Yeni kayıt" seçilince `link_same_name:false`: liste görüldü ve
 *   yönetici yeni dedi -- sunucu aynı adlıya kendiliğinden bağlamasın
 *   (aynı adı taşıyan başka bir kişi).
 */
export function personnelDecision<E extends PersonnelEmployee>({
  canManage,
  createEmployee,
  unlinked,
  fullName,
  choice,
}: {
  canManage: boolean;
  createEmployee: boolean;
  unlinked: E[] | null;
  fullName: string;
  choice: string | null;
}): PersonnelDecision<E> {
  const none: PersonnelDecision<E> = { matches: [], ordered: [], selected: null, body: {} };
  if (!canManage) return none;
  if (!createEmployee) return { ...none, body: { create_employee: false } };
  if (unlinked === null) return none;

  const matches = unlinked.filter((e) => samePersonName(e.full_name, fullName));
  const ordered = [
    ...matches,
    ...unlinked.filter((e) => !matches.includes(e)).sort((a, b) => a.full_name.localeCompare(b.full_name, "tr")),
  ];
  let selected = choice;
  // Seçilen kayıt artık listede değilse (başkası bağladı) seçim düşer.
  if (selected !== null && selected !== NEW_EMPLOYEE_CHOICE && !unlinked.some((e) => e.id === selected)) {
    selected = null;
  }
  if (selected === null) {
    if (matches.length === 0) selected = NEW_EMPLOYEE_CHOICE;
    else if (matches.length === 1) selected = matches[0].id;
  }

  let body: PersonnelFields = {};
  if (selected === NEW_EMPLOYEE_CHOICE) body = { create_employee: true, link_same_name: false };
  else if (selected !== null) body = { employee_id: selected };
  return { matches, ordered, selected, body };
}

/** Seçicinin altındaki açıklama (mobil ile aynı metinler); seçim yoksa null. */
export function personnelHelper(decision: Pick<PersonnelDecision, "matches" | "selected">): string | null {
  const { matches, selected } = decision;
  if (selected === NEW_EMPLOYEE_CHOICE) {
    return matches.length === 0
      ? "Bugünün tarihiyle, ücretsiz bir personel kaydı açılır; ücreti Personel ekranından girebilirsin."
      : "Aynı adlı personel kaydı var ama yeni kayıt açılacak — yalnızca farklı bir kişiyse seç.";
  }
  if (selected === null) return null;
  return matches.some((e) => e.id === selected)
    ? "Aynı adlı personel kaydı var; hesap ona bağlanır, ikinci kayıt açılmaz."
    : "Hesap seçilen personel kaydına bağlanır.";
}

/** Seçicideki personel satırı: "Bağla: Ad Soyad · Görev". */
export function employeeOptionLabel(e: PersonnelEmployee): string {
  return `Bağla: ${[e.full_name, e.position].filter(Boolean).join(" · ")}`;
}

/**
 * Hesap seçicisinin satırı: hesap BAŞKA bir personel kaydına bağlıysa
 * hangisine bağlı olduğu da yazılır -- seçmek o bağı taşır (sunucu yalnızca
 * hesapla otomatik açılmış, hiç kullanılmamış kaydı kendiliğinden kaldırır;
 * kullanılmış kayıtta 409 ile hangi personel olduğunu söyler).
 */
export function userOptionLabel(
  u: Pick<User, "full_name" | "username" | "employee_id" | "employee_full_name">,
  selfEmployeeId?: string
): string {
  const base = `${u.full_name} (${u.username})`;
  if (!u.employee_id || u.employee_id === selfEmployeeId) return base;
  return `${base} · personel: ${u.employee_full_name || "başka kayıt"}`;
}

/** Hesaba bağlanabilecek personel: aktif ve giriş hesabı olmayan. */
export function unlinkedActiveEmployees<E extends Pick<Employee, "is_active" | "user_id">>(all: E[]): E[] {
  return all.filter((e) => e.is_active && !e.user_id);
}

/** Bağlı hesap var ama giriş yapamıyor (pasif ya da silinmiş) -- yalnızca hesap bilgisi geldiyse bilinir. */
export function employeeLoginDisabled(e: Pick<Employee, "user_id" | "user_is_active" | "user_deleted">): boolean {
  return Boolean(e.user_id) && (e.user_deleted === true || e.user_is_active === false);
}

/**
 * `PUT /employees/{id}` gövdesi: kaydın TAM durumu (kısmi güncelleme
 * değildir) -- yalnızca bağ değişir. Kayıt "Personeli düzenleme" ile TAZE
 * okunmuş olmalı (ücretler dolu gelir ve aynen geri yazılır).
 */
export function employeeUpdateBody(e: Employee, userId: string | null) {
  return {
    full_name: e.full_name,
    phone: e.phone,
    position: e.position,
    daily_wage: e.daily_wage,
    salary: e.salary,
    start_date: e.start_date,
    description: e.description,
    is_active: e.is_active,
    user_id: userId ?? "",
  };
}

/**
 * Personel kaydı olmayan bir hesap için yeni kayıt (`POST /employees`):
 * hesabın adı, bugünün tarihi, ücret yok (maaş listesinde "Ücret tanımsız")
 * -- backend'in hesapla birlikte açtığı kayıtla aynı şekil.
 */
export function employeeForUserBody(u: Pick<User, "id" | "full_name">, today: string) {
  return {
    full_name: u.full_name,
    phone: "",
    position: "",
    daily_wage: null,
    salary: null,
    start_date: today,
    description: "",
    user_id: u.id,
  };
}
