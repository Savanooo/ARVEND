import type { OrgStatus } from "./types";

/*
 * Firma yaşam döngüsü -- backend'deki domain.OrgStatus.CanTransitionTo
 * tablosunun birebir aynası (gerçek sınır backend'dedir; burası yalnızca
 * hangi düğmelerin gösterileceğini belirler). SİLME YOKTUR: cancelled bir
 * durumdur, firma ve tüm tarihçe korunur; cancelled -> active yeniden
 * aktivasyondur. trial'a geri dönüş yoktur.
 */

const TRANSITIONS: Record<OrgStatus, OrgStatus[]> = {
  trial: ["active", "suspended", "cancelled"],
  active: ["suspended", "cancelled"],
  suspended: ["active", "cancelled"],
  cancelled: ["active"],
};

// buttonVariant, kalıcı KART düğmesinin hiyerarşisidir (Genel sekmesi) --
// yalnızca İptal Et gerçekten "danger" (kırmızı) görünür; Askıya Al bilinçli
// olarak "secondary" (nötr, çerçeveli) kalır ki her ikisi de kırmızı
// gösterilip birbirinden ayrışmasın. Reaktivasyon her zaman "primary"
// (asıl/olumlu eylem). `danger` alanı AYRI bir eksendir: onay diyaloğunun
// KENDİ onay düğmesi için (ikisi de erişimi kapattığı için Askıya Al'ın
// diyaloğu da belirgin kalır) -- bkz. GeneralTab.tsx.
type ButtonVariant = "primary" | "secondary" | "danger";

export interface OrgLifecycleAction {
  target: OrgStatus;
  label: string;
  description: string;
  danger: boolean;
  buttonVariant: ButtonVariant;
}

const ACTION_META: Record<Exclude<OrgStatus, "trial">, Omit<OrgLifecycleAction, "target">> = {
  active: {
    label: "Aktifleştir",
    description: "Firma kullanıcıları yeniden giriş yapabilir; plan ve tüm veriler olduğu gibi devam eder.",
    danger: false,
    buttonVariant: "primary",
  },
  suspended: {
    label: "Askıya Al",
    description:
      "Tüm kullanıcılar (açık oturumlar dahil) anında erişimi kaybeder. Veriler korunur; firma istendiğinde yeniden aktifleştirilebilir.",
    danger: true,
    buttonVariant: "secondary",
  },
  cancelled: {
    label: "İptal Et",
    description:
      "Firma iptal edilir: erişim kapanır, kullanıcılar/teklifler/projeler/finans kayıtları olduğu gibi saklanır. Bu bir silme işlemi DEĞİLDİR; gerekirse yeniden aktifleştirilebilir.",
    danger: true,
    buttonVariant: "danger",
  },
};

export function canTransition(from: OrgStatus, to: OrgStatus): boolean {
  return TRANSITIONS[from].includes(to);
}

export function orgLifecycleActions(status: OrgStatus): OrgLifecycleAction[] {
  return TRANSITIONS[status]
    .filter((target): target is Exclude<OrgStatus, "trial"> => target !== "trial")
    .map((target) => {
      const meta = ACTION_META[target];
      const label = target === "active" && status !== "trial" ? "Yeniden Aktifleştir" : meta.label;
      return { target, ...meta, label };
    });
}
