// Pins the file rule of the scoped-redirect example, as in an app with one
// package per feature: each module lives in its own file, modules never
// import each other, and only app_module.dart imports modules.
//
// It also pins that no example file reads runtimeType: a release web build
// minifies type names, so every name the example shows is a label.
//
// It reads the sources with dart:io; `flutter test` runs from the package
// root, so the paths below are relative to it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const moduleDir = 'lib/coordinator_redirect';
const appModule = '$moduleDir/app_module.dart';
const entryPoint = 'lib/main_coordinator_redirect.dart';

/// One import, export or part directive: the file it is in and its URI.
class Directive {
  const Directive(this.file, this.keyword, this.uri);

  final String file;
  final String keyword;
  final String uri;

  @override
  String toString() => "$file: $keyword '$uri'";
}

/// The directives of [source], in order.
///
/// Reads each `import`, `export` or `part` directive up to its semicolon, so a
/// directive split over lines (a `show` list, a conditional import) is
/// covered. Every quoted URI in a directive counts.
List<Directive> directivesOf(String file, String source) => [
  for (final directive in RegExp(
    r'^\s*(import|export|part)\s+([^;]*);',
    multiLine: true,
  ).allMatches(source))
    for (final uri in RegExp(
      r'''['"]([^'"]+)['"]''',
    ).allMatches(directive.group(2)!))
      Directive(file, directive.group(1)!, uri.group(1)!),
];

/// Whether a module file may use [directive]: only `dart:`,
/// `package:flutter/` and `package:zenrouter/`.
bool moduleMayUse(Directive directive) =>
    directive.uri.startsWith('dart:') ||
    directive.uri.startsWith('package:flutter/') ||
    directive.uri.startsWith('package:zenrouter/');

/// The file [directive] points to, relative to the package root, or null when
/// it points outside this package.
String? localTarget(Directive directive) {
  const self = 'package:example/';
  if (directive.uri.startsWith(self)) {
    return 'lib/${directive.uri.substring(self.length)}';
  }
  if (Uri.parse(directive.uri).hasScheme) return null;
  return Uri.parse(directive.file).resolve(directive.uri).path;
}

List<String> dartFilesUnder(String dir) => [
  for (final entity in Directory(dir).listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart'))
      entity.path.replaceAll(r'\', '/'),
]..sort();

List<Directive> directivesIn(String file) =>
    directivesOf(file, File(file).readAsStringSync());

/// [line] without its `//` comment. A `//` inside a quoted string, such as a
/// URL, does not start one.
String codeOf(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote != null) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = null;
      }
    } else if (char == "'" || char == '"') {
      quote = char;
    } else if (line.startsWith('//', i)) {
      return line.substring(0, i);
    }
  }
  return line;
}

/// Every line of [source] whose code matches URL segments by hand, as
/// `file:line: code`. Comments do not count.
List<String> handParsingOf(String file, String source) => [
  for (final (index, line) in source.split('\n').indexed)
    if (RegExp(r'\bpathSegments\b').hasMatch(codeOf(line)))
      '$file:${index + 1}: ${line.trim()}',
];

/// Every line of [source] whose code reads `runtimeType`, as
/// `file:line: code`. Comments do not count.
List<String> runtimeTypeUsesOf(String file, String source) => [
  for (final (index, line) in source.split('\n').indexed)
    if (RegExp(r'\bruntimeType\b').hasMatch(codeOf(line)))
      '$file:${index + 1}: ${line.trim()}',
];

