// Tests for RouteModuleTree: the capability-agnostic module tree a
// coordinator holds, which redirect rules ask through their internal
// extensions. They drive the tree directly and pin identities and exact
// lists.

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/src/coordinator/base.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

import '../support/harness.dart';

// ===========================================================================
// Modules
// ===========================================================================

/// A plain module that lists exactly [listed].
class ListsA extends FeatureModule {
  ListsA(super.coordinator, this.listed) : super(prefix: 'lists-a');

  final List<StackPath> listed;

  @override
  List<StackPath> get paths => listed;
}

/// A second plain module type that lists exactly [listed].
class ListsB extends FeatureModule {
  ListsB(super.coordinator, this.listed) : super(prefix: 'lists-b');

  final List<StackPath> listed;

  @override
  List<StackPath> get paths => listed;
}

/// A plain module that lists the root stack.
class ListsRoot extends FeatureModule {
  ListsRoot(super.coordinator) : super(prefix: 'lists-root');

  @override
  List<StackPath> get paths => [coordinator.root];
}

/// A declaring module that lists no stack.
class RulesWithoutStack extends ScopedFeature {
  RulesWithoutStack(super.coordinator)
    : super(rules: const [], prefix: 'rules-without-stack');
}

/// A second capability, for tests only: a module mixes it in the way it
/// mixes in [RouteModuleRedirectRule], and the tree scopes it the same way.
mixin TestCapability<T extends RouteUri> on RouteModule<T> {}

/// A module coordinator with the test capability and no redirect rules.
class CapabilityNested extends NestedCoordinator with TestCapability<AppRoute> {
  CapabilityNested(super.parent, {super.childModulesBuilder})
    : super(extraLabel: 'capability');
}

/// A plain module with both the test capability and redirect rules.
class CapabilityAndRules extends ScopedFeature with TestCapability<AppRoute> {
  CapabilityAndRules(super.coordinator, {required super.rules})
    : super(prefix: 'both', hasPath: true);
}

/// Counts the reads of [paths]. Only claiming the stacks reads the root's
/// paths after construction, so this counts how often the tree claims them.
mixin CountsPathReads on CoordinatorCore<AppRoute> {
  int pathsReads = 0;

  @override
  List<StackPath> get paths {
    pathsReads++;
    return super.paths;
  }
}

class CountingApp extends ModularAppCoordinator with CountsPathReads {
  CountingApp({super.modules});
}

class CountingScopedApp extends ScopedModularApp with CountsPathReads {
  CountingScopedApp({required super.rules, super.modules});
}

// ===========================================================================
// Test doubles
// ===========================================================================

/// Only implements the interface, like a hand-written test double.
class InterfaceDouble implements CoordinatorCore<AppRoute> {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers every member it does not implement with `null`, like a mockito
/// mock.
class MockStyleDouble implements CoordinatorCore<AppRoute> {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Only implements the modular interface, handed to a real module as its
/// parent.
class ModularDouble implements CoordinatorModular<AppRoute> {
  ModularDouble(this.root);

  @override
  final StackPath<AppRoute> root;

