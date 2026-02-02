/// Auto-bullet detection and continuation logic (Google Keep style)
class AutoBullet {
  /// Detects a bullet prefix at the start of a line.
  /// Supported: -, *, 1., 2., a., b., A., B., i., ii., I., II. etc.
  /// Returns the full prefix including trailing space, or null if none found.
  static String? detectBulletPrefix(String line) {
    // Check dash/asterisk bullets: "- " or "* "
    final dashMatch = RegExp(r'^(\s*[-*]\s)').firstMatch(line);
    if (dashMatch != null) return dashMatch.group(1);

    // Check numbered bullets: "1. ", "12. "
    final numMatch = RegExp(r'^(\s*\d+\.\s)').firstMatch(line);
    if (numMatch != null) return numMatch.group(1);

    // Check lowercase letter bullets: "a. ", "b. "
    final lowerMatch = RegExp(r'^(\s*[a-z]\.\s)').firstMatch(line);
    if (lowerMatch != null) return lowerMatch.group(1);

    // Check uppercase letter bullets: "A. ", "B. "
    final upperMatch = RegExp(r'^(\s*[A-Z]\.\s)').firstMatch(line);
    if (upperMatch != null) return upperMatch.group(1);

    // Check lowercase roman numeral bullets: "i. ", "ii. ", "iii. ", "iv. "
    final romanLowerMatch = RegExp(r'^(\s*[ivxlcdm]+\.\s)').firstMatch(line);
    if (romanLowerMatch != null) {
      final candidate = romanLowerMatch.group(1)!;
      final romanPart = candidate.trim().replaceAll('. ', '').replaceAll('.', '');
      if (_parseRomanNumeral(romanPart.toUpperCase()) != null) {
        return candidate;
      }
    }

    // Check uppercase roman numeral bullets: "I. ", "II. ", "III. ", "IV. "
    final romanUpperMatch = RegExp(r'^(\s*[IVXLCDM]+\.\s)').firstMatch(line);
    if (romanUpperMatch != null) {
      final candidate = romanUpperMatch.group(1)!;
      final romanPart = candidate.trim().replaceAll('. ', '').replaceAll('.', '');
      if (_parseRomanNumeral(romanPart) != null) {
        return candidate;
      }
    }

    return null;
  }

  /// Returns the next bullet string given a current prefix.
  /// For "- ", returns "- ". For "1. ", returns "2. ". For "a. ", returns "b. ".
  static String getNextBullet(String prefix) {
    final trimmed = prefix.trimLeft();
    final leadingWhitespace = prefix.substring(0, prefix.length - prefix.trimLeft().length);

    // Dash/asterisk: same prefix
    if (trimmed.startsWith('-') || trimmed.startsWith('*')) {
      return prefix;
    }

    // Numbered: increment
    final numMatch = RegExp(r'^(\d+)\.\s$').firstMatch(trimmed);
    if (numMatch != null) {
      final num = int.parse(numMatch.group(1)!);
      return '$leadingWhitespace${num + 1}. ';
    }

    // Lowercase letter: increment
    final lowerMatch = RegExp(r'^([a-z])\.\s$').firstMatch(trimmed);
    if (lowerMatch != null) {
      final char = lowerMatch.group(1)!;
      if (char != 'z') {
        return '$leadingWhitespace${String.fromCharCode(char.codeUnitAt(0) + 1)}. ';
      }
      return prefix; // wrap around not needed
    }

    // Uppercase letter: increment
    final upperMatch = RegExp(r'^([A-Z])\.\s$').firstMatch(trimmed);
    if (upperMatch != null) {
      final char = upperMatch.group(1)!;
      if (char != 'Z') {
        return '$leadingWhitespace${String.fromCharCode(char.codeUnitAt(0) + 1)}. ';
      }
      return prefix;
    }

    // Lowercase roman numeral: increment
    final romanLowerMatch = RegExp(r'^([ivxlcdm]+)\.\s$').firstMatch(trimmed);
    if (romanLowerMatch != null) {
      final roman = romanLowerMatch.group(1)!;
      final value = _parseRomanNumeral(roman.toUpperCase());
      if (value != null) {
        final next = _toRomanNumeral(value + 1);
        if (next != null) {
          return '$leadingWhitespace${next.toLowerCase()}. ';
        }
      }
    }

    // Uppercase roman numeral: increment
    final romanUpperMatch = RegExp(r'^([IVXLCDM]+)\.\s$').firstMatch(trimmed);
    if (romanUpperMatch != null) {
      final roman = romanUpperMatch.group(1)!;
      final value = _parseRomanNumeral(roman);
      if (value != null) {
        final next = _toRomanNumeral(value + 1);
        if (next != null) {
          return '$leadingWhitespace$next. ';
        }
      }
    }

    return prefix;
  }

  /// Checks if a line is an empty bullet (just the prefix, no actual text content)
  static bool isEmptyBullet(String line) {
    final prefix = detectBulletPrefix(line);
    if (prefix == null) return false;
    return line.trimRight() == prefix.trimRight();
  }

  /// Parse a Roman numeral string to an integer (I=1, V=5, X=10, etc.)
  static int? _parseRomanNumeral(String s) {
    if (s.isEmpty) return null;

    final values = <String, int>{
      'I': 1, 'V': 5, 'X': 10, 'L': 50,
      'C': 100, 'D': 500, 'M': 1000,
    };

    int result = 0;
    for (int i = 0; i < s.length; i++) {
      final current = values[s[i]];
      if (current == null) return null;

      if (i + 1 < s.length) {
        final next = values[s[i + 1]];
        if (next != null && current < next) {
          result -= current;
        } else {
          result += current;
        }
      } else {
        result += current;
      }
    }

    // Validate by converting back
    final check = _toRomanNumeral(result);
    if (check?.toUpperCase() != s.toUpperCase()) return null;

    return result;
  }

  /// Convert an integer to a Roman numeral string
  static String? _toRomanNumeral(int num) {
    if (num <= 0 || num > 3999) return null;

    final pairs = [
      (1000, 'M'), (900, 'CM'), (500, 'D'), (400, 'CD'),
      (100, 'C'), (90, 'XC'), (50, 'L'), (40, 'XL'),
      (10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I'),
    ];

    final buffer = StringBuffer();
    var remaining = num;

    for (final (value, symbol) in pairs) {
      while (remaining >= value) {
        buffer.write(symbol);
        remaining -= value;
      }
    }

    return buffer.toString();
  }
}