void main() {
  // Every file next to app_module.dart, in any subfolder, is a module file,
  // whatever its name. The first test fails on a new file there until it is
  // classified.
  final moduleFiles = [
    for (final file in dartFilesUnder(moduleDir))
      if (file != appModule) file,
  ];

  test('the example has one file per module next to app_module.dart, and '
      'nothing else', () {
    expect(File(entryPoint).existsSync(), isTrue);
    expect(
      dartFilesUnder(moduleDir),
      [
        appModule,
        '$moduleDir/auth_module.dart',
        '$moduleDir/feed_module.dart',
        '$moduleDir/security_module.dart',
        '$moduleDir/shop_module.dart',
      ],
      reason:
          'Every file in $moduleDir is app_module.dart or one module; '
          'classify a new file here.',
    );
  });

  test('a module file imports and exports only dart:, package:flutter/ and '
      'package:zenrouter/', () {
    final violations = [
      for (final file in moduleFiles)
        for (final directive in directivesIn(file))
          if (!moduleMayUse(directive)) '$directive',
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'A module never imports a sibling module, another file of the '
          'example or app_module.dart:\n${violations.join('\n')}',
    );
  });

  test('no file under lib/ imports app_module.dart except the entry point', () {
    final violations = [
      for (final file in dartFilesUnder('lib'))
        if (file != entryPoint)
          for (final directive in directivesIn(file))
            if (localTarget(directive) == appModule) '$directive',
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'Only $entryPoint may import $appModule:\n${violations.join('\n')}',
    );
  });

  test('no file under lib/ imports a module file except app_module.dart', () {
    final violations = [
      for (final file in dartFilesUnder('lib'))
        if (file != appModule)
          for (final directive in directivesIn(file))
            if (moduleFiles.contains(localTarget(directive))) '$directive',
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'Only $appModule may import a module file; every other file reaches '
          'a module through it:\n${violations.join('\n')}',
    );
  });

  test('app_module.dart imports every module file', () {
    final imported = {
      for (final directive in directivesIn(appModule))
        if (directive.keyword == 'import') localTarget(directive),
    };
    final missing = [
      for (final file in moduleFiles)
        if (!imported.contains(file)) '$appModule does not import $file',
    ];
    expect(missing, isEmpty, reason: missing.join('\n'));
  });

  test('the entry point imports app_module.dart and nothing else from the '
      'example', () {
    final local = [
      for (final directive in directivesIn(entryPoint))
        if (localTarget(directive) != null) localTarget(directive),
    ];
    expect(local, [appModule], reason: '$entryPoint imports $local');
  });

  test('the checks catch a sibling import, an example import and an '
      'app_module import, and name the file and the import', () {
    const file = '$moduleDir/feed_module.dart';
    const source = '''
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';
import 'auth_module.dart';
export 'package:example/main.dart';
import '../coordinator_redirect/app_module.dart'
    show AppCoordinator;
// import 'shop_module.dart';
''';
    final directives = directivesOf(file, source);

    expect(
      [
        for (final directive in directives)
          if (!moduleMayUse(directive)) '$directive',
      ],
      [
        "$file: import 'auth_module.dart'",
        "$file: export 'package:example/main.dart'",
        "$file: import '../coordinator_redirect/app_module.dart'",
      ],
    );
    expect(directives.map(localTarget), [
      null,
      null,
      null,
      '$moduleDir/auth_module.dart',
      'lib/main.dart',
      appModule,
    ]);
  });

  test('every file in $moduleDir declares its routing as a RouteManifest, '
      'and none matches URL segments by hand', () {
    for (final file in dartFilesUnder(moduleDir)) {
      final source = File(file).readAsStringSync();
      expect(
        source,
        contains('static final manifest = RouteManifest<'),
        reason: '$file owns its routing graph',
      );
      expect(
        handParsingOf(file, source),
        isEmpty,
        reason:
            'A manifest matches URLs and builds them back; a switch on '
            'pathSegments is a second source of truth.',
      );
    }
  });

  test('the hand-parsing check names the file and the line, and skips '
      'comments', () {
    const file = '$moduleDir/shop_module.dart';
    const source = '''
// A comment may say pathSegments.
return switch (uri.pathSegments) {
final manifest = RouteManifest<ShopRouteId>(name: 'shop');
''';

    expect(handParsingOf(file, source), [
      '$file:2: return switch (uri.pathSegments) {',
    ]);
  });

  test('no file in $moduleDir reads runtimeType: a release web build '
      'minifies type names, so every name on screen is a label', () {
    final uses = [
      for (final file in dartFilesUnder(moduleDir))
        ...runtimeTypeUsesOf(file, File(file).readAsStringSync()),
    ];
    expect(
      uses,
      isEmpty,
      reason:
          'A name read from runtimeType shows as minified:… in a release web '
          'build; show a label instead:\n${uses.join('\n')}',
    );
  });

  test('the runtimeType check names the file and the line, and skips '
      'comments', () {
    const file = '$moduleDir/feed_module.dart';
    const source = '''
// A comment may say runtimeType.
/// So may a doc comment: [Object.runtimeType].
final name = route.runtimeType.toString();
final url = 'http://example.com/'; final type = module.runtimeType;
final label = 'ProfileRoute'; // a label, not runtimeType
final runtimeTypeName = 'a longer identifier';
''';

    expect(runtimeTypeUsesOf(file, source), [
      '$file:3: final name = route.runtimeType.toString();',
      "$file:4: final url = 'http://example.com/'; final type = "
          'module.runtimeType;',
    ]);
  });
}
