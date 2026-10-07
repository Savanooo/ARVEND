import { apiServer } from "@/lib/api";
import type { User } from "@/lib/types";

// Backend (ListUsersWithRoles) sayfa başına en fazla 200 kullanıcı döner.
const USERS_PAGE_SIZE = 200;
// Bozuk bir "total" sonsuz döngüye sokmasın.
const MAX_PAGES = 50;

/**
 * "Bağlı Kullanıcı Hesabı" seçicisi için firmanın TÜM kullanıcıları.
 * Eskiden /api/v1/users sayfasız çağrılıyordu: backend en yeni 50
 * kullanıcıyı döndüğü için en eskiler -- Sahip dahil -- listede yoktu ve
 * personele bağlanamıyordu. Sayfa sayfa hepsi alınır, ada göre sıralanır.
 */
export async function fetchAllUsers(cookieHeader: string): Promise<User[]> {
  const all: User[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const { users, total } = await apiServer<{ users: User[]; total: number }>(
      `/api/v1/users?page=${page}&limit=${USERS_PAGE_SIZE}`,
      cookieHeader
    );
    all.push(...users);
    if (users.length < USERS_PAGE_SIZE || all.length >= total) break;
  }
  return all.sort((a, b) => a.full_name.localeCompare(b.full_name, "tr"));
}
