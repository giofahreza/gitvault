import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/notes/knowledge_index.dart';
import '../../core/notes/knowledge_syntax.dart';

typedef WikiLinkTap = Future<void> Function(String target, String? heading);
typedef BlockReferenceTap = Future<void> Function(String blockId);
typedef ExternalLinkTap = Future<void> Function(String href);

class KnowledgeMarkdownView extends StatelessWidget {
  final String data;
  final KnowledgeIndex? knowledgeIndex;
  final WikiLinkTap onWikiLink;
  final BlockReferenceTap onBlockReference;
  final ExternalLinkTap onExternalLink;
  final Color textColor;
  final Color linkColor;

  const KnowledgeMarkdownView({
    super.key,
    required this.data,
    required this.onWikiLink,
    required this.onBlockReference,
    required this.onExternalLink,
    required this.textColor,
    required this.linkColor,
    this.knowledgeIndex,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = MarkdownStyleSheet.fromTheme(theme);
    final styleSheet = base.copyWith(
      p: base.p?.copyWith(color: textColor, fontSize: 16, height: 1.45),
      h1: base.h1?.copyWith(color: textColor, letterSpacing: 0),
      h2: base.h2?.copyWith(color: textColor, letterSpacing: 0),
      h3: base.h3?.copyWith(color: textColor, letterSpacing: 0),
      h4: base.h4?.copyWith(color: textColor, letterSpacing: 0),
      h5: base.h5?.copyWith(color: textColor, letterSpacing: 0),
      h6: base.h6?.copyWith(color: textColor, letterSpacing: 0),
      a: base.a?.copyWith(color: linkColor),
      listBullet: base.listBullet?.copyWith(color: textColor),
      code: base.code?.copyWith(
        color: textColor,
        backgroundColor: textColor.withValues(alpha: 0.08),
      ),
      blockquote: base.blockquote?.copyWith(color: textColor),
      blockquoteDecoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.06),
        border: Border(left: BorderSide(color: linkColor, width: 3)),
      ),
    );

    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: styleSheet,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: knowledgeInlineSyntaxes(),
      softLineBreak: true,
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      builders: {
        wikiLinkElement: _WikiLinkBuilder(
          color: linkColor,
          onTap: onWikiLink,
        ),
        blockReferenceElement: _BlockReferenceBuilder(
          color: linkColor,
          index: knowledgeIndex,
          onTap: onBlockReference,
        ),
        blockAnchorElement: _BlockAnchorBuilder(color: textColor),
      },
      imageBuilder: (uri, title, alt) => Tooltip(
        message: uri.toString(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                size: 16, color: textColor,),
            const SizedBox(width: 6),
            Text(
              alt ?? 'Remote image blocked',
              style: TextStyle(color: textColor),
            ),
          ],
        ),
      ),
      onTapLink: (text, href, title) {
        if (href != null) unawaited(onExternalLink(href));
      },
    );
  }
}

class _WikiLinkBuilder extends MarkdownElementBuilder {
  final Color color;
  final WikiLinkTap onTap;

  _WikiLinkBuilder({required this.color, required this.onTap});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final target = element.attributes['target']!;
    final headingValue = element.attributes['heading'];
    final heading =
        headingValue == null || headingValue.isEmpty ? null : headingValue;
    return Tooltip(
      message: heading == null ? target : '$target#$heading',
      child: InkWell(
        onTap: () => unawaited(onTap(target, heading)),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            element.textContent,
            style:
                (parentStyle ?? preferredStyle ?? const TextStyle()).copyWith(
              color: color,
              decoration: TextDecoration.underline,
              decorationColor: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockReferenceBuilder extends MarkdownElementBuilder {
  final Color color;
  final KnowledgeIndex? index;
  final BlockReferenceTap onTap;

  _BlockReferenceBuilder({
    required this.color,
    required this.index,
    required this.onTap,
  });

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final id = element.attributes['id']!;
    final matches = index?.resolveBlock(id) ?? const <NoteBlockLocation>[];
    final label = matches.length == 1
        ? matches.single.block.text
        : matches.isEmpty
            ? 'Missing block: $id'
            : 'Ambiguous block: $id';
    return Tooltip(
      message: '^$id',
      child: InkWell(
        onTap: () => unawaited(onTap(id)),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.subdirectory_arrow_right, size: 15, color: color),
              const SizedBox(width: 3),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.7,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (parentStyle ?? preferredStyle ?? const TextStyle())
                      .copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlockAnchorBuilder extends MarkdownElementBuilder {
  final Color color;

  _BlockAnchorBuilder({required this.color});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final id = element.attributes['id']!;
    return Tooltip(
      message: 'Block anchor ^$id',
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Icon(
          Icons.link,
          size: 13,
          color: color.withValues(alpha: 0.65),
        ),
      ),
    );
  }
}
