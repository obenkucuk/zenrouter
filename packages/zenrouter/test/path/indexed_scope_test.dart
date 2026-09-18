// F1 and F2 of the scoped-redirect plan: IndexedStackPath.goToIndexed and
// BranchedStackPath.goToBranch resolve through RouteRedirect.resolve, like
// every other entry point.
//
// Every test drives a real Coordinator and real paths, and asserts on the
// rule log, the active index and stacks, and onDiscard counts.
//
// The pre-existing opted-out pins stay in their own files and pass unchanged:
// test/path/indexed_test.dart ('Coordinator will switch to resolved route when
// redirect to outside stack route', 'Redirect works within stack', 'do nothing
// when redirectWith return null') and test/mixin/redirect_rule_test.dart
// ('Indexed stack should not redirect if redirect rule route return itself',
// which reads a rule's call count synchronously after an un-awaited switch).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ===========================================================================
// Routes
// ===========================================================================

abstract class ScopeRoute extends RouteTarget with RouteUnique {
  /// The name the rules log.
  String get id;

  @override
  Uri toUri() => Uri.parse('/$id');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      Text(id);

  @override
  String toString() => '$runtimeType($id)';
}

/// A destination that counts its `onDiscard` calls.
class Dest extends ScopeRoute {
  Dest(this.id);

  @override
  final String id;

  int discards = 0;

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }

  @override
  List<Object?> get props => [id];
}

/// An entry of the scoped tab path; it declares the tab layout, so it lands
/// in the module's stack.
class TabEntry extends Dest {
  TabEntry(super.id);

  @override
  Type? get layout => TabsLayout;
}

class TabsLayout extends ScopeRoute with RouteLayout<ScopeRoute> {
  @override
  String get id => 'tabs-layout';

  @override
  StackPath<RouteUnique> resolvePath(
    covariant CoordinatorModular<ScopeRoute> coordinator,
  ) => coordinator.getModule<TabsModule>().tabs;
}

/// A tab entry whose own redirect returns [to], after a real async gap so a
/// timeout can fire. Past [cap] calls it fails the test outright, so a switch
/// that never ends fails instead of hanging.
class PingTab extends Dest with RouteRedirect<ScopeRoute> {
  PingTab(super.id);

  static const cap = 1000;

  late ScopeRoute Function() to;
  int calls = 0;

  Future<ScopeRoute> _next() async {
    calls++;
    if (calls > cap) fail('goToIndexed followed $id more than $cap times');
    await Future<void>.delayed(Duration.zero);
    return to();
  }

  @override
  Future<ScopeRoute> redirect() => _next();

  @override
  Future<ScopeRoute?> redirectWith(covariant CoordinatorCore coordinator) =>
      _next();
}

/// A tab entry whose own redirect returns a fresh, value-equal instance of
/// itself every time, recorded in [created].
class EchoTab extends Dest with RouteRedirect<ScopeRoute> {
  EchoTab(super.id, this.created);

  final List<EchoTab> created;
  int calls = 0;

  Future<ScopeRoute> _next() async {
    calls++;
    if (created.length >= PingTab.cap) {
      fail('goToIndexed followed $id more than ${PingTab.cap} times');
    }
    await Future<void>.delayed(Duration.zero);
    final echo = EchoTab(id, created);
    created.add(echo);
    return echo;
  }

  @override
  Future<ScopeRoute> redirect() => _next();

  @override
  Future<ScopeRoute?> redirectWith(covariant CoordinatorCore coordinator) =>
      _next();
}

/// The only route type the narrow tab path hosts.
class NarrowTab extends Dest {
  NarrowTab(super.id);
}

/// A narrow entry whose own redirect returns a route of another type.
class WrongTypeTab extends NarrowTab with RouteRedirect<ScopeRoute> {
  WrongTypeTab(super.id, this.to);

  final ScopeRoute Function() to;

  @override
  ScopeRoute redirect() => to();
}

/// An entry whose own redirect (with a coordinator) returns [to]: `null`
/// stops, another route redirects.
class SwitchTab extends Dest with RouteRedirect<ScopeRoute> {
  SwitchTab(super.id, this.to);

  final ScopeRoute? Function() to;

  @override
  ScopeRoute? redirectWith(covariant CoordinatorCore coordinator) => to();
}

// Branches ------------------------------------------------------------------

