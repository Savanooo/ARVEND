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

export interface OrgLifecycleAction {
  target: OrgStatus;
  label: string;
  description: string;
  danger: boolean;
}

const ACTION_META: Record<Exclude<OrgStatus, "trial">, Omit<OrgLifecycleAction, "target">> = {
  active: {
    label: "Aktifleştir",
    description: "Firma kullanıcıları yeniden giriş yapabilir; plan ve tüm veriler olduğu gibi devam eder.",
    danger: false,
  },
  suspended: {
    label: "Askıya Al",
    description:
      "Tüm kullanıcılar (açık oturumlar dahil) anında erişimi kaybeder. Veriler korunur; firma istendiğinde yeniden aktifleştirilebilir.",
    danger: true,
  },
  cancelled: {
    label: "İptal Et",
    description:
      "Firma iptal edilir: erişim kapanır, kullanıcılar/teklifler/projeler/finans kayıtları olduğu gibi saklanır. Bu bir silme işlemi DEĞİLDİR; gerekirse yeniden aktifleştirilebilir.",
    danger: true,
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
