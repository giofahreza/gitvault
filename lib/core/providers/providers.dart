import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../crypto/crypto_manager.dart';
import '../crypto/key_storage.dart';
import '../auth/biometric_auth.dart';
import '../auth/duress_manager.dart';
import '../auth/pin_auth.dart';
import '../crypto/blind_handshake.dart';
import '../services/autofill_service.dart';
import '../theme/theme_provider.dart';
import '../../data/repositories/vault_repository.dart';
import '../../data/repositories/notes_repository.dart';
import '../../data/models/vault_entry.dart';
import '../../data/models/note.dart';
import '../../main.dart' show navigatorKey;

export '../theme/theme_provider.dart';

/// Provider for CryptoManager singleton
final cryptoManagerProvider = Provider<CryptoManager>((ref) {
  return CryptoManager();
});

/// Provider for KeyStorage singleton
final keyStorageProvider = Provider<KeyStorage>((ref) {
  return KeyStorage();
});

/// Provider for BiometricAuth singleton
final biometricAuthProvider = Provider<BiometricAuth>((ref) {
  return BiometricAuth();
});

/// Provider for DuressManager
final duressManagerProvider = Provider<DuressManager>((ref) {
  return DuressManager(
    keyStorage: ref.watch(keyStorageProvider),
    cryptoManager: ref.watch(cryptoManagerProvider),
  );
});

/// Provider for BlindHandshake
final blindHandshakeProvider = Provider<BlindHandshake>((ref) {
  return BlindHandshake(
    cryptoManager: ref.watch(cryptoManagerProvider),
  );
});

/// Provider for VaultRepository
final vaultRepositoryProvider = Provider<VaultRepository>((ref) {
  return VaultRepository(
    cryptoManager: ref.watch(cryptoManagerProvider),
    keyStorage: ref.watch(keyStorageProvider),
  );
});

/// Provider for AutofillService
final autofillServiceProvider = Provider<AutofillService>((ref) {
  return AutofillService(
    vaultRepository: ref.watch(vaultRepositoryProvider),
    navigatorKey: navigatorKey,
  );
});

/// Provider for checking if vault is set up
final isVaultSetupProvider = FutureProvider<bool>((ref) async {
  final keyStorage = ref.watch(keyStorageProvider);
  await keyStorage.initialize();
  return await keyStorage.hasRootKey();
});

/// Provider for checking if biometrics are available
final biometricsAvailableProvider = FutureProvider<bool>((ref) async {
  final biometricAuth = ref.watch(biometricAuthProvider);
  return await biometricAuth.isSupported();
});

/// Provider for vault entries list (auto-refreshes when invalidated)
final vaultEntriesProvider = FutureProvider<List<VaultEntry>>((ref) async {
  final repo = ref.watch(vaultRepositoryProvider);
  try {
    await repo.initialize();
    return await repo.getAllEntries();
  } catch (e) {
    return [];
  }
});

/// Provider for NotesRepository
final notesRepositoryProvider = Provider<NotesRepository>((ref) {
  return NotesRepository(
    cryptoManager: ref.watch(cryptoManagerProvider),
    keyStorage: ref.watch(keyStorageProvider),
  );
});

/// Provider for notes list (auto-refreshes when invalidated)
final notesProvider = FutureProvider<List<Note>>((ref) async {
  final repo = ref.watch(notesRepositoryProvider);
  try {
    await repo.initialize();
    return await repo.getAllNotes();
  } catch (e) {
    return [];
  }
});

/// Provider for PinAuth
final pinAuthProvider = Provider<PinAuth>((ref) {
  return PinAuth(keyStorage: ref.watch(keyStorageProvider));
});

/// Provider for checking if PIN is set up
final pinEnabledProvider = FutureProvider<bool>((ref) async {
  final pinAuth = ref.watch(pinAuthProvider);
  return await pinAuth.isPinSetup();
});

/// Provider for biometric enabled state (persisted via secure storage)
/// Initialized from storage at app startup via loadPersistedSettings()
final biometricEnabledProvider = StateProvider<bool>((ref) => true);

/// Provider for clipboard auto-clear seconds (persisted via secure storage)
/// Initialized from storage at app startup via loadPersistedSettings()
final clipboardClearSecondsProvider = StateProvider<int>((ref) => 30);

/// Provider for auto-sync interval in minutes (0 = off)
/// Initialized from storage at app startup via loadPersistedSettings()
final autoSyncIntervalProvider = StateProvider<int>((ref) => 5);

/// Loads persisted settings from secure storage into state providers
Future<void> loadPersistedSettings(ProviderContainer container) async {
  final keyStorage = container.read(keyStorageProvider);
  await keyStorage.initialize(); // Initialize before use
  final biometric = await keyStorage.getBiometricEnabled();
  final clipboard = await keyStorage.getClipboardClearSeconds();
  final themeMode = await keyStorage.getThemeMode();
  final autoSyncInterval = await keyStorage.getAutoSyncInterval();
  container.read(biometricEnabledProvider.notifier).state = biometric;
  container.read(clipboardClearSecondsProvider.notifier).state = clipboard;
  container.read(themeModeProvider.notifier).state = AppThemeMode.fromString(themeMode);
  container.read(autoSyncIntervalProvider.notifier).state = autoSyncInterval;
}