class BranchShell extends ScopeRoute with RouteLayout<ScopeRoute> {
  @override
  String get id => 'branch-shell';

  @override
  StackPath<RouteUnique> resolvePath(
    covariant CoordinatorModular<ScopeRoute> coordinator,
  ) => coordinator.getModule<BranchModule>().branches;
}

class HomeBranch extends ScopeRoute with RouteLayout<ScopeRoute> {
  @override
  String get id => 'home-branch';

  @override
  Type get layout => BranchShell;

  @override
  StackPath<RouteUnique> resolvePath(
    covariant CoordinatorModular<ScopeRoute> coordinator,
  ) => coordinator.getModule<BranchModule>().homePath;
}

class SettingsBranch extends ScopeRoute with RouteLayout<ScopeRoute> {
  @override
  String get id => 'settings-branch';

  @override
  Type get layout => BranchShell;

  @override
  StackPath<RouteUnique> resolvePath(
    covariant CoordinatorModular<ScopeRoute> coordinator,
  ) => coordinator.getModule<BranchModule>().settingsPath;
}

class SettingsItem extends Dest {
  SettingsItem(super.id);

  @override
  Type get layout => SettingsBranch;
}

// ===========================================================================
// Rules
// ===========================================================================

/// Logs `'$name(${route.id})'`, records the coordinator it received, then
/// returns [outcome] (continue by default).
class RecordingRule extends RedirectRule<ScopeRoute> {
  RecordingRule(this.name, this.log);

  final String name;
  final List<String> log;

  /// Mutable, so a test can change the verdict between navigations.
  RedirectResult<ScopeRoute> Function(ScopeRoute route)? outcome;

  final coordinators = <CoordinatorCore>[];

  @override
  RedirectResult<ScopeRoute> redirectResult(
    CoordinatorCore coordinator,
    ScopeRoute route,
  ) {
    log.add('$name(${route.id})');
    coordinators.add(coordinator);
    return outcome?.call(route) ?? const RedirectResult.continueRedirect();
  }
}

// ===========================================================================
// Coordinators
// ===========================================================================

/// A plain module that declares rules and owns the tab path.
class TabsModule extends RouteModule<ScopeRoute>
    with RouteModuleRedirectRule<ScopeRoute> {
  TabsModule(super.coordinator, this.rule);

  final RecordingRule rule;

  @override
  late final List<RedirectRule> redirectRules = [rule];

  late final IndexedStackPath<ScopeRoute> tabs =
      IndexedStackPath<ScopeRoute>.createWith(
        [TabEntry('a'), TabEntry('b'), TabEntry('c')],
        coordinator: coordinator as Coordinator,
        label: 'tabs',
      )..bindLayout(TabsLayout.new);

  @override
  List<StackPath> get paths => [tabs];

  @override
  ScopeRoute? parseRouteFromUri(Uri uri) => null;
}

/// Root with an app-wide rule; the tabs module owns the tab path.
class TabsApp extends Coordinator<ScopeRoute>
    with CoordinatorModular<ScopeRoute>, RouteModuleRedirectRule<ScopeRoute> {
  final log = <String>[];
  late final appRule = RecordingRule('app', log);
  late final tabsRule = RecordingRule('tabs', log);

  @override
  late final List<RedirectRule> redirectRules = [appRule];

  @override
  Iterable<RouteModule<ScopeRoute>> defineModules() => [
    TabsModule(this, tabsRule),
  ];

  TabsModule get module => getModule<TabsModule>();

  IndexedStackPath<ScopeRoute> get tabs => module.tabs;

  List<TabEntry> get entries => tabs.stack.cast<TabEntry>();

  List<int> get entryDiscards => [for (final e in entries) e.discards];

  @override
  ScopeRoute notFoundRoute(Uri uri) => Dest('not-found');
}

/// A standalone coordinator with no redirect rules anywhere.
class PlainApp extends Coordinator<ScopeRoute> {
  PlainApp(this.entries);

  final List<ScopeRoute> entries;

  late final IndexedStackPath<ScopeRoute> tabs =
      IndexedStackPath<ScopeRoute>.createWith(
        entries,
        coordinator: this,
        label: 'plain-tabs',
      );

  @override
  List<StackPath> get paths => [...super.paths, tabs];

  @override
  ScopeRoute parseRouteFromUri(Uri uri) => Dest('home');
}