  @override
  Uri get currentUri => Uri.parse('/');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ===========================================================================
// Fixtures
// ===========================================================================

/// Four levels of module coordinators, plus a plain module on the fourth:
///
/// ```
/// app                                   level 1, the tree root
/// └── l2 (NestedCoordinator)            level 2
///     └── l3 (NestedCoordinator)        level 3
///         ├── l4 (NestedCoordinator)    level 4
///         └── p4 (plain FeatureModule)  level 4
/// ```
///
/// Each level is a `NestedCoordinator`: one type at every level.
typedef Deep = ({
  ModularAppCoordinator app,
  NestedCoordinator l2,
  NestedCoordinator l3,
  NestedCoordinator l4,
  FeatureModule p4,
});

Deep deepTree() {
  late NestedCoordinator l2, l3, l4;
  late FeatureModule p4;
  final app = ModularAppCoordinator(
    modules: (c) => [
      l2 = NestedCoordinator(
        c,
        extraLabel: 'l2',
        childModulesBuilder: (self) => [
          l3 = NestedCoordinator(
            self,
            extraLabel: 'l3',
            childModulesBuilder: (self) => [
              l4 = NestedCoordinator(self, extraLabel: 'l4'),
              p4 = FeatureModule(self, prefix: 'p4', hasPath: true),
            ],
          ),
        ],
      ),
    ],
  );
  return (app: app, l2: l2, l3: l3, l4: l4, p4: p4);
}

/// A wide tree in which two module coordinators of one type sit at two
/// levels:
///
/// ```
/// app                          owns root, nested
/// ├── a  (NestedCoordinator)   owns a
/// │   ├── a1 (plain)           owns a1
/// │   └── a2 (NestedCoordinator, like a)   owns a2
/// │       └── a21 (plain)      owns a21
/// └── b  (plain)               owns b
/// ```
typedef Wide = ({
  ModularAppCoordinator app,
  NestedCoordinator a,
  FeatureModule a1,
  NestedCoordinator a2,
  FeatureModule a21,
  FeatureModule b,
});

Wide wideTree() {
  late NestedCoordinator a, a2;
  late FeatureModule a1, a21, b;
  final app = ModularAppCoordinator(
    modules: (c) => [
      a = NestedCoordinator(
        c,
        extraLabel: 'a',
        childModulesBuilder: (self) => [
          a1 = FeatureModule(self, prefix: 'a1', hasPath: true),
          a2 = NestedCoordinator(
            self,
            extraLabel: 'a2',
            childModulesBuilder: (self) => [
              a21 = FeatureModule(self, prefix: 'a21', hasPath: true),
            ],
          ),
        ],
      ),
      b = FeatureModule(c, prefix: 'b', hasPath: true),
    ],
  );
  return (app: app, a: a, a1: a1, a2: a2, a21: a21, b: b);
}

/// Every topology problem at once:
///
/// - `shared` is listed by the siblings ListsA and ListsB;
/// - ListsRoot lists the root stack;
/// - `detached`, listed by ListsA, has no coordinator;
/// - `foreign`, listed by ListsB, belongs to [other], another tree root.
///
/// With [declaring], a module that mixes in [RouteModuleRedirectRule] and
/// lists no stack is registered too, which opts the tree in.
({
  ModularAppCoordinator app,
  ListsA listsA,
  ListsB listsB,
  ListsRoot listsRoot,
  AppStackPath shared,
  AppStackPath detached,
  AppStackPath foreign,
  AppCoordinator other,
})
problemTree({required bool declaring}) {
  final other = AppCoordinator();
  final foreign = AppStackPath(coordinator: other, debugLabel: 'foreign');
  final detached = AppStackPath(debugLabel: 'detached');
  late AppStackPath shared;
  late ListsA listsA;
  late ListsB listsB;
  late ListsRoot listsRoot;
  final app = ModularAppCoordinator(
    modules: (c) {
      shared = AppStackPath(coordinator: c, debugLabel: 'shared');
      return [
        listsA = ListsA(c, [shared, detached]),
        listsB = ListsB(c, [shared, foreign]),
        listsRoot = ListsRoot(c),
        if (declaring) RulesWithoutStack(c),
      ];
    },
  );
  return (
    app: app,
    listsA: listsA,
    listsB: listsB,
    listsRoot: listsRoot,
    shared: shared,
    detached: detached,
    foreign: foreign,
    other: other,
  );
}

/// The module of each node, in order.
Iterable<RouteModule> modulesOf(Iterable<RouteModuleTreeNode> nodes) =>
    nodes.map((node) => node.module);

void main() {
  group('the tree root', () {
    test(
      'is the same coordinator from every level, a plain module and a path',
      () {
        final d = deepTree();
        // The pointers the walk can start from are erased: a plain module
        // stores its parent's parent, and a module's stack its module's
        // parent.
        expect(d.p4.coordinator, same(d.l2));
        expect(d.l4.extra.coordinator, same(d.l3));

        final starts = <String, CoordinatorCore>{
          'level 1': d.app,
          'level 2': d.l2,
          'level 3': d.l3,
          'level 4': d.l4,
          'the coordinator of a plain module': d.p4.coordinator,
          'the coordinator of a path': d.l4.extra.coordinator!,
        };
        for (final MapEntry(key: from, value: start) in starts.entries) {
          expect(RouteModuleTree.rootOf(start), same(d.app), reason: from);
        }

        final tree = RouteModuleTree.of(d.app)!;
        expect(tree.root, same(d.app));
        for (final MapEntry(key: from, value: start) in starts.entries) {
          expect(RouteModuleTree.of(start), same(tree), reason: from);
        }
      },
    );

    test('differs between two trees built from the same module types', () {
      final first = deepTree();
      final second = deepTree();

      expect(RouteModuleTree.rootOf(second.l4), same(second.app));
      expect(RouteModuleTree.rootOf(first.l4), same(first.app));
      expect(
        RouteModuleTree.of(second.l4),
        isNot(same(RouteModuleTree.of(first.l4))),
      );
      expect(RouteModuleTree.of(first.app)!.contains(second.l4), isFalse);
    });

    test(
      'is absent for a test double that only implements CoordinatorCore, and for a module below one',
      () {
        final interfaceDouble = InterfaceDouble();
        final mockStyleDouble = MockStyleDouble();
        final belowDouble = NestedCoordinator(
          ModularDouble(AppStackPath(debugLabel: 'double-root')),
        );
        expect(belowDouble.isRouteModule, isTrue);

        for (final (label, coordinator) in <(String, CoordinatorCore)>[
          ('interface double', interfaceDouble),
          ('mock-style double', mockStyleDouble),
          ('real module below a double', belowDouble),
        ]) {
          expect(RouteModuleTree.rootOf(coordinator), isNull, reason: label);
          expect(RouteModuleTree.of(coordinator), isNull, reason: label);
          expect(
            coordinator.moduleTreeUsingRedirectRules,
            isNull,
            reason: label,
          );
        }
      },
    );
  });

  group('nodes', () {
    test('come in pre-order, root first, with their parent links', () {
      final w = wideTree();
      final tree = RouteModuleTree.of(w.app)!;

      expect(modulesOf(tree.nodes), [
        same(w.app),
        same(w.a),
        same(w.a1),
        same(w.a2),
        same(w.a21),
        same(w.b),
      ]);
      expect(tree.nodes.map((node) => node.parent?.module), [
        isNull,
        same(w.app),
        same(w.a),
        same(w.a),
        same(w.a2),
        same(w.app),
      ]);
      expect(tree.nodeOf(w.a21)!.parent, same(tree.nodeOf(w.a2)));
      expect(tree.nodeOf(w.a2)!.parent, same(tree.nodeOf(w.a)));
      expect(tree.nodeOf(w.a)!.parent, same(tree.nodes.first));
      expect(() => tree.nodes.add(tree.nodes.first), throwsUnsupportedError);
    });

    test(
      'enclose exactly the nodes below them, the same answer as walking up the parent links',
      () {
        bool walksUpTo(RouteModuleTreeNode node, RouteModuleTreeNode other) {
          for (var up = other.parent; up != null; up = up.parent) {
            if (identical(up, node)) return true;
          }
          return false;
        }

        for (final (label, tree) in <(String, RouteModuleTree)>[
          ('deep tree', RouteModuleTree.of(deepTree().app)!),
          ('wide tree', RouteModuleTree.of(wideTree().app)!),
        ]) {
          final nodes = tree.nodes;
          var enclosing = 0;
          for (var i = 0; i < nodes.length; i++) {
            for (var j = 0; j < nodes.length; j++) {
              final expected = walksUpTo(nodes[i], nodes[j]);
              if (expected) enclosing++;
              expect(
                nodes[i].encloses(nodes[j]),
                expected,
                reason: '$label: node $i encloses node $j',
              );
            }
          }
          // Guards against a vacuous pass: both trees nest several levels.
          expect(enclosing, greaterThan(nodes.length), reason: label);
        }
      },
    );

    test(
      'are one per module instance: two equal modules of one type at two levels are two nodes',
      () {
        final w = wideTree();
        final tree = RouteModuleTree.of(w.app)!;
        // Coordinators extend Equatable: same type, same props, so `==`.
        expect(w.a2, equals(w.a));

        final a = tree.nodeOf(w.a)!;
        final a2 = tree.nodeOf(w.a2)!;
        expect(a2, isNot(same(a)));
        expect(a.module, same(w.a));
        expect(a2.module, same(w.a2));
        expect(a.encloses(a2), isTrue);
        expect(a2.encloses(a), isFalse);
        expect(a2.encloses(tree.nodeOf(w.a1)!), isFalse);
        expect(a.encloses(tree.nodeOf(w.a21)!), isTrue);

        // An equal module that is not registered is not in the tree.
        final stranger = NestedCoordinator(w.app, extraLabel: 'stranger');
        expect(stranger, equals(w.a));
        expect(tree.contains(stranger), isFalse);
        expect(tree.nodeOf(stranger), isNull);
        for (final module in modulesOf(tree.nodes)) {
          expect(tree.contains(module), isTrue);
        }
      },
    );

    test(
      'are one per registration: a module registered twice has two nodes, and nodeOf answers the first in pre-order',
      () {
        late NestedCoordinator a;
        late FeatureModule twice;
        final app = ModularAppCoordinator(
          modules: (c) {
            twice = FeatureModule(c, prefix: 'twice');
            return [
              a = NestedCoordinator(c, extraLabel: 'a', childModules: [twice]),
              twice,
            ];
          },
        );
        final tree = RouteModuleTree.of(app)!;

        expect(modulesOf(tree.nodes), [
          same(app),
          same(a),
          same(twice),
          same(twice),
        ]);
        expect(tree.nodes[2].parent!.module, same(a));
        expect(tree.nodes[3].parent!.module, same(app));
        expect(tree.nodeOf(twice), same(tree.nodes[2]));
        expect(tree.contains(twice), isTrue);
      },
    );
  });

  group('ownership', () {
    test('each stack is owned by the innermost module that lists it', () {
      final w = wideTree();
      final tree = RouteModuleTree.of(w.app)!;

      expect(tree.ownedPaths.map((path) => path.debugLabel), [
        'root',
        'nested',
        'a1',
        'a21',
        'a2',
        'a',
        'b',
      ]);
      expect(tree.ownedPaths.map((path) => tree.ownerOf(path)!.module), [
        same(w.app),
        same(w.app),
        same(w.a1),
        same(w.a21),
        same(w.a2),
        same(w.a),
        same(w.b),
      ]);
      expect(tree.ownerOf(w.a21.featurePath), same(tree.nodeOf(w.a21)));
      expect(tree.problems, isEmpty);

      final loose = AppStackPath(coordinator: w.app, debugLabel: 'loose');
      expect(tree.ownerOf(loose), isNull);
    });

    test("a module that lists an ancestor's stack takes it over", () {
      late ListsA claimant;
      final app = ModularAppCoordinator(
        // `nested` is the root's own secondary stack, like a modal stack.
        modules: (c) => [
          claimant = ListsA(c, [c.nested]),
        ],
      );
      final tree = RouteModuleTree.of(app)!;

      expect(tree.ownerOf(app.nested)!.module, same(claimant));
      expect(tree.ownerOf(app.root)!.module, same(app));
      expect(tree.ownedPaths, [same(app.root), same(app.nested)]);
      expect(tree.problems, isEmpty);
    });

    test('whether a subtree owns a stack counts the stacks below it', () {
      late ListsA empty;
      late NestedCoordinator pathless;
      late FeatureModule sub;
      final app = ModularAppCoordinator(
        modules: (c) => [
          empty = ListsA(c, const []),
          pathless = NestedCoordinator(
            c,
            extraLabel: 'pathless',
            childModulesBuilder: (self) => [
              sub = FeatureModule(self, prefix: 'sub', hasPath: true),
            ],
          ),
        ],
      );
      final tree = RouteModuleTree.of(app)!;

      expect(tree.subtreeOwnsAStack(tree.nodeOf(empty)!), isFalse);
      expect(tree.subtreeOwnsAStack(tree.nodeOf(pathless)!), isTrue);
      expect(tree.subtreeOwnsAStack(tree.nodeOf(sub)!), isTrue);
      expect(tree.subtreeOwnsAStack(tree.nodes.first), isTrue);
    });
  });

  group('ancestry', () {
    test(
      'lists every module from the root down, root first, whether or not it declares rules',
      () {
        final log = <String>[];
        late NestedCoordinator gap;
        late ScopedNested below;
        late FeatureModule leaf;
        final app = ScopedModularApp(
          rules: [RecordingRule('app', log)],
          modules: (c) => [
            gap = NestedCoordinator(
              c,
              extraLabel: 'gap',
              childModulesBuilder: (self) => [
                below = ScopedNested(
                  self,
                  rules: [RecordingRule('below', log)],
                  extraLabel: 'below',
                  childModulesBuilder: (self) => [
                    leaf = FeatureModule(self, prefix: 'leaf', hasPath: true),
                  ],
                ),
              ],
            ),
          ],
        );
        app.registerShell(key: 'belowShell', path: below.extra);
        app.registerShell(key: 'leafShell', path: leaf.featurePath);
        final tree = RouteModuleTree.of(app)!;

        expect(tree.nodes.first.ancestry, [same(app)]);
        expect(tree.nodeOf(gap)!.ancestry, [same(app), same(gap)]);
        expect(tree.nodeOf(leaf)!.ancestry, [
          same(app),
          same(gap),
          same(below),
          same(leaf),
        ]);

        final toLeaf = AppRoute('x', parentLayoutKey: 'leafShell');
        expect(tree.ancestryOf(toLeaf), [
          same(app),
          same(gap),
          same(below),
          same(leaf),
        ]);
        expect(tree.ancestryOf(AppRoute('y', parentLayoutKey: 'belowShell')), [
          same(app),
          same(gap),
          same(below),
        ]);
        expect(tree.ancestryOf(AppRoute('home')), [same(app)]);
        expect(
          () => tree.nodeOf(leaf)!.ancestry.add(app),
          throwsUnsupportedError,
        );

        // The redirect scope keeps only the modules with redirect rules.
        expect(app.redirectScopeOf(toLeaf), [same(app), same(below)]);
        expect(log, isEmpty);
      },
    );

    test('is absent for a destination landing in a stack no module lists', () {
      final app = ScopedModularApp(rules: []);
      final loose = AppStackPath(coordinator: app, debugLabel: 'loose');
      app.registerShell(key: 'looseShell', path: loose);
      final tree = RouteModuleTree.of(app)!;
      final destination = AppRoute('x', parentLayoutKey: 'looseShell');

      expect(tree.landingOf(destination), same(loose));
      expect(tree.ownerOf(loose), isNull);
      expect(tree.ancestryOf(destination), isNull);
    });
  });

  group('landing', () {
    test(
      'is the root stack without a parent layout, and the layout stack with one',
      () {
        final w = wideTree();
        w.app.registerShell(key: 'a2Shell', path: w.a2.extra);
        w.app.registerShell(key: 'a21Shell', path: w.a21.featurePath);
        final tree = RouteModuleTree.of(w.a21.coordinator)!;

        expect(tree.landingOf(AppRoute('home')), same(w.app.root));
        expect(
          tree.landingOf(AppRoute('x', parentLayoutKey: 'a2Shell')),
          same(w.a2.extra),
        );
        expect(
          tree.landingOf(AppRoute('y', parentLayoutKey: 'a21Shell')),
          same(w.a21.featurePath),
        );
      },
    );

    test('throws for a parent layout the tree root cannot build', () {
      final tree = RouteModuleTree.of(ModularAppCoordinator())!;

      expect(
        () => tree.landingOf(AppRoute('q', parentLayoutKey: 'missing')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'AppRoute(q) names parentLayoutKey missing, but the tree root '
                'ModularAppCoordinator has no layout constructor for it, so '
                'it would silently land on the root stack; register the '
                'layout on the tree root.',
          ),
        ),
      );
    });

    test(
      'discards a layout built only to answer exactly once, and reuses a mounted layout without discarding it',
      () async {
        final w = wideTree();
        final shells = CountingShellConstructor(
          w.app,
          key: 'aShell',
          path: w.a.extra,
        );
        final tree = RouteModuleTree.of(w.app)!;

        expect(
          tree.landingOf(AppRoute('x', parentLayoutKey: 'aShell')),
          same(w.a.extra),
        );
        expect(shells.constructions, 1);
        expect(shells.built.single.stackPath, isNull);
        expect(shells.built.single.discards, 1);

        expect(
          tree.landingOf(AppRoute('x', parentLayoutKey: 'aShell')),
          same(w.a.extra),
        );
        expect(shells.built.map((probe) => probe.discards), [1, 1]);

        // The tree is opted out, so resolving does not probe: the push builds
        // and mounts one shell.
        await w.app.pushSilently(AppRoute('x', parentLayoutKey: 'aShell'));
        expect(shells.constructions, 3);
        final mounted = shells.built.last;
        expect(w.app.root.stack, [same(mounted)]);

        expect(
          tree.landingOf(AppRoute('y', parentLayoutKey: 'aShell')),
          same(w.a.extra),
        );
        expect(
          tree.landingOf(AppRoute('z', parentLayoutKey: 'aShell')),
          same(w.a.extra),
        );
        expect(shells.constructions, 3);
        expect(shells.built.map((layout) => layout.discards), [1, 1, 0]);
        expect(shells.discards, 2);
        expect(mounted.stackPath, same(w.app.root));
      },
    );
  });

