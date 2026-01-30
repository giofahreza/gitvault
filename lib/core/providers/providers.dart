import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../crypto/crypto_manager.dart';
import '../crypto/key_storage.dart';
import '../auth/biometric_auth.dart';
import '../auth/duress_manager.dart';
import '../crypto/blind_handshake.dart';
import '../../data/repositories/vault_repository.dart';

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

/// Provider for checking if vault is set up
final isVaultSetupProvider = FutureProvider<bool>((ref) async {
  final keyStorage = ref.watch(keyStorageProvider);
  return await keyStorage.hasRootKey();
});

/// Provider for checking if biometrics are available
final biometricsAvailableProvider = FutureProvider<bool>((ref) async {
  final biometricAuth = ref.watch(biometricAuthProvider);
  return await biometricAuth.isSupported();
});