/// A plain module that declares rules and owns the branched path and both
/// branch stacks.
class BranchModule extends RouteModule<ScopeRoute>
    with RouteModuleRedirectRule<ScopeRoute> {
  BranchModule(super.coordinator, this.rule);

  final RecordingRule rule;

  @override
  late final List<RedirectRule> redirectRules = [rule];

  late final NavigationPath<ScopeRoute> homePath =
      NavigationPath<ScopeRoute>.createWith(
        coordinator: coordinator,
        label: 'home',
      )..bindLayout(HomeBranch.new);

  late final NavigationPath<ScopeRoute> settingsPath =
      NavigationPath<ScopeRoute>.createWith(
        coordinator: coordinator,
        label: 'settings',
      )..bindLayout(SettingsBranch.new);

  late final BranchedStackPath<ScopeRoute> branches =
      BranchedStackPath<ScopeRoute>.createWith(
        [HomeBranch(), SettingsBranch()],
        coordinator: coordinator as Coordinator,
        label: 'branches',
      )..bindLayout(BranchShell.new);

  @override
  List<StackPath> get paths => [branches, homePath, settingsPath];

  @override
  ScopeRoute? parseRouteFromUri(Uri uri) => null;
}

class BranchApp extends Coordinator<ScopeRoute>
    with CoordinatorModular<ScopeRoute>, RouteModuleRedirectRule<ScopeRoute> {
  final log = <String>[];
  late final appRule = RecordingRule('app', log);
  late final branchRule = RecordingRule('branch', log);

  @override
  late final List<RedirectRule> redirectRules = [appRule];

  @override
  Iterable<RouteModule<ScopeRoute>> defineModules() => [
    BranchModule(this, branchRule),
  ];

  BranchModule get module => getModule<BranchModule>();

  @override
  ScopeRoute notFoundRoute(Uri uri) => Dest('not-found');
}

/// A plain module that declares rules and owns a tab path whose entries
/// declare no layout, the upstream layout-less entry idiom.
class LooseTabsModule extends RouteModule<ScopeRoute>
    with RouteModuleRedirectRule<ScopeRoute> {
  LooseTabsModule(super.coordinator, this.rule);

  final RecordingRule rule;

  @override
  late final List<RedirectRule> redirectRules = [rule];

  late final IndexedStackPath<ScopeRoute> tabs =
      IndexedStackPath<ScopeRoute>.createWith(
        [Dest('a'), Dest('b'), Dest('c')],
        coordinator: coordinator as Coordinator,
        label: 'loose-tabs',
      );

  @override
  List<StackPath> get paths => [tabs];

  @override
  ScopeRoute? parseRouteFromUri(Uri uri) => null;
}

/// A declaring root over [LooseTabsModule], whose rule stops everything.
class LooseTabsApp extends Coordinator<ScopeRoute>
    with CoordinatorModular<ScopeRoute>, RouteModuleRedirectRule<ScopeRoute> {
  final log = <String>[];
  late final appRule = RecordingRule('app', log);
  late final tabsRule = RecordingRule('tabs', log)
    ..outcome = (_) => const RedirectResult.stop();

  @override
  late final List<RedirectRule> redirectRules = [appRule];

  @override
  Iterable<RouteModule<ScopeRoute>> defineModules() => [
    LooseTabsModule(this, tabsRule),
  ];

  IndexedStackPath<ScopeRoute> get tabs => getModule<LooseTabsModule>().tabs;

  @override
  ScopeRoute notFoundRoute(Uri uri) => Dest('not-found');
}

/// A root that declares no rules over [LooseTabsModule].
class LooseTabsPlainRootApp extends Coordinator<ScopeRoute>
    with CoordinatorModular<ScopeRoute> {
  final log = <String>[];
  late final tabsRule = RecordingRule('tabs', log)
    ..outcome = (_) => const RedirectResult.stop();

  @override
  Iterable<RouteModule<ScopeRoute>> defineModules() => [
    LooseTabsModule(this, tabsRule),
  ];

  IndexedStackPath<ScopeRoute> get tabs => getModule<LooseTabsModule>().tabs;

  @override
  ScopeRoute notFoundRoute(Uri uri) => Dest('not-found');
}

// A tab set that one root can host through a module with or without the
// mixin, for the S9 comparison. The layout resolves through the root, so
// both trees share the same entry types.

