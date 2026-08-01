import 'package:markdown/markdown.dart' as md;

const wikiLinkElement = 'gitvault-wiki-link';
const blockReferenceElement = 'gitvault-block-reference';
const blockAnchorElement = 'gitvault-block-anchor';

List<md.InlineSyntax> knowledgeInlineSyntaxes() => <md.InlineSyntax>[
      // Custom syntaxes are evaluated before Markdown defaults. Parse code
      // spans first so knowledge syntax inside backticks remains literal.
      md.CodeSyntax(),
      WikiLinkSyntax(),
      BlockReferenceSyntax(),
      BlockAnchorSyntax(),
    ];

class WikiLinkSyntax extends md.InlineSyntax {
  WikiLinkSyntax()
      : super(
          r'\[\[([^\]\n]{1,500})\]\]',
          startCharacter: 0x5b,
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match[1]!.trim();
    if (raw.isEmpty) return false;

    final separator = raw.indexOf('|');
    final destination =
        (separator < 0 ? raw : raw.substring(0, separator)).trim();
    final label = (separator < 0 ? raw : raw.substring(separator + 1)).trim();
    if (destination.isEmpty) return false;

    final headingSeparator = destination.indexOf('#');
    final target = (headingSeparator < 0
            ? destination
            : destination.substring(0, headingSeparator))
        .trim();
    final heading = headingSeparator < 0
        ? ''
        : destination.substring(headingSeparator + 1).trim();
    if (target.isEmpty) return false;

    final element = md.Element.text(
      wikiLinkElement,
      label.isEmpty ? destination : label,
    )
      ..attributes['target'] = target
      ..attributes['heading'] = heading;
    parser.addNode(element);
    return true;
  }
}

class BlockReferenceSyntax extends md.InlineSyntax {
  BlockReferenceSyntax()
      : super(
          r'\(\(([A-Za-z0-9][A-Za-z0-9_-]{0,99})\)\)',
          startCharacter: 0x28,
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final id = match[1]!;
    parser.addNode(
      md.Element.text(blockReferenceElement, id)..attributes['id'] = id,
    );
    return true;
  }
}

class BlockAnchorSyntax extends md.InlineSyntax {
  BlockAnchorSyntax()
      : super(
          r'\^([A-Za-z0-9][A-Za-z0-9_-]{0,99})(?=[ \t]*$)',
          startCharacter: 0x5e,
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final id = match[1]!;
    parser.addNode(
      md.Element.text(blockAnchorElement, id)..attributes['id'] = id,
    );
    return true;
  }
}
