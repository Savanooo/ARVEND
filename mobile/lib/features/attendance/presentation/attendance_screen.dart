import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/attendance_providers.dart';
import '../domain/attendance.dart';

class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  DateTime _month = DateTime.now();

  String get _monthKey => '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final recordsAsync = ref.watch(attendanceListProvider(_monthKey));

    return Scaffold(
      appBar: AppBar(title: const Text('Mesai')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateSheet(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                ),
                Text('${_month.year} / ${_month.month.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(attendanceListProvider(_monthKey)),
              child: AsyncStateView(
                value: recordsAsync,
                onRetry: () async => ref.invalidate(attendanceListProvider(_monthKey)),
                isEmpty: (l) => l.isEmpty,
                emptyBuilder: (_) => const EmptyStateView(message: 'Bu ay için kayıt yok.'),
                data: (context, records) => ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                  itemCount: records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    final r = records[i];
                    return Card(
                      child: ListTile(
                        title: Text(r.employeeName.isEmpty ? r.employeeId : r.employeeName),
                        subtitle: Text('${r.date}  ${r.checkIn}${r.checkOut.isNotEmpty ? '-${r.checkOut}' : ''}'),
                        trailing: StatusRegistry.build(r.status, StatusRegistry.attendance),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showCreateSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _AttendanceFormSheet(onCreated: () => ref.invalidate(attendanceListProvider(_monthKey))),
    );
  }
}

class _AttendanceFormSheet extends ConsumerStatefulWidget {
  const _AttendanceFormSheet({required this.onCreated});
  final VoidCallback onCreated;

  @override
  ConsumerState<_AttendanceFormSheet> createState() => _AttendanceFormSheetState();
}

class _AttendanceFormSheetState extends ConsumerState<_AttendanceFormSheet> {
  Employee? _employee;
  DateTime _date = DateTime.now();
  String _status = 'geldi';
  final _checkInController = TextEditingController(text: '08:00');
  final _checkOutController = TextEditingController(text: '17:00');
  final _hoursController = TextEditingController(text: '8');
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _checkInController.dispose();
    _checkOutController.dispose();
    _hoursController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final employeesAsync = ref.watch(employeesProvider);

    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Mesai Kaydı Ekle', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 16),
            employeesAsync.when(
              data: (employees) => DropdownButtonFormField<Employee>(
                initialValue: _employee,
                decoration: const InputDecoration(labelText: 'Personel'),
                items: employees.map((e) => DropdownMenuItem(value: e, child: Text(e.fullName))).toList(),
                onChanged: (v) => setState(() => _employee = v),
              ),
              loading: () => const LinearProgressIndicator(),
              error: (e, st) => const Text('Personel listesi alınamadı'),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tarih'),
              subtitle: Text('${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}'),
              onTap: () async {
                final picked = await showDatePicker(
                    context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (picked != null) setState(() => _date = picked);
              },
            ),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Durum'),
              items: kAttendanceStatuses
                  .map((s) => DropdownMenuItem(value: s, child: Text(StatusRegistry.attendance[s]!.$1)))
                  .toList(),
              onChanged: (v) => setState(() => _status = v!),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(controller: _checkInController, decoration: const InputDecoration(labelText: 'Giriş')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(controller: _checkOutController, decoration: const InputDecoration(labelText: 'Çıkış')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hoursController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Çalışma Saati'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_employee == null) {
      setState(() => _error = 'Personel seçin');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(attendanceRepositoryProvider).create(
            employeeId: _employee!.id,
            date: '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
            checkIn: _checkInController.text.trim(),
            checkOut: _checkOutController.text.trim(),
            workHours: double.tryParse(_hoursController.text.replaceAll(',', '.')) ?? 0,
            status: _status,
          );
      widget.onCreated();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
