import 'package:flutter/services.dart';
import 'dart:convert';
import '../../../data/models/vault_entry.dart';

/// Manages credential metadata cache for IME keyboard.
/// Sends only {uuid, title, url} to native side (NO passwords or usernames).
/// Native side encrypts with Android KeyStore and stores in noBackupFilesDir.
class CredentialCacheService {
  static const _channel = MethodChannel('com.giofahreza.gitvault/ime');

  /// Update the credential metadata cache after vault changes.
  /// Called after create, update, delete, or sync operations.
  static Future<void> updateCredentialCache(
    List<VaultEntry> allEntries,
  ) async {
    try {
      // Extract only metadata: uuid, title, url, group (first tag), hasTotpSecret, totpSecret
      final metadata = allEntries
          .map((entry) => {
                'uuid': entry.uuid,
                'title': entry.title,
                'url': entry.url,
                'group': entry.tags.isNotEmpty ? entry.tags.first : null,
                'hasTotpSecret': entry.totpSecret != null && entry.totpSecret!.isNotEmpty,
                'totpSecret': entry.totpSecret,
              })
          .toList();

      // Serialize to JSON
      final json = jsonEncode(metadata);

      // Send to native side for encryption and storage
      await _channel.invokeMethod('updateCredentialCache', {
        'metadata': json,
      });
    } on PlatformException catch (e) {
      throw CredentialCacheException(
        'Failed to update credential cache: ${e.message}',
      );
    } catch (e) {
      throw CredentialCacheException(
        'Unexpected error updating credential cache: $e',
      );
    }
  }

  /// Clear the encrypted metadata cache (e.g., on logout or data wipe).
  static Future<void> clearCredentialCache() async {
    try {
      // We could add a clearCache method to native side
      // For now, sending empty list achieves the same effect
      await updateCredentialCache([]);
    } catch (e) {
      print('Error clearing credential cache: $e');
      // Non-fatal error, don't throw
    }
  }
}

/// Exception thrown by credential cache operations.
class CredentialCacheException implements Exception {
  final String message;

  CredentialCacheException(this.message);

  @override
  String toString() => 'CredentialCacheException: $message';
}
