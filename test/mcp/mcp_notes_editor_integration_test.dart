import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:gitvault/features/notes/note_editor_screen.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';
import 'package:hive/hive.dart';

import '../support/memory_registry_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    (true, 'autosave'),
    (false, 'autosave'),
    (true, 'archive'),
    (true, 'delete'),
    (false, 'archive'),
    (false, 'delete')
  ]) {
    final (editorFirst, editorAction) = scenario;
    testWidgets(
        'MCP-GAP-009 real editor/MCP $editorAction conflict editorFirst=$editorFirst',
        (tester) async {
      late Directory directory;
      late CryptoManager crypto;
      late MemoryRegistryStorage storage;
      late NotesRepository repository;
      late Note original;
      late McpClientRegistry registry;
      late String clientId;
      late McpApprovalController approvals;
      late NotesMcpService service;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('mcp-editor-');
        Hive.init(directory.path);
        crypto = CryptoManager();
        storage = MemoryRegistryStorage()..root = crypto.generateRandomKey();
        repository =
            NotesRepository(cryptoManager: crypto, keyStorage: storage);
        await repository.initialize();
        original =
            await repository.createNote(title: 'Original', content: 'Body');
        registry = McpClientRegistry();
        await registry.setEnabled(true);
        final issued = await registry.createClient(
            displayName: 'Concurrent app',
            transport: McpClientTransport.streamableHttp,
            permissions: {McpPermission.edit},
            writePolicy: McpWritePolicy.askEveryTime);
        clientId = issued.client.id;
        approvals = McpApprovalController();
        service = NotesMcpService(
            notesRepository: repository,
            registry: registry,
            approvalController: approvals,
            readSession: () => VaultSessionState(
                status: VaultSessionStatus.unlocked,
                changedAt: DateTime.now(),
                generation: 1));
        addTearDown(() => tester.runAsync(() async {
              approvals.dispose();
              registry.dispose();
              await Hive.close();
              await directory.delete(recursive: true);
            }));
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('com.giofahreza.gitvault/ime'),
                (_) async => null);
      });

      await tester.pumpWidget(ProviderScope(
        overrides: [
          keyStorageProvider.overrideWithValue(storage),
          notesRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => FilledButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) =>
                                    NoteEditorDialog(note: original))),
                        child: const Text('Open editor'))))),
      ));
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();

      late Future<Map<String, dynamic>> write;
      await tester.runAsync(() async {
        write = service.updateNote(
            clientId: clientId,
            noteId: original.uuid,
            expectedModifiedAt: original.modifiedAt.toUtc().toIso8601String(),
            content: 'MCP content');
      });
      final result = editorFirst
          ? expectLater(
              write,
              throwsA(isA<McpOperationException>()
                  .having((e) => e.code, 'code', 'conflict')))
          : write.then<void>((_) {});
      var done = false;
      result.then((_) => done = true);
      for (var i = 0; i < 20 && approvals.nextRequest == null; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(approvals.nextRequest, isNotNull);

      Future<void> edit() async {
        if (editorAction != 'autosave') {
          if (editorFirst) {
            await tester.runAsync(() => tester.enterText(
                find.byWidgetPredicate(
                    (w) => w is TextField && w.controller?.text == 'Body'),
                'Editor content'));
          }
          await tester
              .runAsync(() => tester.tap(find.byTooltip('More note actions')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.runAsync(() => tester.tap(
              find.text(editorAction == 'archive' ? 'Archive' : 'Delete')));
          await tester.pump();
          if (editorAction == 'delete') {
            await tester.pump(const Duration(milliseconds: 350));
            await tester.runAsync(
                () => tester.tap(find.widgetWithText(FilledButton, 'Delete')));
          }
          for (var i = 0; i < 40; i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 20));
          }
          return;
        }
        final field = find.byWidgetPredicate(
            (w) => w is TextField && w.controller?.text == 'Body');
        expect(field, findsOneWidget);
        await tester.runAsync(() async {
          await tester.enterText(field, 'Editor content');
          await Future<void>.delayed(const Duration(milliseconds: 800));
        });
        await tester.pump(const Duration(milliseconds: 650));
        for (var i = 0; i < 50; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 20));
          if (find.text('Saved').evaluate().isNotEmpty ||
              find.text('Save failed · Retry').evaluate().isNotEmpty) break;
        }
      }

      if (editorFirst) await edit();
      approvals.resolve(
          approvals.nextRequest!.id, McpApprovalDecision.allowOnce);
      for (var i = 0; i < 50 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      expect(done, true);
      await result;
      if (!editorFirst) await edit();
      final persisted =
          await tester.runAsync(() => repository.getNote(original.uuid));
      if (editorFirst && editorAction == 'delete') {
        expect(persisted, null);
      } else {
        expect(
            persisted!.content, editorFirst ? 'Editor content' : 'MCP content');
      }
      if (!editorFirst && editorAction == 'autosave') {
        expect(find.text('Editor content'), findsOneWidget);
        expect(find.text('Save failed · Retry'), findsOneWidget);
      }
      if (editorAction != 'autosave') {
        if (editorFirst) {
          if (editorAction == 'archive') expect(persisted!.isArchived, true);
          expect(find.byType(NoteEditorDialog), findsNothing);
        } else {
          expect(persisted!.isArchived, false);
          expect(find.byType(NoteEditorDialog), findsOneWidget);
          expect(find.textContaining('changed'), findsOneWidget);
        }
      }
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
      // Disposing a conflicted editor queues one last guarded save. Drain
      // both the fake frame zone and real crypto I/O before closing Hive;
      // otherwise the static repository queue survives into the next test.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      final reopened =
          NotesRepository(cryptoManager: crypto, keyStorage: storage);
      await tester.runAsync(reopened.initialize);
      final durable =
          await tester.runAsync(() => reopened.getNote(original.uuid));
      if (editorFirst && editorAction == 'delete') {
        expect(durable, null);
      } else {
        expect(
            durable!.content, editorFirst ? 'Editor content' : 'MCP content');
        expect(durable.isArchived, editorFirst && editorAction == 'archive');
      }
    });
  }
}
