import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VaultSessionStatus {
  starting,
  locked,
  unlocking,
  unlocked,
  duress,
  revoked,
}

class VaultSessionState {
  final VaultSessionStatus status;
  final DateTime changedAt;
  final String? reason;
  final int generation;

  const VaultSessionState({
    required this.status,
    required this.changedAt,
    required this.generation,
    this.reason,
  });

  bool get canAccessVault => status == VaultSessionStatus.unlocked;

  bool get isTerminal =>
      status == VaultSessionStatus.duress ||
      status == VaultSessionStatus.revoked;
}

class VaultSessionController extends StateNotifier<VaultSessionState> {
  VaultSessionController()
      : super(
          VaultSessionState(
            status: VaultSessionStatus.starting,
            changedAt: DateTime.now(),
            generation: 0,
          ),
        );

  void markStarting({String? reason}) {
    _transition(VaultSessionStatus.starting, reason: reason);
  }

  void beginUnlock({String? reason}) {
    _transition(VaultSessionStatus.unlocking, reason: reason);
  }

  void unlock({String? reason}) {
    _transition(VaultSessionStatus.unlocked, reason: reason);
  }

  void lock({String? reason}) {
    _transition(VaultSessionStatus.locked, reason: reason);
  }

  void activateDuress({String? reason}) {
    _transition(
      VaultSessionStatus.duress,
      reason: reason ?? 'Duress mode activated',
    );
  }

  void revoke({String? reason}) {
    _transition(
      VaultSessionStatus.revoked,
      reason: reason ?? 'This device is no longer trusted',
    );
  }

  void _transition(VaultSessionStatus next, {String? reason}) {
    state = VaultSessionState(
      status: next,
      changedAt: DateTime.now(),
      reason: reason,
      generation: state.generation + 1,
    );
  }
}
