export type Role = "admin" | "kullanici";

export interface User {
  id: string;
  username: string;
  full_name: string;
  role: Role;
  is_active?: boolean;
}

export interface ApiErrorBody {
  error: string;
}