  group('topology problems', () {
    test(
      'are reported as data, in the order found, and building the tree does not throw',
      () {
        final p = problemTree(declaring: false);
        final tree = RouteModuleTree.of(p.app)!;
        final a = tree.nodeOf(p.listsA)!;
        final b = tree.nodeOf(p.listsB)!;

        expect(tree.problems, [
          isA<SiblingSharedStack>()
              .having((problem) => problem.path, 'path', same(p.shared))
              .having((problem) => problem.node, 'node', same(b))
              .having((problem) => problem.owner, 'owner', same(a)),
          isA<RootStackListed>()
              .having((problem) => problem.path, 'path', same(p.app.root))
              .having(
                (problem) => problem.node,
                'node',
                same(tree.nodeOf(p.listsRoot)),
              ),
          isA<StackWithoutCoordinator>()
              .having((problem) => problem.path, 'path', same(p.detached))
              .having((problem) => problem.node, 'node', same(a)),
          isA<StackFromOtherTree>()
              .having((problem) => problem.path, 'path', same(p.foreign))
              .having((problem) => problem.node, 'node', same(b))
              .having(
                (problem) => problem.coordinator,
                'coordinator',
                same(p.other),
              ),
        ]);
        expect(() => tree.problems.removeLast(), throwsUnsupportedError);

        // A listing that is a problem claims nothing; the stacks it names
        // keep their owners.
        expect(tree.ownerOf(p.shared), same(a));
        expect(tree.ownerOf(p.app.root), same(tree.nodes.first));
        expect(tree.ownerOf(p.detached), same(a));
        expect(tree.ownerOf(p.foreign), same(b));
      },
    );

    test(
      'are not errors in a tree where no module declares rules: it uses no redirect rules, and navigation works',
      () async {
        final p = problemTree(declaring: false);

        expect(RouteModuleTree.of(p.app)!.usesRedirectRules, isFalse);
        expect(p.app.moduleTreeUsingRedirectRules, isNull);
        await p.app.pushSilently(AppRoute('home'));
        expect(p.app.root.stack.map((route) => route.id), ['home']);
        expect(p.app.redirectScopeOf(AppRoute('home')), isEmpty);
        expect(RouteModuleTree.of(p.app)!.problems, hasLength(4));
      },
    );

    test(
      'throw from the redirect validation once a module declares rules, followed by its own problems',
      () {
        final p = problemTree(declaring: true);
        final tree = RouteModuleTree.of(p.app)!;
        const expected =
            'Redirect scope of ModularAppCoordinator is misconfigured:\n'
            "- stack 'shared' is listed by both ListsA and ListsB, and "
            'neither encloses the other; list each stack in exactly one '
            'module.\n'
            "- ListsRoot lists the root stack 'root' in paths, which would "
            'make its rules gate every layout-less route; only the tree root '
            'owns the root stack, so remove it from the module paths.\n'
            "- stack 'detached' listed by ListsA has no coordinator, so "
            'path-level navigation on it would skip every gate; create it '
            'with a coordinator of this tree.\n'
            "- stack 'foreign' listed by ListsB belongs to AppCoordinator, "
            'which is not part of this tree; create it with a coordinator of '
            'this tree.\n'
            '- RulesWithoutStack declares redirectRules but no stack it or '
            'its sub-modules list in paths, so its routes land on the root '
            'stack and its rules could gate nothing. Give the module a stack, '
            'bind a layout to it and give its routes that layout; or declare '
            'the rules on the root coordinator, which owns the root stack.';
        final throwsMisconfigured = throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            expected,
          ),
        );

        // The module with rules but no stack is a redirect problem, not a
        // topology problem of the tree.
        expect(tree.problems, hasLength(4));
        expect(modulesOf(tree.nodes).last, isA<RulesWithoutStack>());
        expect(tree.subtreeOwnsAStack(tree.nodes.last), isFalse);
        expect(tree.usesRedirectRules, isTrue);

        expect(() => p.app.moduleTreeUsingRedirectRules, throwsMisconfigured);
        // A failed validation is not kept: every later call throws again.
        expect(() => p.app.moduleTreeUsingRedirectRules, throwsMisconfigured);
        expect(() => tree.validateRedirectScope(), throwsMisconfigured);
        expect(
          () => p.app.redirectScopeOf(AppRoute('home')),
          throwsMisconfigured,
        );
        // The tree itself still stands, and still does not throw.
        expect(RouteModuleTree.of(p.app), same(tree));
        expect(tree.problems, hasLength(4));
      },
    );
  });

