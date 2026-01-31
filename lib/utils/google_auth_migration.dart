import 'dart:convert';
import 'dart:typed_data';

/// Parses Google Authenticator export data from otpauth-migration:// URIs
/// Google Authenticator uses a simple protobuf format for batch export
class GoogleAuthMigration {
  /// Parse the migration URI and extract all TOTP accounts
  static List<MigrationAccount> parseMigrationUri(String uri) {
    // Format: otpauth-migration://offline?data=<base64>
    final parsed = Uri.parse(uri);
    final data = parsed.queryParameters['data'];
    if (data == null || data.isEmpty) return [];

    final bytes = base64Decode(data);
    return _parseProtobuf(bytes);
  }

  /// Manually decode the protobuf structure
  /// The Google Authenticator migration protobuf schema:
  /// message MigrationPayload {
  ///   repeated OtpParameters otp_parameters = 1;
  /// }
  /// message OtpParameters {
  ///   bytes secret = 1;
  ///   string name = 2;
  ///   string issuer = 3;
  ///   Algorithm algorithm = 4; // enum: 0=unspec, 1=SHA1, 2=SHA256, 3=SHA512
  ///   DigitCount digits = 5;   // enum: 0=unspec, 1=SIX, 2=EIGHT
  ///   OtpType type = 6;        // enum: 0=unspec, 1=HOTP, 2=TOTP
  /// }
  static List<MigrationAccount> _parseProtobuf(Uint8List bytes) {
    final accounts = <MigrationAccount>[];
    int offset = 0;

    while (offset < bytes.length) {
      // Read field tag
      final tagResult = _readVarint(bytes, offset);
      if (tagResult == null) break;
      final tag = tagResult.value;
      offset = tagResult.nextOffset;

      final fieldNumber = tag >> 3;
      final wireType = tag & 0x7;

      if (fieldNumber == 1 && wireType == 2) {
        // Length-delimited: embedded OtpParameters message
        final lenResult = _readVarint(bytes, offset);
        if (lenResult == null) break;
        final len = lenResult.value;
        offset = lenResult.nextOffset;

        if (offset + len > bytes.length) break;
        final subBytes = bytes.sublist(offset, offset + len);
        offset += len;

        final account = _parseOtpParameters(Uint8List.fromList(subBytes));
        if (account != null) {
          accounts.add(account);
        }
      } else {
        // Skip unknown fields
        offset = _skipField(bytes, offset, wireType);
        if (offset < 0) break;
      }
    }

    return accounts;
  }

