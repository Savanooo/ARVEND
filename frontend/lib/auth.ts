import { cookies } from "next/headers";

import { apiServer, ApiError } from "./api";
import type { User } from "./types";

/** Server Component'lerde oturum sahibini okur; oturum yoksa/geçersizse null döner. */
export async function getCurrentUser(): Promise<User | null> {
  const cookieStore = await cookies();
  const cookieHeader = cookieStore.toString();
  if (!cookieHeader) return null;

  try {
    return await apiServer<User>("/api/v1/auth/me", cookieHeader);
  } catch (err) {
    if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
      return null;
    }
    throw err;
  }
}
