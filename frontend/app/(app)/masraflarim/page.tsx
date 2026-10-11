import Link from "next/link";
import { cookies } from "next/headers";

import { PickerActionButton } from "@/components/dashboard/PickerActionButton";
import { PageHeader } from "@/components/layout/PageHeader";
import { buttonClass } from "@/components/ui/styles";
import { apiServer, ApiError } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { projectHref, quickActionFor } from "@/lib/dashboard";
import { expenseActorFor, MY_EXPENSES_PATH } from "@/lib/expenses";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";
import type { MyExpense } from "@/lib/types";

import { MyExpensesView } from "./MyExpensesView";

type MyExpensesResponse = { expenses: MyExpense[]; limit: number };

function first(v: string | string[] | undefined): string | null {
  const s = Array.isArray(v) ? v[0] : v;
  return s && s.trim() ? s.trim() : null;
}

// Masraflarım (backend migration 0066; mobil /diger/masraflarim): kişinin
// KENDİ girdiği masraflar, projeler arası, en yeni giriş önce (sunucu en
// fazla `limit`). GET /expenses/mine projects.expenses.create ister --
// finans okuma izni gerekmez, sunucu yalnızca kişinin kendi kayıtlarını
// döndürür, toplam/özet YOKTUR.
//
// ?proje=<id>: o projeyle süzülür (proje sayfasındaki "Masraf Takibi").
// ?masraf=<id>: karar bildiriminden gelince o masrafın ayrıntısı bir kez açılır.
export default async function MasraflarimPage({
  searchParams,
}: {
  searchParams: Promise<{ proje?: string | string[]; masraf?: string | string[] }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.myExpenses);
  const sp = await searchParams;
  const projectId = first(sp.proje);
  const expenseId = first(sp.masraf);
  const cookieHeader = (await cookies()).toString();
  const path = projectId
    ? `/api/v1/expenses/mine?project_id=${encodeURIComponent(projectId)}`
    : "/api/v1/expenses/mine";
  const result = await apiServer<MyExpensesResponse>(path, cookieHeader).then(
    (data) => ({ data, error: null }),
    (err: unknown) => ({
      data: null,
      error: err instanceof ApiError ? err.message : "Masraflar yüklenemedi. Lütfen tekrar dene.",
    })
  );

  // "Masraf Gir": ana sayfadaki hızlı işlemle aynı kapı (proje seçici
  // projects.read ister); liste o izin olmadan da çalışır. Süzülmüş projede
  // doğrudan o projenin masraf girişine gider.
  const add = quickActionFor(user, "expense");
  const addAction = add?.pickerTab ? (
    projectId ? (
      <Link href={projectHref(projectId, add.pickerTab)} className={buttonClass("primary")}>
        + Masraf Gir
      </Link>
    ) : (
      <PickerActionButton tab={add.pickerTab} label="+ Masraf Gir" />
    )
  ) : undefined;

  return (
    <>
      <PageHeader title="Masraflarım" action={addAction} />
      <div className="flex flex-col gap-4 p-8">
        {result.data ? (
          <MyExpensesView
            rows={result.data.expenses}
            limit={result.data.limit}
            actor={expenseActorFor(user)}
            projectId={projectId}
            initialExpenseId={expenseId}
            canOpenProjects={hasPermission(user.permissions, PAGE_PERMISSIONS.projects)}
          />
        ) : (
          <div className="flex flex-col gap-3 rounded-lg border border-border bg-surface p-6 text-sm">
            <p className="text-danger">{result.error}</p>
            {projectId && (
              <Link href={MY_EXPENSES_PATH} className="text-text-muted hover:text-gold hover:underline">
                Tüm projelerdeki masraflarım →
              </Link>
            )}
          </div>
        )}
      </div>
    </>
  );
}
