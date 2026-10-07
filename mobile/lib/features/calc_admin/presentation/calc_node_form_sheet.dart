import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../domain/calc_admin.dart';
import 'calc_admin_common.dart';
import '../../../core/widgets/app_sheet.dart';

/// Formun gönderdiği değerler -- grup ve kategori AYNI alan kümesini
/// kullanır (web NewGroupButton/NewCategoryButton + EditGroupForm/
/// EditCategoryForm).
typedef CalcNodeValues = ({String name, String slug, String description, int sortOrder, bool isActive});

/// Grup / kategori (hesaplama türü) oluştur + düzenle sayfası. Oluştururken
/// web gibi yalnızca Ad/Slug/Açıklama sorulur (sıra 0, aktif); düzenlerken
/// Sıra ve Aktif de gelir. Slug, kullanıcı elle değiştirene kadar addan
/// otomatik üretilir (web `slugify` davranışı).
class CalcNodeFormSheet extends StatefulWidget {
  const CalcNodeFormSheet({
    super.key,
    required this.title,
    required this.nameHint,
    required this.onSubmit,
    this.initial,
    this.nameMaxLength = CalcLimits.nodeName,
  });

  /// Grup adı en çok 120, kategori adı 160 karakter (veritabanı sütunları).
  final int nameMaxLength;
  final String title;
  final String nameHint;
  final CalcNodeValues? initial;

  /// Başarılıysa sayfa kapanır; hata fırlatırsa mesajı formda gösterilir.
  final Future<void> Function(CalcNodeValues values) onSubmit;

  bool get isEdit => initial != null;

  @override
  State<CalcNodeFormSheet> createState() => _CalcNodeFormSheetState();
}

/// Sayfayı açar; kayıt başarılıysa `true` döner. Önbellek tazelemesi
/// [onSubmit] İÇİNDE yapılmalı: sayfa kapanmış olsa da çalışsın.
Future<bool> showCalcNodeFormSheet(
  BuildContext context, {
  required String title,
  required String nameHint,
  required Future<void> Function(CalcNodeValues values) onSubmit,
  CalcNodeValues? initial,
  int nameMaxLength = CalcLimits.nodeName,
}) async {
  final saved = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CalcNodeFormSheet(
      title: title,
      nameHint: nameHint,
      initial: initial,
      onSubmit: onSubmit,
      nameMaxLength: nameMaxLength,
    ),
  );
  return saved == true;
}

class _CalcNodeFormSheetState extends State<CalcNodeFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _slug;
  late final TextEditingController _description;
  late final TextEditingController _sortOrder;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  /// Slug'ın hâlâ otomatik türev olup olmadığını anlamak için önceki ad.
  String _lastName = '';

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? '');
    _slug = TextEditingController(text: i?.slug ?? '');
    _description = TextEditingController(text: i?.description ?? '');
    _sortOrder = TextEditingController(text: '${i?.sortOrder ?? 0}');
    _isActive = i?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    _description.dispose();
    _sortOrder.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    // Yalnızca oluştururken ve slug hâlâ adın otomatik türeviyse izler --
    // kullanıcı slug'ı elle değiştirdiyse dokunulmaz.
    if (widget.isEdit) return;
    final previousAuto = slugify(_lastName);
    if (_slug.text.isEmpty || _slug.text == previousAuto) {
      _slug.text = slugify(value);
    }
    _lastName = value;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit((
        name: _name.text.trim(),
        slug: _slug.text.trim(),
        description: _description.text.trim(),
        sortOrder: int.tryParse(_sortOrder.text.trim()) ?? 0,
        isActive: _isActive,
      ));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = calcAdminErrorMessage(e, write: true));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      busy: _saving,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.title, style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Bilgiler',
                  children: [
                    TextFormField(
                      controller: _name,
                      inputFormatters: [LengthLimitingTextInputFormatter(widget.nameMaxLength)],
                      decoration: InputDecoration(labelText: 'Ad *', hintText: widget.nameHint),
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: _onNameChanged,
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Ad zorunludur' : null,
                    ),
                    TextFormField(
                      controller: _slug,
                      inputFormatters: [LengthLimitingTextInputFormatter(CalcLimits.slug)],
                      decoration: const InputDecoration(
                        labelText: 'Slug *',
                        helperText: 'Adresteki kısa ad; addan otomatik üretilir.',
                      ),
                      autocorrect: false,
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Slug zorunludur' : null,
                    ),
                    TextFormField(
                      controller: _description,
                      decoration: const InputDecoration(labelText: 'Açıklama'),
                      maxLines: 3,
                      minLines: 2,
                    ),
                    if (widget.isEdit) ...[
                      TextFormField(
                        controller: _sortOrder,
                        decoration: const InputDecoration(labelText: 'Sıra'),
                        keyboardType: const TextInputType.numberWithOptions(signed: true),
                        validator: (v) => (v != null && v.trim().isNotEmpty && int.tryParse(v.trim()) == null)
                            ? 'Tam sayı gir'
                            : null,
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: _isActive,
                        onChanged: (v) => setState(() => _isActive = v),
                        title: const Text('Aktif', style: AppTypography.body),
                        subtitle: const Text('Metraj Hesapla panelinde görünür', style: AppTypography.helper),
                      ),
                    ],
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(label: widget.isEdit ? 'Kaydet' : 'Oluştur', loading: _saving, onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
