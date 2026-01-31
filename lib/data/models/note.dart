import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import '../../core/theme/note_colors.dart';

part 'note.freezed.dart';
part 'note.g.dart';

@freezed
class ChecklistItem with _$ChecklistItem {
  const factory ChecklistItem({
    required String text,
    @Default(false) bool isChecked,
  }) = _ChecklistItem;

  factory ChecklistItem.fromJson(Map<String, dynamic> json) =>
      _$ChecklistItemFromJson(json);
}

@freezed
class Note with _$Note {
  const factory Note({
    required String uuid,
    required String title,
    required String content,
    @Default(NoteColor.white) NoteColor color,
    @Default(false) bool isPinned,
    @Default([]) List<String> tags,
    @Default(false) bool isChecklist,
    @Default([]) List<ChecklistItem> checklistItems,
    required DateTime createdAt,
    required DateTime modifiedAt,
  }) = _Note;

  factory Note.fromJson(Map<String, dynamic> json) => _$NoteFromJson(json);
}

enum NoteColor {
  white,
  red,
  orange,
  yellow,
  green,
  teal,
  blue,
  purple,
  pink,
  brown,
  gray;

  /// Legacy color value getter for backwards compatibility
  /// Returns light theme colors only
  int get colorValue {
    switch (this) {
      case NoteColor.white:
        return 0xFFFFFFFF;
      case NoteColor.red:
        return 0xFFF28B82;
      case NoteColor.orange:
        return 0xFFFBBC04;
      case NoteColor.yellow:
        return 0xFFFFF475;
      case NoteColor.green:
        return 0xFFCCFF90;
      case NoteColor.teal:
        return 0xFFA7FFEB;
      case NoteColor.blue:
        return 0xFFCBF0F8;
      case NoteColor.purple:
        return 0xFFAECBFA;
      case NoteColor.pink:
        return 0xFFFDCFE8;
      case NoteColor.brown:
        return 0xFFE6C9A8;
      case NoteColor.gray:
        return 0xFFE8EAED;
    }
  }

  /// Get color index for NoteColorPalette
  int get colorIndex {
    switch (this) {
      case NoteColor.white:
        return 0;
      case NoteColor.red:
        return 1;
      case NoteColor.orange:
        return 2;
      case NoteColor.yellow:
        return 3;
      case NoteColor.green:
        return 4;
      case NoteColor.teal:
        return 5;
      case NoteColor.blue:
        return 7;
      case NoteColor.purple:
        return 8;
      case NoteColor.pink:
        return 9;
      case NoteColor.brown:
        return 10;
      case NoteColor.gray:
        return 6; // Maps to cyan in the palette
    }
  }

  /// Get the appropriate color for the current brightness
  Color getColorForBrightness(Brightness brightness) {
    return NoteColorPalette.getColor(colorIndex, brightness);
  }
}

extension NoteExtension on Note {
  String toJsonString() => jsonEncode(toJson());

  /// Get background color for this note based on brightness
  Color getBackgroundColor(Brightness brightness) {
    return color.getColorForBrightness(brightness);
  }

  /// Get text color for this note based on brightness
  Color getTextColor(Brightness brightness) {
    return NoteColorPalette.getTextColor(color.colorIndex, brightness);
  }

  /// Get border color for this note based on brightness
  Color getBorderColor(Brightness brightness) {
    return NoteColorPalette.getBorderColor(color.colorIndex, brightness);
  }
}