  group('scopeOf', () {
    test(
      'scopes each capability on its own: a module with only one of two capabilities never appears in the scope of the other',
      () async {
        final log = <String>[];
        late CapabilityNested capability;
        late CapabilityAndRules both;
        late ScopedNested rules;
        final app = ModularAppCoordinator(
          modules: (c) => [
            capability = CapabilityNested(
              c,
              childModulesBuilder: (self) => [
                both = CapabilityAndRules(
                  self,
                  rules: [RecordingRule('both', log)],
                ),
              ],
            ),
            rules = ScopedNested(
              c,
              rules: [RecordingRule('rules', log)],
              extraLabel: 'rules',
            ),
          ],
        );
        app.registerShell(key: 'capabilityShell', path: capability.extra);
        app.registerShell(key: 'bothShell', path: both.featurePath);
        app.registerShell(key: 'rulesShell', path: rules.extra);
        final tree = RouteModuleTree.of(app)!;
        final toCapability = AppRoute('c', parentLayoutKey: 'capabilityShell');
        final toBoth = AppRoute('b', parentLayoutKey: 'bothShell');
        final toRules = AppRoute('r', parentLayoutKey: 'rulesShell');
        final toRoot = AppRoute('home');

        expect(tree.declares<TestCapability>(), isTrue);
        expect(tree.declares<RouteModuleRedirectRule>(), isTrue);

        expect(tree.scopeOf<TestCapability>(toCapability), [same(capability)]);
        expect(tree.scopeOf<RouteModuleRedirectRule>(toCapability), isEmpty);
        expect(app.redirectScopeOf(toCapability), isEmpty);

        expect(tree.scopeOf<TestCapability>(toBoth), [
          same(capability),
          same(both),
        ]);
        expect(tree.scopeOf<RouteModuleRedirectRule>(toBoth), [same(both)]);
        expect(app.redirectScopeOf(toBoth), [same(both)]);

        expect(tree.scopeOf<TestCapability>(toRules), isEmpty);
        expect(tree.scopeOf<RouteModuleRedirectRule>(toRules), [same(rules)]);
        expect(app.redirectScopeOf(toRules), [same(rules)]);

        expect(tree.scopeOf<TestCapability>(toRoot), isEmpty);
        expect(tree.scopeOf<RouteModuleRedirectRule>(toRoot), isEmpty);

        // Navigation runs only redirect rules.
        await app.pushSilently(toCapability);
        await app.pushSilently(toBoth);
        await app.pushSilently(toRules);
        expect(log, ['both(b)', 'rules(r)']);
      },
    );

    test(
      'a tree whose modules have only another capability uses no redirect rules, and still scopes that capability',
      () {
        late CapabilityNested capability;
        final app = ModularAppCoordinator(
          modules: (c) => [capability = CapabilityNested(c)],
        );
        app.registerShell(key: 'capabilityShell', path: capability.extra);
        final tree = RouteModuleTree.of(app)!;
        final toCapability = AppRoute('c', parentLayoutKey: 'capabilityShell');

        expect(tree.declares<TestCapability>(), isTrue);
        expect(tree.declares<RouteModuleRedirectRule>(), isFalse);
        expect(tree.usesRedirectRules, isFalse);
        expect(app.moduleTreeUsingRedirectRules, isNull);
        expect(app.redirectScopeOf(toCapability), isEmpty);
        expect(tree.scopeOf<TestCapability>(toCapability), [same(capability)]);
      },
    );

    test('is empty for a layout parent, without resolving where it lands', () {
      final w = wideTree();
      final shells = CountingShellConstructor(
        w.app,
        key: 'aShell',
        path: w.a.extra,
      );
      final tree = RouteModuleTree.of(w.app)!;
      // A shell nested in the aShell layout: it lands in a's stack.
      final shell = AppLayout(
        'a2Shell',
        layoutKey: 'a2Shell',
        path: w.a2.extra,
        parentLayoutKey: 'aShell',
      );

      expect(tree.scopeOf<RouteModule>(shell), isEmpty);
      expect(tree.scopeOf<NestedCoordinator>(shell), isEmpty);
      expect(shells.constructions, 0);

      // Asked where it lands, it is a destination like any other.
      expect(tree.ancestryOf(shell), [same(w.app), same(w.a)]);
      expect(shells.constructions, 1);
      expect(shells.discards, 1);
    });

    test(
      'returns the identical list for every destination one module owns, per capability',
      () {
        late ListsA owner;
        late AppStackPath first, second;
        final app = ScopedModularApp(
          rules: [],
          modules: (c) {
            first = AppStackPath(coordinator: c, debugLabel: 'first');
            second = AppStackPath(coordinator: c, debugLabel: 'second');
            return [
              owner = ListsA(c, [first, second]),
            ];
          },
        );
        app.registerShell(key: 'firstShell', path: first);
        app.registerShell(key: 'secondShell', path: second);
        final tree = RouteModuleTree.of(app)!;
        AppRoute toFirst() => AppRoute('x', parentLayoutKey: 'firstShell');
        AppRoute toSecond() => AppRoute('y', parentLayoutKey: 'secondShell');

        final modules = tree.scopeOf<RouteModule>(toFirst());
        expect(modules, [same(app), same(owner)]);
        expect(tree.scopeOf<RouteModule>(toFirst()), same(modules));
        expect(tree.scopeOf<RouteModule>(toSecond()), same(modules));
        expect(() => modules.add(app), throwsUnsupportedError);

        final redirect = tree.scopeOf<RouteModuleRedirectRule>(toFirst());
        expect(redirect, [same(app)]);
        expect(
          tree.scopeOf<RouteModuleRedirectRule>(toSecond()),
          same(redirect),
        );
        expect(tree.redirectLineageOf(toSecond()), same(redirect));

        final root = tree.scopeOf<RouteModule>(AppRoute('home'));
        expect(root, [same(app)]);
        expect(tree.scopeOf<RouteModule>(AppRoute('again')), same(root));
      },
    );

    test(
      'throws the landing errors with the messages navigation throws',
      () async {
        final app = ScopedModularApp(rules: []);
        final loose = AppStackPath(coordinator: app, debugLabel: 'loose');
        app.registerShell(key: 'looseShell', path: loose);
        final tree = RouteModuleTree.of(app)!;
        const noLayout =
            'AppRoute(q) names parentLayoutKey missing, but the tree root '
            'ScopedModularApp has no layout constructor for it, so it would '
            'silently land on the root stack; register the layout on the tree '
            'root.';
        const unlisted =
            "AppRoute(x) lands in stack 'loose', which no module of "
            'ScopedModularApp lists in paths; list it in the owning '
            "module's paths. Stacks are claimed once, on the first "
            'resolution: a stack that a paths getter starts to return later '
            'is not seen, so return it from the start.';
        Matcher throwsMessage(String message) => throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            message,
          ),
        );
        final missing = AppRoute('q', parentLayoutKey: 'missing');
        final stray = AppRoute('x', parentLayoutKey: 'looseShell');

        expect(
          () => tree.scopeOf<RouteModule>(missing),
          throwsMessage(noLayout),
        );
        expect(
          () => tree.scopeOf<RouteModuleRedirectRule>(missing),
          throwsMessage(noLayout),
        );
        expect(() => app.redirectScopeOf(missing), throwsMessage(noLayout));
        await expectLater(app.pushSilently(missing), throwsMessage(noLayout));

        expect(() => tree.scopeOf<RouteModule>(stray), throwsMessage(unlisted));
        expect(
          () => tree.scopeOf<RouteModuleRedirectRule>(stray),
          throwsMessage(unlisted),
        );
        expect(() => app.redirectScopeOf(stray), throwsMessage(unlisted));
        await expectLater(app.pushSilently(stray), throwsMessage(unlisted));
        expect(loose.stack, isEmpty);
      },
    );
  });

  group('laziness', () {
    test(
      'the tree is built once per root and reused by every coordinator, navigation and the redirect rules',
      () async {
        final log = <String>[];
        late ScopedNested mod;
        final app = CountingScopedApp(
          rules: [RecordingRule('app', log)],
          modules: (c) => [
            mod = ScopedNested(
              c,
              rules: [RecordingRule('mod', log)],
              extraLabel: 'mod',
            ),
          ],
        );
        app.registerShell(key: 'modShell', path: mod.extra);
        final atConstruction = app.pathsReads;

        final tree = RouteModuleTree.of(mod)!;
        expect(
          app.pathsReads,
          atConstruction,
          reason: 'building the tree walks the registry only',
        );

        await app.pushSilently(AppRoute('x', parentLayoutKey: 'modShell'));
        await mod.pushSilently(AppRoute('y', parentLayoutKey: 'modShell'));
        await mod.extra.pushSilently(
          AppRoute('z', parentLayoutKey: 'modShell'),
        );
        await app.pushSilently(AppRoute('home'));
        expect(
          app.redirectScopeOf(AppRoute('w', parentLayoutKey: 'modShell')),
          [same(app), same(mod)],
        );
        expect(log, [
          'app(x)',
          'mod(x)',
          'app(y)',
          'mod(y)',
          'app(z)',
          'mod(z)',
          'app(home)',
        ]);

        expect(RouteModuleTree.of(app), same(tree));
        expect(RouteModuleTree.of(mod), same(tree));
        expect(app.moduleTreeUsingRedirectRules, same(tree));
        expect(mod.moduleTreeUsingRedirectRules, same(tree));
        expect(
          app.pathsReads - atConstruction,
          1,
          reason: 'the stacks are claimed once, when redirects first validate',
        );
      },
    );

    test(
      'an opted-out tree is built once and claims its stacks only when asked',
      () async {
        late NestedCoordinator mod;
        final app = CountingApp(
          modules: (c) => [mod = NestedCoordinator(c, extraLabel: 'mod')],
        );
        app.registerShell(key: 'modShell', path: mod.extra);
        final atConstruction = app.pathsReads;
        final tree = RouteModuleTree.of(app)!;

        await app.pushSilently(AppRoute('x', parentLayoutKey: 'modShell'));
        await mod.pushSilently(AppRoute('y', parentLayoutKey: 'modShell'));
        await mod.extra.pushSilently(AppRoute('z'));
        expect(app.moduleTreeUsingRedirectRules, isNull);
        expect(RouteModuleTree.of(mod), same(tree));
        expect(
          app.pathsReads,
          atConstruction,
          reason: 'navigation in an opted-out tree never claims the stacks',
        );

        expect(tree.ownerOf(mod.extra), same(tree.nodeOf(mod)));
        expect(tree.ownerOf(app.root), same(tree.nodes.first));
        await app.pushSilently(AppRoute('w', parentLayoutKey: 'modShell'));
        expect(RouteModuleTree.of(app), same(tree));
        expect(app.pathsReads - atConstruction, 1);
      },
    );
  });
}
