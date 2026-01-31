import 'dart:typed_data';
import 'package:bip39/bip39.dart' as bip39;
import 'package:hex/hex.dart';

/// Helper class for converting between root keys and BIP39 mnemonic phrases
class MnemonicHelper {
  /// Generates a new 24-word mnemonic phrase and returns both mnemonic and root key
  static MnemonicResult generateMnemonic() {
    // Generate 256-bit entropy for 24 words
    final mnemonic = bip39.generateMnemonic(strength: 256);
    final rootKey = mnemonicToRootKey(mnemonic);
    return MnemonicResult(mnemonic: mnemonic, rootKey: rootKey);
  }

  /// Converts a mnemonic phrase to a 32-byte root key
  /// Uses the mnemonic's entropy directly as the root key (256 bits = 32 bytes)
  static Uint8List mnemonicToRootKey(String mnemonic) {
    // Validate mnemonic first
    if (!isValidMnemonic(mnemonic)) {
      throw Exception('Invalid mnemonic phrase');
    }

    // Get the entropy (raw bytes) from the mnemonic
    // For 24 words, this gives us 32 bytes (256 bits)
    final entropyHex = bip39.mnemonicToEntropy(mnemonic);
    final entropyBytes = HEX.decode(entropyHex);

    return Uint8List.fromList(entropyBytes);
  }

  /// Converts a 32-byte root key to a 24-word mnemonic phrase
  static String rootKeyToMnemonic(Uint8List rootKey) {
    if (rootKey.length != 32) {
      throw Exception('Root key must be exactly 32 bytes (256 bits)');
    }

    // Convert bytes to hex string
    final entropyHex = HEX.encode(rootKey);

    // Convert entropy to mnemonic
    final mnemonic = bip39.entropyToMnemonic(entropyHex);

    return mnemonic;
  }

  /// Validates a mnemonic phrase
  static bool isValidMnemonic(String mnemonic) {
    return bip39.validateMnemonic(mnemonic);
  }

  /// Formats a mnemonic for display (adds numbering)
  static String formatMnemonicForDisplay(String mnemonic) {
    final words = mnemonic.split(' ');
    final buffer = StringBuffer();

    for (int i = 0; i < words.length; i++) {
      buffer.write('${i + 1}. ${words[i]}');
      if ((i + 1) % 4 == 0 && i != words.length - 1) {
        buffer.write('\n');
      } else if (i != words.length - 1) {
        buffer.write('  ');
      }
    }

    return buffer.toString();
  }

  /// Gets word count from mnemonic
  static int getWordCount(String mnemonic) {
    return mnemonic.trim().split(RegExp(r'\s+')).length;
  }

  /// Normalizes mnemonic (lowercase, single spaces)
  static String normalizeMnemonic(String mnemonic) {
    return mnemonic
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .join(' ');
  }
}

/// Result from mnemonic generation
class MnemonicResult {
  final String mnemonic;
  final Uint8List rootKey;

  MnemonicResult({
    required this.mnemonic,
    required this.rootKey,
  });
}