  static MigrationAccount? _parseOtpParameters(Uint8List bytes) {
    Uint8List? secret;
    String name = '';
    String issuer = '';
    int algorithm = 0;
    int digits = 0;
    int type = 0;
    int offset = 0;

    while (offset < bytes.length) {
      final tagResult = _readVarint(bytes, offset);
      if (tagResult == null) break;
      final tag = tagResult.value;
      offset = tagResult.nextOffset;

      final fieldNumber = tag >> 3;
      final wireType = tag & 0x7;

      switch (fieldNumber) {
        case 1: // secret (bytes)
          if (wireType == 2) {
            final lenResult = _readVarint(bytes, offset);
            if (lenResult == null) return null;
            final len = lenResult.value;
            offset = lenResult.nextOffset;
            if (offset + len > bytes.length) return null;
            secret = bytes.sublist(offset, offset + len);
            offset += len;
          }
          break;
        case 2: // name (string)
          if (wireType == 2) {
            final lenResult = _readVarint(bytes, offset);
            if (lenResult == null) return null;
            final len = lenResult.value;
            offset = lenResult.nextOffset;
            if (offset + len > bytes.length) return null;
            name = utf8.decode(bytes.sublist(offset, offset + len));
            offset += len;
          }
          break;
        case 3: // issuer (string)
          if (wireType == 2) {
            final lenResult = _readVarint(bytes, offset);
            if (lenResult == null) return null;
            final len = lenResult.value;
            offset = lenResult.nextOffset;
            if (offset + len > bytes.length) return null;
            issuer = utf8.decode(bytes.sublist(offset, offset + len));
            offset += len;
          }
          break;
        case 4: // algorithm (varint)
          if (wireType == 0) {
            final valResult = _readVarint(bytes, offset);
            if (valResult == null) return null;
            algorithm = valResult.value;
            offset = valResult.nextOffset;
          }
          break;
        case 5: // digits (varint)
          if (wireType == 0) {
            final valResult = _readVarint(bytes, offset);
            if (valResult == null) return null;
            digits = valResult.value;
            offset = valResult.nextOffset;
          }
          break;
        case 6: // type (varint)
          if (wireType == 0) {
            final valResult = _readVarint(bytes, offset);
            if (valResult == null) return null;
            type = valResult.value;
            offset = valResult.nextOffset;
          }
          break;
        default:
          offset = _skipField(bytes, offset, wireType);
          if (offset < 0) return null;
      }
    }

    if (secret == null || secret.isEmpty) return null;

    // Parse name: can be "issuer:account" or just "account"
    String account = name;
    if (name.contains(':')) {
      final parts = name.split(':');
      if (issuer.isEmpty) issuer = parts[0].trim();
      account = parts.length > 1 ? parts[1].trim() : name;
    }

    return MigrationAccount(
      secret: _bytesToBase32(secret),
      name: account,
      issuer: issuer,
      algorithm: _algorithmToString(algorithm),
      digits: _digitsToInt(digits),
      type: type == 1 ? 'hotp' : 'totp',
    );
  }

  static _VarintResult? _readVarint(Uint8List bytes, int offset) {
    int result = 0;
    int shift = 0;

    while (offset < bytes.length) {
      final byte = bytes[offset];
      result |= (byte & 0x7F) << shift;
      offset++;
      if ((byte & 0x80) == 0) {
        return _VarintResult(result, offset);
      }
      shift += 7;
      if (shift >= 64) return null;
    }

    return null;
  }

  static int _skipField(Uint8List bytes, int offset, int wireType) {
    switch (wireType) {
      case 0: // varint
        while (offset < bytes.length) {
          if ((bytes[offset] & 0x80) == 0) return offset + 1;
          offset++;
        }
        return -1;
      case 1: // 64-bit
        return offset + 8;
      case 2: // length-delimited
        final lenResult = _readVarint(bytes, offset);
        if (lenResult == null) return -1;
        return lenResult.nextOffset + lenResult.value;
      case 5: // 32-bit
        return offset + 4;
      default:
        return -1;
    }
  }

  static String _bytesToBase32(Uint8List bytes) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final result = StringBuffer();
    int bits = 0;
    int value = 0;

    for (final byte in bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        result.write(alphabet[(value >> bits) & 0x1F]);
      }
    }

    if (bits > 0) {
      result.write(alphabet[(value << (5 - bits)) & 0x1F]);
    }

    return result.toString();
  }

  static String _algorithmToString(int algo) {
    switch (algo) {
      case 1: return 'SHA1';
      case 2: return 'SHA256';
      case 3: return 'SHA512';
      default: return 'SHA1';
    }
  }

  static int _digitsToInt(int digits) {
    switch (digits) {
      case 2: return 8;
      default: return 6;
    }
  }
}

class _VarintResult {
  final int value;
  final int nextOffset;
  _VarintResult(this.value, this.nextOffset);
}

/// Represents a single TOTP account extracted from Google Authenticator export
class MigrationAccount {
  final String secret;
  final String name;
  final String issuer;
  final String algorithm;
  final int digits;
  final String type;

  MigrationAccount({
    required this.secret,
    required this.name,
    required this.issuer,
    required this.algorithm,
    required this.digits,
    required this.type,
  });

  String get displayName => issuer.isNotEmpty ? '$issuer ($name)' : name;
}