class RootTabsLayout extends ScopeRoute with RouteLayout<ScopeRoute> {
  @override
  String get id => 'root-tabs-layout';

  @override
  StackPath<RouteUnique> resolvePath(covariant TabsRoot coordinator) =>
      coordinator.tabs;
}

/// An entry of [TabsRoot]'s tab set; it declares the tab set's layout.
class RootTabEntry extends Dest {
  RootTabEntry(super.id);

  @override
  Type get layout => RootTabsLayout;
}

/// An entry of [TabsRoot]'s tab set whose own redirect returns [to].
class OutTab extends RootTabEntry with RouteRedirect<ScopeRoute> {
  OutTab(super.id, this.to);

  final ScopeRoute Function() to;

  @override
  ScopeRoute redirectWith(covariant CoordinatorCore coordinator) => to();
}

abstract class TabsModuleBase extends RouteModule<ScopeRoute> {
  TabsModuleBase(super.coordinator, this.entries);

  final List<ScopeRoute> entries;

  late final IndexedStackPath<ScopeRoute> tabs =
      IndexedStackPath<ScopeRoute>.createWith(
        entries,
        coordinator: coordinator as Coordinator,
        label: 'root-tabs',
      )..bindLayout(RootTabsLayout.new);

  @override
  List<StackPath> get paths => [tabs];

  @override
  ScopeRoute? parseRouteFromUri(Uri uri) => null;
}

/// The tab module without the mixin: the reference.
class PlainTabsModule extends TabsModuleBase {
  PlainTabsModule(super.coordinator, super.entries);
}

/// The same tab module, declaring an empty rule list.
class EmptyRulesTabsModule extends TabsModuleBase
    with RouteModuleRedirectRule<ScopeRoute> {
  EmptyRulesTabsModule(super.coordinator, super.entries);

  @override
  late final List<RedirectRule> redirectRules = [];
}

/// A root without the mixin that hosts one tab module.
class TabsRoot extends Coordinator<ScopeRoute>
    with CoordinatorModular<ScopeRoute> {
  TabsRoot(this.build);

  final TabsModuleBase Function(TabsRoot root) build;

  late final TabsModuleBase module = build(this);

  IndexedStackPath<ScopeRoute> get tabs => module.tabs;

  @override
  Iterable<RouteModule<ScopeRoute>> defineModules() => [module];

  @override
  ScopeRoute notFoundRoute(Uri uri) => Dest('not-found');
}

RedirectResult<ScopeRoute> pass() => const RedirectResult.continueRedirect();

Matcher sameEntries(List<ScopeRoute> entries) =>
    equals([for (final entry in entries) same(entry)]);

// ===========================================================================
// Tests
// ===========================================================================

