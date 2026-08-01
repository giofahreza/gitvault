import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'mcp_models.dart';

class McpApprovalController extends ChangeNotifier {
  static const Duration defaultTimeout = Duration(seconds: 60);

  final Uuid _uuid = const Uuid();
  final List<McpApprovalRequest> _pending = [];
  final Map<String, Completer<McpApprovalDecision>> _completers = {};
  final Map<String, Timer> _timers = {};

  List<McpApprovalRequest> get pending => List.unmodifiable(_pending);

  McpApprovalRequest? get nextRequest =>
      _pending.isEmpty ? null : _pending.first;

  Future<McpApprovalDecision> request({
    required String clientId,
    required String clientName,
    required McpPermission permission,
    required String action,
    required String summary,
    String? noteId,
    String? noteTitle,
    String? before,
    String? after,
    Duration timeout = defaultTimeout,
  }) {
    final now = DateTime.now().toUtc();
    final request = McpApprovalRequest(
      id: _uuid.v4(),
      clientId: clientId,
      clientName: clientName,
      permission: permission,
      action: action,
      noteId: noteId,
      noteTitle: noteTitle,
      summary: summary,
      before: before,
      after: after,
      createdAt: now,
      expiresAt: now.add(timeout),
    );
    final completer = Completer<McpApprovalDecision>();
    _pending.add(request);
    _completers[request.id] = completer;
    _timers[request.id] = Timer(
      timeout,
      () => resolve(request.id, McpApprovalDecision.timeout),
    );
    notifyListeners();
    return completer.future;
  }

  void resolve(String requestId, McpApprovalDecision decision) {
    final completer = _completers.remove(requestId);
    if (completer == null) return;
    _timers.remove(requestId)?.cancel();
    _pending.removeWhere((request) => request.id == requestId);
    if (!completer.isCompleted) completer.complete(decision);
    notifyListeners();
  }

  void cancelForClient(String clientId) {
    final ids = _pending
        .where((request) => request.clientId == clientId)
        .map((request) => request.id)
        .toList();
    for (final id in ids) {
      resolve(id, McpApprovalDecision.cancelled);
    }
  }

  void cancelAll() {
    for (final id in _completers.keys.toList()) {
      resolve(id, McpApprovalDecision.cancelled);
    }
  }

  @override
  void dispose() {
    cancelAll();
    super.dispose();
  }
}
