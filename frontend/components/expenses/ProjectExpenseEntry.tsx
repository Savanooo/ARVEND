"use client";

import Link from "next/link";
import { useState } from "react";

import { Section } from "@/components/ui/Accordion";
import { Button } from "@/components/ui/Button";
import { buttonClass } from "@/components/ui/styles";
import { myExpensesHref } from "@/lib/expenses";
import type { Project } from "@/lib/types";

import { ExpenseForm } from "./ExpenseForm";

// Finans sekmesini GÖREMEYEN (projects.finance.read yok) ama masraf girebilen
// (projects.expenses.create) kişinin proje sayfasındaki ayrı girişi -- mobil
// proje Özeti'ndeki "Masraf Ekle" + "Masraf Takibi" (backend migration 0066).
// Form yalnızca temel alanları gösterir (bağlar finance.manage ister); girilen
// masrafın durumu Masraflarım'da (bu projeyle süzülmüş) izlenir. Ana sayfanın
// "Masraf Gir" hızlı işlemi bu kişiyi buraya (Genel sekmesi) getirir.
export function ProjectExpenseEntry({ project, locked }: { project: Project; locked: boolean }) {
  const [formOpen, setFormOpen] = useState(false);
  return (
    <Section title="Masraflarım" defaultOpen>
      <div className="flex flex-col gap-3">
        <p className="text-sm text-text-muted">
          Bu projeye yaptığın harcamayı gir; yönetici onaylayınca projenin maliyetine işlenir. Girdiğin masrafların
          durumunu (onay bekliyor, onaylandı, reddedildi) Masraflarım&apos;da izleyebilirsin.
        </p>
        {locked ? (
          <p className="text-xs text-text-muted">
            {project.status === "cancelled"
              ? "Bu proje iptal edilmiş; masraf girilemez."
              : "Proje tamamlandı; masraf girilemez."}
          </p>
        ) : (
          formOpen && (
            <div className="border-t border-border pt-3">
              <ExpenseForm
                projectId={project.id}
                currency={project.currency}
                canLink={false}
                idPrefix="expense_entry"
                onDone={() => setFormOpen(false)}
                onCancel={() => setFormOpen(false)}
              />
            </div>
          )
        )}
        <div className="flex flex-wrap items-center gap-2">
          {!locked && !formOpen && (
            <Button type="button" onClick={() => setFormOpen(true)}>
              + Masraf Ekle
            </Button>
          )}
          <Link href={myExpensesHref({ projectId: project.id })} className={buttonClass("secondary")}>
            Masraf Takibi
          </Link>
        </div>
      </div>
    </Section>
  );
}
