/// backend/internal/domain/user.go: Role = "admin" | "kullanici".
enum UserRole {
  admin('admin'),
  kullanici('kullanici');

  const UserRole(this.wireValue);
  final String wireValue;

  static UserRole fromWire(String value) => switch (value) {
        'admin' => UserRole.admin,
        _ => UserRole.kullanici,
      };
}

/// backend/internal/httpapi/handler/auth_handler.go: userResponse struct.
/// NOT: organization_id/organization adı bu yanıtta YOK (yalnızca rol
/// bilgisi var) - bkz. mobile/API_CONTRACT.md ve MOBILE_BACKEND_GAPS.md.
class User {
  final String id;
  final String username;
  final String fullName;
  final UserRole role;
  final bool isActive;

  const User({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    required this.isActive,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        username: json['username'] as String,
        fullName: json['full_name'] as String,
        role: UserRole.fromWire(json['role'] as String),
        isActive: json['is_active'] as bool,
      );
}