void main() {
  group('F1 (T1) goToIndexed under a scoped root', () {
    test('F1 a tab switch runs the root rules, then the owning module rules, '
        'for the entry', () async {
      final app = TabsApp();
      final [a, b, c] = app.entries;
      expect(app.redirectScopeOf(b), [app, app.module]);

      await app.tabs.goToIndexed(1);

      expect(app.log, ['app(b)', 'tabs(b)']);
      expect(app.tabs.activeIndex, 1);
      expect(app.tabs.stack, sameEntries([a, b, c]));
      expect(app.root.stack, isEmpty);
      expect(app.entryDiscards, [0, 0, 0]);
      expect([
        ...app.appRule.coordinators,
        ...app.tabsRule.coordinators,
      ], everyElement(same(app)));
    });

    test('F1 a Stop keeps the active index and discards no entry', () async {
      final app = TabsApp();
      final [a, b, c] = app.entries;
      app.tabsRule.outcome = (route) =>
          route.id == 'b' ? const RedirectResult.stop() : pass();

      await app.tabs.goToIndexed(1);

      expect(app.log, ['app(b)', 'tabs(b)']);
      expect(app.tabs.activeIndex, 0);
      expect(app.entryDiscards, [0, 0, 0]);

      // A root Stop ends the pass before the module rule runs.
      app.log.clear();
      app.tabsRule.outcome = null;
      app.appRule.outcome = (_) => const RedirectResult.stop();

      await app.tabs.goToIndexed(2);

      expect(app.log, ['app(c)']);
      expect(app.tabs.activeIndex, 0);
      expect(app.tabs.stack, sameEntries([a, b, c]));
      expect(app.root.stack, isEmpty);
      expect(app.entryDiscards, [0, 0, 0]);
    });

    test('F1 a RedirectTo another entry switches to it, and neither entry is '
        'discarded', () async {
      final app = TabsApp();
      final [a, b, c] = app.entries;
      app.tabsRule.outcome = (route) =>
          route.id == 'b' ? RedirectResult.redirectTo(c) : pass();

      await app.tabs.goToIndexed(1);

      // The target is resolved again from the top, in its own scope.
      expect(app.log, ['app(b)', 'tabs(b)', 'app(c)', 'tabs(c)']);
      expect(app.tabs.activeIndex, 2);
      expect(app.tabs.stack, sameEntries([a, b, c]));
      expect(app.entryDiscards, [0, 0, 0]);
    });

    test('F1 a RedirectTo an equal new instance switches to the entry and '
        'discards the unused instance once', () async {
      final app = TabsApp();
      final [a, b, c] = app.entries;
      final fresh = <TabEntry>[];
      app.tabsRule.outcome = (route) {
        if (route.id != 'b') return pass();
        final next = TabEntry('c');
        fresh.add(next);
        return RedirectResult.redirectTo(next);
      };

      await app.tabs.goToIndexed(1);

      expect(app.log, ['app(b)', 'tabs(b)', 'app(c)', 'tabs(c)']);
      expect(app.tabs.activeIndex, 2);
      expect(app.tabs.stack, sameEntries([a, b, c]));
      expect(fresh.single.discards, 1);
      expect(app.entryDiscards, [0, 0, 0]);
    });

    test(
      'F1 a redirect out of the entries keeps the index, asserts with the '
      'coordinator.navigate advice, and discards the fresh target once',
      () async {
        final app = TabsApp();
        final [a, b, c] = app.entries;
        final outside = Dest('outside');
        app.tabsRule.outcome = (route) =>
            route.id == 'b' ? RedirectResult.redirectTo(outside) : pass();

        await expectLater(
          app.tabs.goToIndexed(1),
          throwsA(
            isA<AssertionError>().having(
              (error) => '${error.message}',
              'message',
              allOf(
                contains('coordinator.navigate'),
                contains('TabEntry'),
                contains('tabs'),
              ),
            ),
          ),
        );

        // outside is layout-less: it lands on the root stack, so only the
        // root chain runs for it.
        expect(app.log, ['app(b)', 'tabs(b)', 'app(outside)']);
        expect(app.tabs.activeIndex, 0);
        expect(app.tabs.stack, sameEntries([a, b, c]));
        expect(app.root.stack, isEmpty);
        expect(outside.discards, 1);
        expect(app.entryDiscards, [0, 0, 0]);
      },
    );

    test('F1 coordinator navigation to a tab runs the chain for the operation, '
        'then again for the switch', () async {
      final app = TabsApp();
      final request = TabEntry('b');

      await app.pushSilently(request);

      // Documented: the operation resolves, then activateRoute ->
      // goToIndexed resolves the entry again.
      expect(app.log, ['app(b)', 'tabs(b)', 'app(b)', 'tabs(b)']);
      expect(app.tabs.activeIndex, 1);
      expect(app.root.stack, [isA<TabsLayout>()]);
      // activateRoute merges the request into the live entry and discards
      // the request; the entries are never discarded.
      expect(request.discards, 1);
      expect(app.entryDiscards, [0, 0, 0]);
      expect([
        ...app.appRule.coordinators,
        ...app.tabsRule.coordinators,
      ], everyElement(same(app)));
    });

    test('F1 a layout-less entry of a module-owned tab set asserts, naming the '
        'module, instead of switching past its rules', () async {
      final app = LooseTabsApp();
      final entries = app.tabs.stack.cast<Dest>();

      await expectLater(
        app.tabs.goToIndexed(1),
        throwsA(
          isA<AssertionError>().having(
            (error) => '${error.message}',
            'message',
            allOf(contains('LooseTabsModule'), contains("'loose-tabs'")),
          ),
        ),
      );

      expect(app.log, isEmpty);
      expect(app.tabs.activeIndex, 0);
      expect([for (final e in entries) e.discards], [0, 0, 0]);
      expect(app.root.stack, isEmpty);
    });

    test('F1 under a root that declares no rules, a layout-less entry of a '
        'module-owned tab set asserts instead of switching ungated', () async {
      final app = LooseTabsPlainRootApp();
      final entries = app.tabs.stack.cast<Dest>();

      await expectLater(
        app.tabs.goToIndexed(1),
        throwsA(
          isA<AssertionError>().having(
            (error) => '${error.message}',
            'message',
            contains('LooseTabsModule'),
          ),
        ),
      );

      expect(app.log, isEmpty);
      expect(app.tabs.activeIndex, 0);
      expect([for (final e in entries) e.discards], [0, 0, 0]);
    });
  });

  group('F2 goToIndexed in an opted-out tree', () {
    test('F2 (T3) two entries redirecting to each other throw StateError '
        'instead of '
        'hanging', () async {
      final home = Dest('home');
      final a = PingTab('a');
      final b = PingTab('b');
      a.to = () => b;
      b.to = () => a;
      final path = IndexedStackPath<ScopeRoute>.create([
        home,
        a,
        b,
      ], label: 'ping');

      await expectLater(
        path.goToIndexed(1).timeout(const Duration(seconds: 5)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('RouteRedirect loop detected'),
          ),
        ),
      );

      expect(path.activeIndex, 0);
      // a -> b -> a is detected when a moves the second time.
      expect([a.calls, b.calls], [2, 1]);
      expect([home.discards, a.discards, b.discards], [0, 0, 0]);
    });

    test('F2 an entry returning an equal new instance terminates on the '
        'entry', () async {
      final created = <EchoTab>[];
      final home = Dest('home');
      final b = EchoTab('b', created);
      final path = IndexedStackPath<ScopeRoute>.create([
        home,
        b,
      ], label: 'echo');

      await path.goToIndexed(1).timeout(const Duration(seconds: 5));

      expect(path.activeIndex, 1);
      expect(path.activeRoute, same(b));
      expect(b.calls, 1);
      expect([home.discards, b.discards], [0, 0]);
      // The value-equal instance ends the chain on the entry. resolve does not
      // discard it, as upstream does not; pinned so a change is visible.
      expect(created.single.discards, 0);
    });

    test('F2 a wrong-type redirect throws StateError', () async {
      final foreign = Dest('foreign');
      final a = NarrowTab('a');
      final b = WrongTypeTab('b', () => foreign);
      final path = IndexedStackPath<NarrowTab>.create([a, b], label: 'narrow');

      await expectLater(
        path.goToIndexed(1),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('expected NarrowTab'),
          ),
        ),
      );

      expect(path.activeIndex, 0);
      expect([a.discards, b.discards], [0, 0]);
    });

    test(
      'F2 a Stop, a redirect to an entry and a redirect out of the entries '
      'never discard an entry; only the unshown fresh target is discarded',
      () async {
        final outside = Dest('outside');
        final home = Dest('home');
        final a = Dest('a');
        final stop = SwitchTab('stop', () => null);
        final toA = SwitchTab('to-a', () => a);
        final out = SwitchTab('out', () => outside);
        final app = PlainApp([home, a, stop, toA, out]);
        final entries = [home, a, stop, toA, out];
        expect(app.redirectScopeOf(out), isEmpty);

        await app.tabs.goToIndexed(2);
        expect(app.tabs.activeIndex, 0);

        await app.tabs.goToIndexed(3);
        expect(app.tabs.activeIndex, 1);

        // Opted out: no assert, the switch is cancelled.
        await app.tabs.goToIndexed(4);
        expect(app.tabs.activeIndex, 1);

        expect(app.tabs.stack, sameEntries(entries));
        expect(outside.discards, 1);
        expect([for (final e in entries) e.discards], [0, 0, 0, 0, 0]);
        expect(app.root.stack, isEmpty);
      },
    );
  });

  group('F2 synchronous switch', () {
    test('F2 an entry with no redirect and no gating rules switches '
        'synchronously, as before', () async {
      final path = IndexedStackPath<ScopeRoute>.create([
        Dest('a'),
        Dest('b'),
      ], label: 'sync');
      final switching = path.goToIndexed(1);
      expect(path.activeIndex, 1);
      await switching;

      final app = PlainApp([Dest('home'), Dest('x')]);
      final switchingWithCoordinator = app.tabs.goToIndexed(1);
      expect(app.tabs.activeIndex, 1);
      await switchingWithCoordinator;
    });

    test('F2 in an opted-in tree goToIndexed offers a gated entry to the '
        'first rule synchronously', () async {
      final app = TabsApp();

      final switching = app.tabs.goToIndexed(1);
      // Read synchronously, like the opted-out pin in redirect_rule_test.dart.
      expect(app.log, ['app(b)']);

      await switching;
      expect(app.log, ['app(b)', 'tabs(b)']);
      expect(app.tabs.activeIndex, 1);
    });

    test('F2 in an opted-in tree an ungated branch root switches '
        'synchronously', () async {
      final app = BranchApp();
      final branches = app.module.branches;
      final switching = branches.goToBranch(1);
      expect(branches.activeBranchIndex, 1);
      await switching;
      expect(app.log, isEmpty);
    });
  });

  group('F2 (S9) a declaring module with an empty rule list', () {
    final trees = <String, TabsModuleBase Function(TabsRoot, List<ScopeRoute>)>{
      'without the mixin': PlainTabsModule.new,
      'with an empty rule list': EmptyRulesTabsModule.new,
    };

    test('S9 an entry with no redirect switches synchronously, as in the tree '
        'without the mixin', () async {
      for (final tree in trees.entries) {
        final app = TabsRoot(
          (c) => tree.value(c, [RootTabEntry('a'), RootTabEntry('b')]),
        );

        final switching = app.tabs.goToIndexed(1);
        expect(app.tabs.activeIndex, 1, reason: tree.key);
        await switching;
        expect(app.tabs.activeIndex, 1, reason: tree.key);
      }
      final empty = TabsRoot(
        (c) => EmptyRulesTabsModule(c, [RootTabEntry('a'), RootTabEntry('b')]),
      );
      expect(empty.redirectScopeOf(empty.tabs.stack[1]), [same(empty.module)]);
    });

    test('S9 an entry redirecting out of the tab set cancels the switch '
        'silently, as in the tree without the mixin', () async {
      for (final tree in trees.entries) {
        final outside = Dest('outside');
        final entries = [RootTabEntry('a'), OutTab('b', () => outside)];
        final app = TabsRoot((c) => tree.value(c, entries));

        await app.tabs.goToIndexed(1);

        expect(app.tabs.activeIndex, 0, reason: tree.key);
        expect(outside.discards, 1, reason: tree.key);
        expect([for (final e in entries) e.discards], [0, 0], reason: tree.key);
        expect(app.root.stack, isEmpty, reason: tree.key);
      }
    });
  });

  group('F2 BranchedStackPath.goToBranch', () {
    test('F2 goToBranch never offers branch roots to scoped rules', () async {
      final app = BranchApp();
      final module = app.module;
      final branches = module.branches;
      expect(app.redirectScopeOf(branches.stack[1]), isEmpty);
      expect(app.redirectScopeOf(SettingsItem('x')), [app, module]);

      // A module rule that stops every destination it is offered does not
      // block a branch switch: branch roots are layouts.
      app.branchRule.outcome = (_) => const RedirectResult.stop();

      await branches.goToBranch(1);
      expect(branches.activeBranchIndex, 1);
      await branches.goToBranch(0);
      expect(branches.activeBranchIndex, 0);
      expect(app.log, isEmpty);

      // A branch child is gated by the same rule.
      final blocked = SettingsItem('blocked');
      await app.pushSilently(blocked);

      expect(app.log, ['app(blocked)', 'branch(blocked)']);
      expect(blocked.discards, 1);
      expect(module.settingsPath.stack, isEmpty);
      expect(module.homePath.stack, isEmpty);
      expect(branches.activeBranchIndex, 0);
      expect(app.root.stack, isEmpty);

      // Let children through. The shell and the branch the operation mounts
      // on the way are still never offered to a rule.
      app.log.clear();
      app.branchRule.outcome = null;
      final prefs = SettingsItem('prefs');
      await app.pushSilently(prefs);

      expect(app.log, ['app(prefs)', 'branch(prefs)']);
      expect(branches.activeBranchIndex, 1);
      expect(module.settingsPath.stack, sameEntries([prefs]));
      expect(module.homePath.stack, isEmpty);
      expect(app.root.stack, [isA<BranchShell>()]);
      expect(prefs.discards, 0);
      expect([
        ...app.appRule.coordinators,
        ...app.branchRule.coordinators,
      ], everyElement(same(app)));
    });
  });
}
