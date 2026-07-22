import 'package:flutter/material.dart';

class GroupSelectorField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Iterable<String> availableGroups;
  final bool enabled;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final String labelText;
  final String hintText;

  const GroupSelectorField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.availableGroups,
    this.enabled = true,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.labelText = 'Group (optional)',
    this.hintText = 'Select or create a group',
  });

  @override
  Widget build(BuildContext context) {
    final groups = _normalizedGroups(availableGroups);

    return RawAutocomplete<_GroupOption>(
      textEditingController: controller,
      focusNode: focusNode,
      displayStringForOption: (option) => option.value,
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.trim();
        final normalizedQuery = query.toLowerCase();
        final matches = normalizedQuery.isEmpty
            ? groups
            : groups
                .where(
                  (group) => group.toLowerCase().contains(normalizedQuery),
                )
                .toList();
        final exactMatch = normalizedQuery.isNotEmpty &&
            groups.any((group) => group.toLowerCase() == normalizedQuery);

        return <_GroupOption>[
          if (query.isNotEmpty && !exactMatch) _GroupOption.create(query),
          ...matches.map(_GroupOption.existing),
        ];
      },
      onSelected: (option) {
        final value = option.value.trim();
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      },
      fieldViewBuilder: (
        context,
        fieldController,
        fieldFocusNode,
        onFieldSubmitted,
      ) {
        return TextFormField(
          controller: fieldController,
          focusNode: fieldFocusNode,
          decoration: InputDecoration(
            labelText: labelText,
            hintText: hintText,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.folder_outlined),
            suffixIcon: ExcludeFocus(
              child: IconButton(
                tooltip: 'Show groups',
                icon: const Icon(Icons.arrow_drop_down),
                onPressed: enabled
                    ? () {
                        fieldFocusNode.requestFocus();
                      }
                    : null,
              ),
            ),
          ),
          enabled: enabled,
          textCapitalization: TextCapitalization.words,
          textInputAction: textInputAction,
          onFieldSubmitted: (value) {
            onFieldSubmitted();
            onSubmitted?.call(value);
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final optionList = options.toList(growable: false);
        final viewportWidth = MediaQuery.sizeOf(context).width;
        final menuWidth = viewportWidth >= 480
            ? 360.0
            : (viewportWidth - 48).clamp(240.0, 360.0).toDouble();

        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: menuWidth,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: optionList.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final option = optionList[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        option.isCreate
                            ? Icons.add_circle_outline
                            : Icons.folder_outlined,
                      ),
                      title: Text(
                        option.isCreate
                            ? 'Create "${option.value}"'
                            : option.value,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static List<String> _normalizedGroups(Iterable<String> groups) {
    final seen = <String>{};
    final normalized = <String>[];

    for (final rawGroup in groups) {
      final group = rawGroup.trim();
      if (group.isEmpty) continue;

      final key = group.toLowerCase();
      if (seen.add(key)) {
        normalized.add(group);
      }
    }

    normalized.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return normalized;
  }
}

class _GroupOption {
  final String value;
  final bool isCreate;

  const _GroupOption._({
    required this.value,
    required this.isCreate,
  });

  factory _GroupOption.existing(String value) {
    return _GroupOption._(value: value, isCreate: false);
  }

  factory _GroupOption.create(String value) {
    return _GroupOption._(value: value, isCreate: true);
  }
}
