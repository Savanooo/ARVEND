import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../attendance/data/attendance_providers.dart';
import '../../attendance/domain/attendance.dart' show Employee;
import '../../tasks/data/tasks_providers.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';

String? _fmtDate(DateTime? d) {
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// Faz 7 — Görev Ekle/Düzenle. Create + Edit AYNI ekran. Atanacak kişi
/// kataloğu P0'da zaten kurulmuş `employeesProvider`ı (Mesai modülünün
/// organizasyon personel kataloğu) YENİDEN KULLANIR -- ikinci bir personel
/// listesi İCAT EDİLMEZ. Durum bir dropdown'dur -- backend'de sabit bir
/// geçiş grafiği olmadığı için (bkz. domain/project.dart `ProjectTask`
/// yorumu) mobil de kendi kısıtlamasını İCAT ETMEZ, dört durum da HER ZAMAN
/// seçilebilir (yalnızca EDIT'te -- CREATE'te backend zaten 'tamamlandı'
/// olarak açmayı reddeder, bu yüzden create formu durumu hiç sormaz).
class TaskFormScreen extends ConsumerStatefulWidget {
  const TaskFormScreen({super.key, required this.projectId, this.taskId});

  final String projectId;
  final String? taskId;

  bool get isEdit => taskId != null;

  @override
  ConsumerState<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends ConsumerState<TaskFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  String _priority = ProjectTask.priorityNormal;
  String _status = ProjectTask.statusTodo;
  String? _assignedEmployeeId;
  String? _scheduleItemId;
  DateTime? _dueDate;
  bool _loading = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting());
    }
  }

  Future<void> _loadExisting() async {
    try {
      final tasks = await ref.read(projectsRepositoryProvider).tasks(widget.projectId);
      ProjectTask? task;
      for (final t in tasks) {
        if (t.id == widget.taskId) {
          task = t;
          break;
        }
      }
      if (!mounted) return;
      if (task == null) {
        setState(() {
          _loading = false;
          _error = 'Görev bulunamadı.';
        });
        return;
      }
      _titleController.text = task.title;
      _descriptionController.text = task.description;
      _priority = task.priority;
      _status = task.status;
      _assignedEmployeeId = task.assignedEmployeeId;
      _scheduleItemId = task.scheduleItemId;
      _dueDate = _parseDate(task.dueDate);
      setState(() => _loading = false);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final ProjectTask task;
      if (widget.isEdit) {
        task = await repo.updateTask(
          widget.projectId,
          widget.taskId!,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          scheduleItemId: _scheduleItemId,
          assignedEmployeeId: _assignedEmployeeId,
          priority: _priority,
          status: _status,
          dueDate: _fmtDate(_dueDate),
        );
      } else {
        task = await repo.createTask(
          widget.projectId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          assignedEmployeeId: _assignedEmployeeId,
          priority: _priority,
          dueDate: _fmtDate(_dueDate),
        );
      }
      ref.invalidate(projectTasksProvider(widget.projectId));
      ref.invalidate(myTasksProvider);
      ref.invalidate(projectOperationsSummaryProvider(widget.projectId));
      if (mounted) context.go('/projeler/${widget.projectId}/gorevler/${task.id}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final employeesAsync = ref.watch(employeesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Görevi Düzenle' : 'Yeni Görev')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : employeesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _RetryView(error: e, onRetry: () => ref.invalidate(employeesProvider)),
              data: (employees) => _buildForm(context, employees),
            ),
    );
  }

  Widget _buildForm(BuildContext context, List<Employee> employees) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Başlık'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Başlık gerekli' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _descriptionController,
            decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _assignedEmployeeId != null && _assignedEmployeeId!.isNotEmpty ? _assignedEmployeeId : '',
            decoration: const InputDecoration(labelText: 'Atanan Kişi (opsiyonel)'),
            items: [
              const DropdownMenuItem(value: '', child: Text('— Atanmadı —')),
              ...employees
                  .where((e) => e.isActive || e.id == _assignedEmployeeId)
                  .map((e) => DropdownMenuItem(value: e.id, child: Text(e.fullName, overflow: TextOverflow.ellipsis))),
            ],
            onChanged: (v) => setState(() => _assignedEmployeeId = (v == null || v.isEmpty) ? null : v),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _priority,
            decoration: const InputDecoration(labelText: 'Öncelik'),
            items: const [
              DropdownMenuItem(value: ProjectTask.priorityLow, child: Text('Düşük')),
              DropdownMenuItem(value: ProjectTask.priorityNormal, child: Text('Normal')),
              DropdownMenuItem(value: ProjectTask.priorityHigh, child: Text('Yüksek')),
              DropdownMenuItem(value: ProjectTask.priorityUrgent, child: Text('Acil')),
            ],
            onChanged: (v) => setState(() => _priority = v ?? ProjectTask.priorityNormal),
          ),
          if (widget.isEdit) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Durum'),
              items: const [
                DropdownMenuItem(value: ProjectTask.statusTodo, child: Text('Yapılacak')),
                DropdownMenuItem(value: ProjectTask.statusInProgress, child: Text('Devam Ediyor')),
                DropdownMenuItem(value: ProjectTask.statusCompleted, child: Text('Tamamlandı')),
                DropdownMenuItem(value: ProjectTask.statusCancelled, child: Text('İptal Edildi')),
              ],
              onChanged: (v) => setState(() => _status = v ?? ProjectTask.statusTodo),
            ),
          ],
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Vade Tarihi (opsiyonel)'),
            subtitle: _dueDate != null
                ? Text('${_dueDate!.day.toString().padLeft(2, '0')}.${_dueDate!.month.toString().padLeft(2, '0')}.${_dueDate!.year}')
                : null,
            trailing: _dueDate != null
                ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _dueDate = null))
                : const Icon(Icons.calendar_today_outlined, size: 18),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _dueDate ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _dueDate = picked);
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text(widget.isEdit ? 'Kaydet' : 'Görevi Oluştur'),
          ),
        ],
      ),
    );
  }
}

class _RetryView extends StatelessWidget {
  const _RetryView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ApiException ? (error as ApiException).message : 'Beklenmeyen bir hata oluştu.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
          ],
        ),
      ),
    );
  }
}
