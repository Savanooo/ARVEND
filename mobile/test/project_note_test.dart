import 'package:flutter_test/flutter_test.dart';
import 'package:arvend/features/projects/domain/project.dart';

void main() {
  test('ProjectNote.fromJson maps list/create response fields', () {
    final note = ProjectNote.fromJson({
      'id': 'n1',
      'content': 'Sahada beton dokumu tamam',
      'created_by_name': 'Ayse Yilmaz',
      'created_at': '2026-09-17T10:00:00Z',
    });
    expect(note.id, 'n1');
    expect(note.content, 'Sahada beton dokumu tamam');
    expect(note.createdByName, 'Ayse Yilmaz');
    expect(note.createdAt, '2026-09-17T10:00:00Z');
  });

  test('ProjectNote.fromJson tolerates missing optional display fields', () {
    final note = ProjectNote.fromJson({'id': 'n2'});
    expect(note.content, '');
    expect(note.createdByName, '');
    expect(note.createdAt, '');
  });
}
