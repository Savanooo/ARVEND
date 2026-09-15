import { redirect } from "next/navigation";

import type { User } from "./types";

/**
 * Kullanıcının bulunması gereken rota -- must-change-password ÖNCE,
 * onboarding SONRA sıralanır (spec: "must_change_password first-login
 * flow... sequenced before onboarding"); super_admin herhangi bir
 * organizasyona bağlı olmadığı için onboarding'den muaftır. Giriş sonrası
 * yönlendirme (giris/page.tsx, client) İLE (admin)/(app)/(panel)/root
 * page.tsx'in (server) zorunlu-akış kontrolü AYNI kaynağı kullanır --
 * mantık iki kez yazılmaz.
 */
export function nextDestination(user: User): string {
  if (user.must_change_password) return "/sifre-belirle";
  if (user.role !== "super_admin" && !user.onboarding_completed) return "/kurulum";
  if (user.role === "super_admin") return "/super-admin";
  return user.role === "admin" ? "/admin" : "/panel";
}

/**
 * (admin)/(app)/(panel) layout'larının ortak zorunlu-akış kontrolü --
 * super_admin bu layout'lara hiç giremediği için (kendi role kontrolleri
 * zaten reddeder) burada ayrıca ele alınmaz.
 */
export function enforceFirstLoginFlow(user: User): void {
  if (user.must_change_password) redirect("/sifre-belirle");
  if (!user.onboarding_completed) redirect("/kurulum");
}
