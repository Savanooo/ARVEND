export function PageHeader({ title, action }: { title: React.ReactNode; action?: React.ReactNode }) {
  return (
    <header className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-8 py-5">
      <h1 className="text-lg font-bold tracking-tight">{title}</h1>
      {action}
    </header>
  );
}
