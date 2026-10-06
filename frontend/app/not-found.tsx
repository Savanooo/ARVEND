import { NotFoundView } from "@/components/layout/RouteFallbacks";

// Eşleşmeyen URL'ler ve kabuk dışı sayfalardaki notFound() çağrıları.
export default function RootNotFound() {
  return (
    <div className="flex min-h-screen">
      <NotFoundView />
    </div>
  );
}
