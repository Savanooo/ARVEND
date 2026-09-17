import 'package:flutter_test/flutter_test.dart';
import 'package:arvend/features/projects/domain/project.dart';

void main() {
  test('ProjectTask.fromJson parses /tasks/mine row fields', () {
    final task = ProjectTask.fromJson({
      'id': 't1',
      'title': 'KalÄ±p kontrol',
      'description': 'desc',
      'assigned_employee_id': null,
      'assigned_name': '',
      'priority': 'normal',
      'status': 'todo',
      'due_date': '2026-09-20',
      'completed_at': null,
      'is_overdue': false,
      'schedule_item_id': null,
      'project_id': 'p1',
      'project_name': 'Villa Projesi',
    });
    expect(task.id, 't1');
    expect(task.title, 'KalÄ±p kontrol');
    expect(task.status, 'todo');
    expect(task.priority, 'normal');
    expect(task.isOverdue, isFalse);
  });
}

