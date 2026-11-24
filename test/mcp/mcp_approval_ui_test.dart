import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/features/ai_apps/mcp_approval_host.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/mcp_providers.dart';

void main() {
  for (final decision in [
    McpApprovalDecision.allowOnce,
    McpApprovalDecision.allowAlways,
    McpApprovalDecision.deny,
    McpApprovalDecision.cancelled
  ]) {
    testWidgets('MCP-GAP-005 actual approval dialog resolves $decision',
        (tester) async {
      final controller = McpApprovalController();
      await tester.pumpWidget(ProviderScope(
          overrides: [
            mcpApprovalControllerProvider.overrideWith((_) => controller),
          ],
          child: const MaterialApp(
              home: McpApprovalHost(
                  child: Scaffold(
            body: Text('Vault'),
          )))));
      final result = controller.request(
          clientId: 'c',
          clientName: 'AI app',
          permission: McpPermission.edit,
          action: 'update_note',
          summary: 'Edit note',
          before: 'Original body',
          after: 'New body');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('AI app request'), findsOneWidget);
      expect(find.text('Original body', findRichText: true), findsOneWidget);
      expect(find.text('New body', findRichText: true), findsOneWidget);
      if (decision == McpApprovalDecision.cancelled) {
        controller.cancelAll();
      } else {
        await tester.tap(find.text(switch (decision) {
          McpApprovalDecision.allowOnce => 'Allow once',
          McpApprovalDecision.allowAlways => 'Always allow',
          _ => 'Deny',
        }));
      }
      await tester.pumpAndSettle();
      expect(await result, decision);
      expect(controller.pending, isEmpty);
      expect(find.text('AI app request'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'MCP-GAP-005 delete offers one explicit approval and no exemption',
      (tester) async {
    final controller = McpApprovalController();
    await tester.pumpWidget(ProviderScope(overrides: [
      mcpApprovalControllerProvider.overrideWith((_) => controller),
    ], child: const MaterialApp(home: McpApprovalHost(child: Scaffold()))));
    final result = controller.request(
        clientId: 'c',
        clientName: 'AI app',
        permission: McpPermission.delete,
        action: 'delete_note',
        summary: 'Delete note');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Always allow'), findsNothing);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(await result, McpApprovalDecision.allowOnce);
    await tester.pumpWidget(const SizedBox());
  });
}
