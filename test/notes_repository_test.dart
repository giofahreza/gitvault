import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory hiveDirectory;

  setUp(() async {
    hiveDirectory = await Directory.systemTemp.createTemp(
      'gitvault-notes-repository-test-',
    );
    Hive.init(hiveDirectory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  test('note type queries keep archived templates in templates', () async {
    final cryptoManager = CryptoManager();
    final keyStorage = KeyStorage();
    await keyStorage.initialize();
    await keyStorage.storeRootKey(cryptoManager.generateRandomKey());

    final repository = NotesRepository(
      cryptoManager: cryptoManager,
      keyStorage: keyStorage,
    );
    await repository.initialize();

    final regular = await repository.createNote(
      title: 'Regular',
      content: 'Regular body',
    );
    final archivedRegular = await repository.createNote(
      title: 'Archived regular',
      content: 'Archived regular body',
    );
    await repository.updateNote(archivedRegular.copyWith(isArchived: true));
    final template = await repository.createNote(
      title: 'Saved template',
      content: 'Template body',
      isTemplate: true,
    );
    await repository.updateNote(template.copyWith(isArchived: true));

    final activeNotes = await repository.getAllNotes();
    final archivedNotes = await repository.getArchivedNotes();
    final templates = await repository.getTemplates();

    expect(activeNotes.map((note) => note.uuid), [regular.uuid]);
    expect(archivedNotes.map((note) => note.uuid), [archivedRegular.uuid]);
    expect(templates.map((note) => note.uuid), [template.uuid]);
  });
}
