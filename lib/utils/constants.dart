/// Global constants for GitVault
class Constants {
  // Cryptography
  static const int blockSize = 4096; // 4KB blocks for padding
  static const int nonceSize = 24; // XChaCha20 nonce size
  static const int macSize = 16; // Poly1305 MAC tag size
  static const int keySize = 32; // 256-bit key

  // Storage
  static const String dataFolder = 'data';
  static const String indexFile = 'index.bin';
  static const String trustedDevicesFile = 'trusted_devices.bin';
  static const String fileExtension = '.bin';

  // Security
  static const int clipboardClearDelay = 30; // seconds
  static const int totpInterval = 30; // seconds
  static const int totpDigits = 6;

  // Sync
  static const String defaultCommitMessage = 'Update entry';
}
