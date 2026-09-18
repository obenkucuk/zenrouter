// Boundary tests for module-scoped redirect rules (RouteModuleRedirectRule).
//
// Test names carry the ids of the plan (C1-C19) and of the brief's extra
// boundary list (S6-S9, O3r, O4m, O5, O8, B-HOP). Every test drives the real
// coordinator, path and resolve code and asserts on the rule log, the full
// stacks, onDiscard counts and, where it applies, the hop boundary.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

import '../support/harness.dart';

// ===========================================================================
// Routes
// ===========================================================================

/// A destination that counts its `onDiscard` calls.
class CountingRoute extends AppRoute {
  CountingRoute(super.id, {super.parentLayoutKey});

  int discards = 0;

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }
}

/// A shell that resolves to whatever stack [pick] names when it is asked: a
/// guest shell and a member shell behind one layout key.
class SwitchingLayout extends AppLayout {
  SwitchingLayout(super.id, {required super.layoutKey, required this.pick})
    : super(path: pick());

  final StackPath Function() pick;

  @override
  StackPath resolvePath(covariant CoordinatorCore coordinator) => pick();
}

/// A destination with its own rule chain.
class RuledAppRoute extends CountingRoute
    with RouteRedirect<AppRoute>, RouteRedirectRule<AppRoute> {
  RuledAppRoute(super.id, this.rules, {super.parentLayoutKey});

  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

/// A destination whose own redirect returns a fresh [to] route, stops, or
/// returns itself.
class AliasRoute extends CountingRoute with RouteRedirect<AppRoute> {
  AliasRoute(super.id, {this.to, this.stop = false, super.parentLayoutKey});

  final AppRoute Function()? to;
  final bool stop;
  int calls = 0;

  @override
  FutureOr<AppRoute> redirect() {
    calls++;
    return to?.call() ?? this;
  }

  @override
  FutureOr<AppRoute?> redirectWith(CoordinatorCore coordinator) {
    calls++;
    if (stop) return null;
    return to?.call() ?? this;
  }
}

/// Returns itself from its own redirect: a terminal that still consults.
class SelfRedirectRoute extends CountingRoute with RouteRedirect<AppRoute> {
  SelfRedirectRoute(super.id, {super.parentLayoutKey});
}

/// `c0 → c1 → … → c(moves-1) → terminal()`: exactly [moves] moves driven by
/// the routes' own redirects, so it works in every tree. Every chain route
/// it creates is recorded in [created].
class ChainRoute extends CountingRoute with RouteRedirect<AppRoute> {
  ChainRoute(this.index, this.moves, this.terminal, this.created)
    : super('c$index') {
    created.add(this);
  }

  final int index;
  final int moves;
  final CountingRoute Function() terminal;
  final List<CountingRoute> created;

  AppRoute _next() => index + 1 == moves
      ? terminal()
      : ChainRoute(index + 1, moves, terminal, created);

  @override
  FutureOr<AppRoute> redirect() => _next();

  @override
  FutureOr<AppRoute?> redirectWith(CoordinatorCore coordinator) => _next();
}

/// `a → b → a → …` with a fresh, value-equal route on every hop.
class PingRoute extends CountingRoute with RouteRedirect<AppRoute> {
  PingRoute(super.id, this.created) {
    created.add(this);
  }

  final List<CountingRoute> created;

  AppRoute _next() => PingRoute(id == 'a' ? 'b' : 'a', created);

  @override
  FutureOr<AppRoute> redirect() => _next();

  @override
  FutureOr<AppRoute?> redirectWith(CoordinatorCore coordinator) => _next();
}

/// A destination whose own redirect throws [error].
class ThrowingRoute extends CountingRoute with RouteRedirect<AppRoute> {
  ThrowingRoute(super.id, this.error, {super.parentLayoutKey});

  final Object error;

  @override
  FutureOr<AppRoute> redirect() => throw error;

  @override
  FutureOr<AppRoute?> redirectWith(CoordinatorCore coordinator) => throw error;
}

/// Returns a fresh, value-equal instance of itself from its own redirect;
/// every instance it returns is recorded in [created].
class EchoRoute extends CountingRoute with RouteRedirect<AppRoute> {
  EchoRoute(super.id, this.created, {super.parentLayoutKey});

  final List<EchoRoute> created;

  AppRoute _next() {
    final echo = EchoRoute(id, created, parentLayoutKey: parentLayoutKey);
    created.add(echo);
    return echo;
  }

  @override
  FutureOr<AppRoute> redirect() => _next();

  @override
  FutureOr<AppRoute?> redirectWith(CoordinatorCore coordinator) => _next();
}

/// State a splash screen initialises.
class SplashSession {
  bool ready = false;
}

/// A route gated on [session]: until it is ready, it redirects to a
/// [SplashRoute] that forwards back to this very instance.
class GatedRoute extends CountingRoute with RouteRedirect<AppRoute> {
  GatedRoute(super.id, this.session, {super.parentLayoutKey});

  final SplashSession session;
  final splashes = <SplashRoute>[];

  AppRoute _next() {
    if (session.ready) return this;
    final splash = SplashRoute(session, this);
    splashes.add(splash);
    return splash;
  }

  @override
  FutureOr<AppRoute> redirect() => _next();

  @override
  FutureOr<AppRoute?> redirectWith(CoordinatorCore coordinator) => _next();
}

/// Finishes initialising [session] after an async gap, then forwards to the
/// original [next] instance.
class SplashRoute extends CountingRoute with RouteRedirect<AppRoute> {
  SplashRoute(this.session, this.next) : super('splash');

  final SplashSession session;
  final AppRoute next;

  Future<AppRoute> _next() async {
    await Future<void>.delayed(Duration.zero);
    session.ready = true;
    return next;
  }

  @override
  Future<AppRoute> redirect() => _next();

  @override
  Future<AppRoute?> redirectWith(CoordinatorCore coordinator) => _next();
}

/// The only route type the vault stack hosts.
class VaultRoute extends CountingRoute {
  VaultRoute(super.id) : super(parentLayoutKey: 'vaultShell');
}

// ===========================================================================
// Rules
// ===========================================================================

class ContinueRule extends RedirectRule<AppRoute> {
  const ContinueRule();

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) => const RedirectResult.continueRedirect();
}

/// Redirects every route it is offered to a fresh [to] route.
class ToRule extends RedirectRule<AppRoute> {
  ToRule(this.to);

  final AppRoute Function() to;

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) => RedirectResult.redirectTo(to());
}

/// Walks `hop-0 → hop-1 → … → hop-(limit-1) → done`, exactly [limit]
/// moves, keeping every route behind [layoutKey].
class HopRule extends RedirectRule<AppRoute> {
  HopRule(this.limit, {this.layoutKey});

  final int limit;
  final Object? layoutKey;

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    final id = route.id;
    if (!id.startsWith('hop-')) return const RedirectResult.continueRedirect();
    final n = int.parse(id.substring(4));
    return RedirectResult.redirectTo(
      AppRoute(
        n + 1 >= limit ? 'done' : 'hop-${n + 1}',
        parentLayoutKey: layoutKey,
      ),
    );
  }
}

/// Logs a synchronous rule once, and an asynchronous one (with a [delay])
/// at its start and at its end, so any reordering across awaits shows.
class OrderedRule extends RedirectRule<AppRoute> {
  OrderedRule(this.name, this.log, {this.delay, this.outcome});

  final String name;
  final List<String> log;
  final Duration? delay;
  final RedirectResult<AppRoute> Function(AppRoute route)? outcome;

  @override
  FutureOr<RedirectResult<AppRoute>> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    final verdict =
        outcome?.call(route) ??
        const RedirectResult<AppRoute>.continueRedirect();
    final delay = this.delay;
    if (delay == null) {
      log.add('$name(${route.id})');
      return verdict;
    }
    return () async {
      log.add('$name:start(${route.id})');
      await Future<void>.delayed(delay);
      log.add('$name:end(${route.id})');
      return verdict;
    }();
  }
}

/// A rule typed to the vault's own route base. Being offered any other
/// route would throw a TypeError.
class VaultOnlyRule extends RedirectRule<VaultRoute> {
  int calls = 0;

  @override
  FutureOr<RedirectResult<VaultRoute>> redirectResult(
    CoordinatorCore coordinator,
    VaultRoute route,
  ) {
    calls++;
    return const RedirectResult.continueRedirect();
  }
}

// ===========================================================================
// Modules (one runtime type per module of a level: defineModules rejects
// duplicate module types)
// ===========================================================================

class ShopCoordinator extends ScopedNested {
  ShopCoordinator(super.parent, {required super.rules})
    : super(extraLabel: 'shop');
}

class FeedCoordinator extends NestedCoordinator {
  FeedCoordinator(super.parent) : super(extraLabel: 'feed');
}

class AuthCoordinator extends ScopedNested {
  AuthCoordinator(super.parent, {required super.rules, super.childModules})
    : super(extraLabel: 'auth');
}

class SecModule extends ScopedFeature {
  SecModule(super.coordinator, {required super.rules})
    : super(prefix: 'sec', hasPath: true);
}

class PlainShop extends NestedCoordinator {
  PlainShop(super.parent) : super(extraLabel: 'shop');
}

class PlainAuth extends NestedCoordinator {
  PlainAuth(super.parent, {super.childModules}) : super(extraLabel: 'auth');
}

class PlainSec extends FeatureModule {
  PlainSec(super.coordinator) : super(prefix: 'sec', hasPath: true);
}

class OuterCoordinator extends ScopedNested {
  OuterCoordinator(
    super.parent, {
    required super.rules,
    super.childModulesBuilder,
  }) : super(extraLabel: 'outer');
}

class InnerCoordinator extends ScopedNested {
  InnerCoordinator(
    super.parent, {
    required super.rules,
    super.childModulesBuilder,
  }) : super(extraLabel: 'inner');
}

class FeatUnderInner extends ScopedFeature {
  FeatUnderInner(super.coordinator, {required super.rules})
    : super(prefix: 'feat', hasPath: true);
}

class ModCoordinator extends NestedCoordinator {
  ModCoordinator(super.parent) : super(extraLabel: 'mod');
}

class ScopedModCoordinator extends ScopedNested {
  ScopedModCoordinator(super.parent, {required super.rules})
    : super(extraLabel: 'mod');
}

class GapCoordinator extends NestedCoordinator {
  GapCoordinator(super.parent, {super.childModulesBuilder})
    : super(extraLabel: 'gap');
}

class BelowGap extends ScopedNested {
  BelowGap(super.parent, {required super.rules}) : super(extraLabel: 'below');
}

class VaultCoordinator extends ScopedNested {
  VaultCoordinator(super.parent, {required super.rules})
    : super(extraLabel: 'vault');
}

/// A plain module that lists exactly [listed].
class ListingA extends FeatureModule {
  ListingA(super.coordinator, this.listed) : super(prefix: 'listing-a');

  final List<StackPath> listed;

  @override
  List<StackPath> get paths => listed;
}

/// A second plain module type that lists exactly [listed].
class ListingB extends FeatureModule {
  ListingB(super.coordinator, this.listed) : super(prefix: 'listing-b');

  final List<StackPath> listed;

  @override
  List<StackPath> get paths => listed;
}

/// A parse-only declaring module with no stack (the BlogPostsModule shape).
class BlogPostsModule extends ScopedFeature {
  BlogPostsModule(super.coordinator)
    : super(rules: [const ContinueRule()], prefix: 'blog');
}

/// A declaring module that lists the root stack.
class RootListing extends ScopedFeature {
  RootListing(super.coordinator)
    : super(rules: const [], prefix: 'root-listing');

  @override
  List<StackPath> get paths => [coordinator.root];
}

/// A declaring module coordinator with no stack of its own; its sub-module
/// owns one.
class PathlessScoped extends ScopedNested {
  PathlessScoped(super.parent, {required super.rules, super.childModules})
    : super(extraLabel: 'pathless');

  @override
  List<StackPath> get paths => [
    for (final path in super.paths)
      if (!identical(path, extra)) path,
  ];
}

class SubOwner extends ScopedFeature {
  SubOwner(super.coordinator, {required super.rules})
    : super(prefix: 'sub', hasPath: true);
}

/// A declaring plain module that lists exactly [claimed].
class ClaimsStack extends ScopedFeature {
  ClaimsStack(super.coordinator, this.claimed, {required super.rules})
    : super(prefix: 'claims');

  final StackPath claimed;

  @override
  List<StackPath> get paths => [claimed];
}

/// A module coordinator whose `coordinator` getter throws a
/// NoSuchMethodError once [broken], like user code making a dynamic call on
/// a handle that is not wired yet.
class NsmModule extends ScopedNested {
  NsmModule(super.parent) : super(rules: const [], extraLabel: 'nsm');

  bool broken = false;
  dynamic registry;

  @override
  CoordinatorModular<AppRoute> get coordinator => broken
      ? registry.parentOf(this) as CoordinatorModular<AppRoute>
      : super.coordinator;
}

/// A test double that only implements the [CoordinatorModular] interface,
/// like a mock handed to a real module as its parent.
class DoubleParent implements CoordinatorModular<AppRoute> {
  DoubleParent(this.root);

  @override
  final StackPath<AppRoute> root;

  @override
  Uri get currentUri => Uri.parse('/');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An app coordinator with a member of its own named `registeredModules`,
/// as an app written against 3.0.0-beta.1 may have.
class OwnRegistryApp extends ScopedModularApp {
  OwnRegistryApp({required super.rules, super.modules});

  /// The app's own bookkeeping, unrelated to the redirect scope.
  final Set<Type> registeredModules = {};
}

// ===========================================================================
// Fixtures
// ===========================================================================

/// The tree of the plan's C1:
///
/// ```
/// app  (declares 'app')                 owns root, nested
/// ├── shop  (declares 'shop')           owns shop
/// ├── feed  (declares nothing)          owns feed
/// └── auth  (declares 'auth')           owns auth
///     └── sec  (plain, declares 'sec')  owns sec
/// ```
///
/// Shells registered on the root host each module stack. Destinations: home
/// (no layout, root stack), cart (shop), post (feed), profile (auth) and
/// totp (sec).
class Fixture {
  Fixture() {
    app = ScopedModularApp(
      rules: appRules,
      modules: (c) => [
        shop = ShopCoordinator(c, rules: shopRules),
        feed = FeedCoordinator(c),
        auth = AuthCoordinator(
          c,
          rules: authRules,
          childModules: [sec = SecModule(c, rules: secRules)],
        ),
      ],
    );
    app.registerShell(key: 'shopShell', path: shop.extra);
    app.registerShell(key: 'feedShell', path: feed.extra);
    app.registerShell(key: 'authShell', path: auth.extra);
    app.registerShell(key: 'secShell', path: sec.featurePath);
  }

  final log = <String>[];
  late final appRule = RecordingRule('app', log);
  late final shopRule = RecordingRule('shop', log);
  late final authRule = RecordingRule('auth', log);
  late final secRule = RecordingRule('sec', log);
  late final appRules = <RedirectRule>[appRule];
  late final shopRules = <RedirectRule>[shopRule];
  late final authRules = <RedirectRule>[authRule];
  late final secRules = <RedirectRule>[secRule];

  late final ScopedModularApp app;
  late final ShopCoordinator shop;
  late final FeedCoordinator feed;
  late final AuthCoordinator auth;
  late final SecModule sec;

  List<RecordingRule> get rules => [appRule, shopRule, authRule, secRule];
}

/// The C1 tree with no mixin anywhere: the opted-out reference.
class PlainFixture {
  PlainFixture() {
    app = ModularAppCoordinator(
      modules: (c) => [
        shop = PlainShop(c),
        feed = FeedCoordinator(c),
        auth = PlainAuth(c, childModules: [sec = PlainSec(c)]),
      ],
    );
    app.registerShell(key: 'shopShell', path: shop.extra);
    app.registerShell(key: 'feedShell', path: feed.extra);
    app.registerShell(key: 'authShell', path: auth.extra);
    app.registerShell(key: 'secShell', path: sec.featurePath);
  }

  final log = <String>[];
  late final ModularAppCoordinator app;
  late final PlainShop shop;
  late final FeedCoordinator feed;
  late final PlainAuth auth;
  late final PlainSec sec;
}

/// Two coordinator levels plus a plain module below the second:
///
/// ```
/// app (declares 'app')
/// └── outer (declares 'outer')              owns outer
///     └── inner (declares 'inner')          owns inner
///         └── feat (plain, declares 'feat') owns feat
/// ```
///
/// inner's stack reports `coordinator == outer` and feat stores outer as its
/// coordinator: both are one hop only, which is why the scope walks the
/// registry instead.
class DeepFixture {
  DeepFixture() {
    app = ScopedModularApp(
      rules: [RecordingRule('app', log)],
      modules: (c) => [
        outer = OuterCoordinator(
          c,
          rules: [RecordingRule('outer', log)],
          childModulesBuilder: (self) => [
            inner = InnerCoordinator(
              self,
              rules: [RecordingRule('inner', log)],
              childModulesBuilder: (self) => [
                feat = FeatUnderInner(
                  self,
                  rules: [RecordingRule('feat', log)],
                ),
              ],
            ),
          ],
        ),
      ],
    );
    app.registerShell(key: 'outerShell', path: outer.extra);
    app.registerShell(key: 'innerShell', path: inner.extra);
    app.registerShell(key: 'featShell', path: feat.featurePath);
  }

  final log = <String>[];
  late final ScopedModularApp app;
  late final OuterCoordinator outer;
  late final InnerCoordinator inner;
  late final FeatUnderInner feat;
}

/// One module tree for the hop-budget matrix; [log] is fed by its rules, if
/// it has any.
typedef HopTree = ({ModularAppCoordinator app, List<String> log});

HopTree optedOutTree() {
  final app = ModularAppCoordinator(modules: (c) => [ModCoordinator(c)]);
  app.registerShell(
    key: 'modShell',
    path: app.getModule<ModCoordinator>().extra,
  );
  return (app: app, log: <String>[]);
}

HopTree optedInWithRules() {
  final log = <String>[];
  final app = ScopedModularApp(
    rules: [RecordingRule('app', log)],
    modules: (c) => [
      ScopedModCoordinator(c, rules: [RecordingRule('mod', log)]),
    ],
  );
  app.registerShell(
    key: 'modShell',
    path: app.getModule<ScopedModCoordinator>().extra,
  );
  return (app: app, log: log);
}

HopTree optedInEmpty() {
  final app = ScopedModularApp(
    rules: [],
    modules: (c) => [ScopedModCoordinator(c, rules: [])],
  );
  app.registerShell(
    key: 'modShell',
    path: app.getModule<ScopedModCoordinator>().extra,
  );
  return (app: app, log: <String>[]);
}

// ===========================================================================
// Helpers
// ===========================================================================

AppRoute home() => AppRoute('home');
AppRoute cart() => AppRoute('cart', parentLayoutKey: 'shopShell');
AppRoute post() => AppRoute('post', parentLayoutKey: 'feedShell');
AppRoute profile() => AppRoute('profile', parentLayoutKey: 'authShell');
AppRoute totp() => AppRoute('totp', parentLayoutKey: 'secShell');

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Every path of [coordinator], by debug label, as route ids.
Map<String, List<String>> stacksOf(CoordinatorCore coordinator) => {
  for (final path in coordinator.paths)
    path.debugLabel!: [for (final route in path.stack) (route as AppRoute).id],
};

/// The full stacks of the C1 tree; unnamed stacks are empty.
Map<String, List<String>> c1Stacks({
  List<String> root = const [],
  List<String> nested = const [],
  List<String> shop = const [],
  List<String> feed = const [],
  List<String> sec = const [],
  List<String> auth = const [],
}) => {
  'root': root,
  'nested': nested,
  'shop': shop,
  'feed': feed,
  'sec': sec,
  'auth': auth,
};

void resetAll(CoordinatorCore coordinator) {
  for (final path in coordinator.paths) {
    path.reset();
  }
}

/// Every path's entries, by identity.
List<(String, List<RouteTarget>)> snapshotOf(CoordinatorCore coordinator) => [
  for (final path in coordinator.paths)
    (path.debugLabel ?? '$path', List.of(path.stack)),
];

void expectSameStacks(
  List<(String, List<RouteTarget>)> after,
  List<(String, List<RouteTarget>)> before, {
  required String reason,
}) {
  expect(after.length, before.length, reason: reason);
  for (var i = 0; i < before.length; i++) {
    final (label, entries) = before[i];
    expect(after[i].$1, label, reason: reason);
    expect(after[i].$2.length, entries.length, reason: '$reason, $label');
    for (var j = 0; j < entries.length; j++) {
      expect(after[i].$2[j], same(entries[j]), reason: '$reason, $label[$j]');
    }
  }
}

/// [log] is one or more back-to-back repetitions of [pass].
void expectRepetitionOf(
  List<String> log,
  List<String> pass, {
  required String reason,
}) {
  expect(log, isNotEmpty, reason: reason);
  expect(log.length % pass.length, 0, reason: '$reason: $log');
  for (var i = 0; i < log.length; i++) {
    expect(log[i], pass[i % pass.length], reason: '$reason: $log');
  }
}

Matcher throwsStateErrorWith(List<String> parts) => throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'message',
    allOf([for (final part in parts) contains(part)]),
  ),
);

/// Resolves a chain of exactly [moves] moves ending on [terminal] and
/// describes the outcome, the discards of every fresh route and the
/// terminal's discards.
Future<String> hopOutcome(
  CoordinatorCore coordinator,
  int moves,
  CountingRoute Function() terminal,
) async {
  final created = <CountingRoute>[];
  CountingRoute? last;
  String outcome;
  try {
    final resolved = await RouteRedirect.resolve<AppRoute>(
      ChainRoute(0, moves, () => last = terminal(), created),
      coordinator,
    );
    outcome =
        'resolved ${resolved!.id}, same terminal: '
        '${identical(resolved, last)}';
  } on StateError catch (error) {
    outcome = 'threw ${error.message}';
  }
  final onceEach = created.every((route) => route.discards == 1);
  return '$outcome; ${created.length} intermediates, each discarded once: '
      '$onceEach; terminal discards ${last?.discards}';
}

/// Resolves `a → b → a` with fresh routes and describes the outcome.
Future<String> cycleOutcome(CoordinatorCore coordinator) async {
  final created = <CountingRoute>[];
  String outcome;
  try {
    await RouteRedirect.resolve<AppRoute>(PingRoute('a', created), coordinator);
    outcome = 'resolved';
  } on StateError catch (error) {
    outcome = 'threw ${error.message}';
  }
  final onceEach = created.every((route) => route.discards == 1);
  return '$outcome; ${created.length} routes, each discarded once: $onceEach';
}

const hop20 =
    'resolved t, same terminal: true; 20 intermediates, each discarded once: '
    'true; terminal discards 0';
const hop21 =
    'threw RouteRedirect loop detected after 20 hops starting from '
    'AppRoute(c0); 21 intermediates, each discarded once: true; terminal '
    'discards 1';
const cycle =
    'threw RouteRedirect loop detected after 2 hops starting from '
    'AppRoute(a); 4 routes, each discarded once: true';

/// Navigation on the root stack only, described by its observable effects.
Future<Map<String, Object?>> rootStackScript(ModularAppCoordinator app) async {
  final homeRoute = CountingRoute('home');
  await app.pushSilently(homeRoute);

  late CountingRoute target;
  final alias = AliasRoute('alias', to: () => target = CountingRoute('target'));
  final aliasResult = await RouteRedirect.resolve<AppRoute>(alias, app);

  final stopped = AliasRoute('stopped', stop: true);
  final stoppedResult = await RouteRedirect.resolve<AppRoute>(stopped, app);

  final self = AliasRoute('self');
  final selfResult = await RouteRedirect.resolve<AppRoute>(self, app);

  await app.pushSilently(
    AliasRoute('pushed-alias', to: () => CountingRoute('pushed-target')),
  );

  return {
    'stacks': stacksOf(app),
    'home.discards': homeRoute.discards,
    'alias': [
      aliasResult?.id,
      identical(aliasResult, target),
      alias.calls,
      alias.discards,
      target.discards,
    ],
    'stopped': [stoppedResult, stopped.calls, stopped.discards],
    'self': [identical(selfResult, self), self.calls, self.discards],
    'hops': [
      await hopOutcome(app, 20, () => CountingRoute('t')),
      await hopOutcome(app, 21, () => CountingRoute('t')),
      await hopOutcome(app, 20, () => SelfRedirectRoute('t')),
      await hopOutcome(app, 21, () => SelfRedirectRoute('t')),
      await cycleOutcome(app),
    ],
  };
}

/// Navigation through a module that owns 'mod' behind 'modShell', described
/// by its observable effects.
Future<Map<String, Object?>> moduleScript(
  ModularAppCoordinator app,
  NestedCoordinator mod,
) async {
  final routes = <String, CountingRoute>{};
  T track<T extends CountingRoute>(T route, [String? key]) =>
      routes[key ?? route.id] = route;

  await app.pushSilently(track(CountingRoute('home')));
  await app.pushSilently(
    track(CountingRoute('inside', parentLayoutKey: 'modShell')),
  );
  await mod.pushSilently(
    track(CountingRoute('via-module', parentLayoutKey: 'modShell')),
  );
  await mod.extra.pushSilently(
    track(CountingRoute('path-level', parentLayoutKey: 'modShell')),
  );
  // Layout-less, committed at path level into the module's stack.
  await mod.extra.pushSilently(track(CountingRoute('foreign')));
  final alias = track(
    AliasRoute(
      'alias',
      parentLayoutKey: 'modShell',
      to: () => track(CountingRoute('landed', parentLayoutKey: 'modShell')),
    ),
  );
  await app.pushSilently(alias);
  final stopped = track(
    AliasRoute('stopped', stop: true, parentLayoutKey: 'modShell'),
  );
  await app.pushSilently(stopped);
  // An equal new instance: pops back to 'inside' and discards the newcomer.
  await app.navigate(
    track(CountingRoute('inside', parentLayoutKey: 'modShell'), 'inside#2'),
  );

  return {
    'stacks': stacksOf(app),
    'discards': {
      for (final entry in routes.entries) entry.key: entry.value.discards,
    },
    'alias.calls': alias.calls,
    'stopped.calls': stopped.calls,
    'hops': [
      await hopOutcome(
        app,
        20,
        () => CountingRoute('t', parentLayoutKey: 'modShell'),
      ),
      await hopOutcome(
        app,
        21,
        () => CountingRoute('t', parentLayoutKey: 'modShell'),
      ),
      await hopOutcome(
        app,
        20,
        () => SelfRedirectRoute('t', parentLayoutKey: 'modShell'),
      ),
      await hopOutcome(
        app,
        21,
        () => SelfRedirectRoute('t', parentLayoutKey: 'modShell'),
      ),
      await cycleOutcome(app),
    ],
  };
}

void main() {
  // =========================================================================
  // C: scope, order and entry points
  // =========================================================================
  group('C scope, chain and entry points', () {
    test(
      'C1 (S1, S2) root rules gate every destination, even one whose module declares nothing',
      () async {
        final f = Fixture();

        for (final (route, chain) in [
          (home(), ['app(home)']),
          (cart(), ['app(cart)', 'shop(cart)']),
          (post(), ['app(post)']),
          (profile(), ['app(profile)', 'auth(profile)']),
          (totp(), ['app(totp)', 'auth(totp)', 'sec(totp)']),
        ]) {
          f.log.clear();
          final resolved = await RouteRedirect.resolve(route, f.app);
          expect(resolved, same(route), reason: route.id);
          expect(f.log, chain, reason: route.id);
        }
        expect(stacksOf(f.app), c1Stacks());
      },
    );

    test(
      'C2 (S4) owner scenario: a feed route never reaches the shop rule, whatever the call site',
      () async {
        final f = Fixture();

        await f.app.pushSilently(post());
        await f.shop.pushSilently(post());
        await f.feed.pushSilently(post());
        await f.feed.extra.pushSilently(post());
        expect(f.log, ['app(post)', 'app(post)', 'app(post)', 'app(post)']);
        expect(f.shopRule.coordinators, isEmpty);

        f.log.clear();
        await f.feed.pushSilently(cart());
        await f.auth.pushSilently(cart());
        expect(f.log, ['app(cart)', 'shop(cart)', 'app(cart)', 'shop(cart)']);
        expect(f.authRule.coordinators, isEmpty);

        expect(
          stacksOf(f.app),
          c1Stacks(
            root: ['feedShell', 'shopShell'],
            feed: ['post', 'post', 'post', 'post'],
            shop: ['cart', 'cart'],
          ),
        );
      },
    );

    test(
      'C3 (S5) user scenario: a root-stack route never reaches the auth or sec rules',
      () async {
        final f = Fixture();

        await f.app.pushSilently(home());
        await f.auth.pushSilently(home());
        expect(f.log, ['app(home)', 'app(home)']);

        f.log.clear();
        await f.app.pushSilently(profile());
        expect(f.log, ['app(profile)', 'auth(profile)']);
        expect(f.secRule.coordinators, isEmpty);

        expect(
          stacksOf(f.app),
          c1Stacks(root: ['home', 'home', 'authShell'], auth: ['profile']),
        );
      },
    );

    test(
      'C4 every coordinator and path entry point computes the same chain for profile',
      () async {
        final f = Fixture();
        // A plain module stores its parent's rootCoordinator, one hop up:
        // sec's is the root itself, so it adds no call site of its own. The
        // plain module two levels down is driven at the end of this test.
        expect(f.sec.coordinator, same(f.app));

        final sites = <String, CoordinatorRecoverable<AppRoute>>{
          'root': f.app,
          'auth': f.auth,
          'shop': f.shop,
          'feed': f.feed,
        };
        final ops =
            <
              String,
              Future<void> Function(CoordinatorRecoverable<AppRoute>, AppRoute)
            >{
              'push': (c, r) async {
                unawaited(c.push(r));
                await settle();
              },
              'pushSilently': (c, r) => c.pushSilently(r),
              'pushOrMoveToTop': (c, r) => c.pushOrMoveToTop(r),
              'pushReplacement': (c, r) async {
                unawaited(c.pushReplacement(r));
                await settle();
              },
              'replace': (c, r) => c.replace(r),
              'navigate': (c, r) => c.navigate(r),
              'recover': (c, r) => c.recover(r),
            };

        void clearRecords() {
          f.log.clear();
          for (final rule in f.rules) {
            rule.coordinators.clear();
          }
        }

        void expectChain(String label) {
          expectRepetitionOf(f.log, [
            'app(profile)',
            'auth(profile)',
          ], reason: label);
          for (final rule in f.rules) {
            expect(rule.coordinators, everyElement(same(f.app)), reason: label);
          }
        }

        for (final site in sites.entries) {
          for (final op in ops.entries) {
            final label = '${op.key} via ${site.key}';
            resetAll(f.app);
            clearRecords();
            await op.value(site.value, profile());
            expectChain(label);
            expect(f.auth.extra.stack.last.id, 'profile', reason: label);
          }
        }

        final pathOps = <String, Future<void> Function(AppStackPath, AppRoute)>{
          'push': (p, r) async {
            unawaited(p.push(r));
            await settle();
          },
          'pushSilently': (p, r) => p.pushSilently(r),
          'pushOrMoveToTop': (p, r) => p.pushOrMoveToTop(r),
          'pushReplacement': (p, r) async {
            unawaited(p.pushReplacement(r));
            await settle();
          },
          'navigate': (p, r) => p.navigate(r),
        };
        for (final op in pathOps.entries) {
          final label = 'auth.extra.${op.key}';
          resetAll(f.app);
          clearRecords();
          await op.value(f.auth.extra, profile());
          expectChain(label);
          expect(stacksOf(f.app), c1Stacks(auth: ['profile']), reason: label);
        }

        resetAll(f.app);
        clearRecords();
        unawaited((f.app.root as AppStackPath).push(profile()));
        await settle();
        expectChain('root.push');
        expect(
          stacksOf(f.app),
          c1Stacks(root: ['profile']),
          reason:
              'a path-level push commits where it was called; profile gates '
              'cover the root stack owner, so no debug assert',
        );

        resetAll(f.app);
        clearRecords();
        await expectLater(
          f.shop.extra.push<Object>(profile()),
          throwsA(isA<AssertionError>()),
          reason: 'the shop rules never ran for profile (D1)',
        );
        expectChain('shop.extra.push');
        expect(stacksOf(f.app), c1Stacks());

        // The plain module two levels down stores the level-1 module
        // coordinator, an independent call site: every coordinator entry
        // point through it gives a route of the inner stack its full chain.
        final d = DeepFixture();
        expect(d.feat.coordinator, same(d.outer));
        for (final op in ops.entries) {
          final label = '${op.key} via feat.coordinator';
          resetAll(d.app);
          // Mount the shell first, as a user would have reached it.
          await d.app.pushSilently(
            AppRoute('x', parentLayoutKey: 'innerShell'),
          );
          d.log.clear();

          await op.value(
            d.feat.coordinator as CoordinatorRecoverable<AppRoute>,
            AppRoute('y', parentLayoutKey: 'innerShell'),
          );

          expectRepetitionOf(d.log, [
            'app(y)',
            'outer(y)',
            'inner(y)',
          ], reason: label);
          expect(d.inner.extra.stack.last.id, 'y', reason: label);
        }
      },
    );

    test(
      'C5 (O1, O2) order is root, enclosing module, owning module, route own; the first non-continue wins',
      () async {
        final f = Fixture();
        RuledAppRoute route() => RuledAppRoute('totp', [
          RecordingRule('own', f.log),
        ], parentLayoutKey: 'secShell');

        final passing = route();
        expect(await RouteRedirect.resolve(passing, f.app), same(passing));
        expect(f.log, ['app(totp)', 'auth(totp)', 'sec(totp)', 'own(totp)']);
        expect(passing.discards, 0);

        f.log.clear();
        f.appRule.outcome = (_) => const RedirectResult.stop();
        final stoppedAtRoot = route();
        expect(await RouteRedirect.resolve(stoppedAtRoot, f.app), isNull);
        expect(f.log, ['app(totp)']);
        expect(stoppedAtRoot.discards, 1);

        f.log.clear();
        f.appRule.outcome = null;
        f.authRule.outcome = (_) => const RedirectResult.stop();
        final stoppedAtAuth = route();
        expect(await RouteRedirect.resolve(stoppedAtAuth, f.app), isNull);
        expect(f.log, ['app(totp)', 'auth(totp)']);
        expect(stoppedAtAuth.discards, 1);
        expect(stacksOf(f.app), c1Stacks());
      },
    );

    test(
      'C6 (O3) a RedirectTo target is resolved from the top, in its own scope',
      () async {
        final f = Fixture();
        f.authRule.outcome = (r) => r.id == 'profile'
            ? RedirectResult.redirectTo(CountingRoute('login'))
            : const RedirectResult.continueRedirect();
        final requested = CountingRoute(
          'profile',
          parentLayoutKey: 'authShell',
        );

        unawaited(f.app.push(requested));
        await settle();

        expect(f.log, ['app(profile)', 'auth(profile)', 'app(login)']);
        expect(stacksOf(f.app), c1Stacks(root: ['login']));
        expect(requested.discards, 1);
        expect((f.app.root.stack.single as CountingRoute).discards, 0);
      },
    );

    test(
      'C7 (O6) a root rule hop chain resolves at 20 moves and throws at the 21st',
      () async {
        final done = await RouteRedirect.resolve(
          AppRoute('hop-0'),
          ScopedModularApp(rules: [HopRule(20)]),
        );
        expect(done?.id, 'done');

        await expectLater(
          RouteRedirect.resolve(
            AppRoute('hop-0'),
            ScopedModularApp(rules: [HopRule(21)]),
          ),
          throwsStateErrorWith(['RouteRedirect loop detected after 20 hops']),
        );
      },
    );

    test(
      'C7 (O6) a module rule hop chain inside its own stack has the same boundary',
      () async {
        for (final (limit, resolves) in [(20, true), (21, false)]) {
          late ScopedModCoordinator mod;
          final app = ScopedModularApp(
            rules: [],
            modules: (c) => [
              mod = ScopedModCoordinator(
                c,
                rules: [HopRule(limit, layoutKey: 'modShell')],
              ),
            ],
          );
          app.registerShell(key: 'modShell', path: mod.extra);
          final start = AppRoute('hop-0', parentLayoutKey: 'modShell');

          if (resolves) {
            await app.pushSilently(start);
            expect(stacksOf(app), {
              'root': ['modShell'],
              'nested': <String>[],
              'mod': ['done'],
            });
          } else {
            await expectLater(
              app.pushSilently(start),
              throwsStateErrorWith([
                'RouteRedirect loop detected after 20 hops',
              ]),
            );
            expect(stacksOf(app), {
              'root': <String>[],
              'nested': <String>[],
              'mod': <String>[],
            });
          }
        }
      },
    );

    test(
      'C8 (O6) a cross-module ping-pong throws and discards every fresh route exactly once',
      () async {
        final f = Fixture();
        final created = <CountingRoute>[];
        CountingRoute newCart() {
          final route = CountingRoute('cart', parentLayoutKey: 'shopShell');
          created.add(route);
          return route;
        }

        RuledAppRoute newPost() {
          final route = RuledAppRoute('post', [
            ToRule(newCart),
          ], parentLayoutKey: 'feedShell');
          created.add(route);
          return route;
        }

        f.shopRule.outcome = (r) => r.id == 'cart'
            ? RedirectResult.redirectTo(newPost())
            : const RedirectResult.continueRedirect();

        await expectLater(
          f.app.pushSilently(newCart()),
          throwsStateErrorWith(['RouteRedirect loop detected after 2 hops']),
        );

        expect(f.log, [
          'app(cart)',
          'shop(cart)',
          'app(post)',
          'app(cart)',
          'shop(cart)',
        ]);
        expect(created.map((r) => '${r.id}:${r.discards}'), [
          'cart:1',
          'post:1',
          'cart:1',
          'post:1',
        ]);
        expect(stacksOf(f.app), c1Stacks());
      },
    );

    test('C9 (O7) layout parents are never offered to any chain', () async {
      final f = Fixture();

      await f.app.pushSilently(cart());
      await f.app.pushSilently(profile());
      await f.app.pushSilently(totp());

      expect(f.log, [
        'app(cart)',
        'shop(cart)',
        'app(profile)',
        'auth(profile)',
        'app(totp)',
        'auth(totp)',
        'sec(totp)',
      ]);
      expect(
        stacksOf(f.app),
        c1Stacks(
          root: ['shopShell', 'authShell', 'secShell'],
          shop: ['cart'],
          auth: ['profile'],
          sec: ['totp'],
        ),
      );
      for (final shell in f.app.root.stack) {
        expect(f.app.redirectScopeOf(shell), isEmpty, reason: shell.id);
        expect(f.auth.redirectScopeOf(shell), isEmpty, reason: shell.id);
      }
    });

    test(
      'C10 (S3) two coordinator levels: every call site runs root, outer, inner',
      () async {
        final d = DeepFixture();
        expect(d.inner.extra.coordinator, same(d.outer));
        expect(d.feat.coordinator, same(d.outer));

        await d.app.pushSilently(AppRoute('x', parentLayoutKey: 'innerShell'));
        await d.inner.pushSilently(
          AppRoute('y', parentLayoutKey: 'innerShell'),
        );
        await d.inner.extra.pushSilently(
          AppRoute('z', parentLayoutKey: 'innerShell'),
        );
        expect(d.log, [
          'app(x)',
          'outer(x)',
          'inner(x)',
          'app(y)',
          'outer(y)',
          'inner(y)',
          'app(z)',
          'outer(z)',
          'inner(z)',
        ]);

        d.log.clear();
        await d.app.pushSilently(AppRoute('o', parentLayoutKey: 'outerShell'));
        expect(d.log, ['app(o)', 'outer(o)']);

        d.log.clear();
        await d.app.pushSilently(AppRoute('f', parentLayoutKey: 'featShell'));
        expect(d.log, ['app(f)', 'outer(f)', 'inner(f)', 'feat(f)']);

        expect(stacksOf(d.app), {
          'root': ['innerShell', 'outerShell', 'featShell'],
          'nested': <String>[],
          'feat': ['f'],
          'inner': ['x', 'y', 'z'],
          'outer': ['o'],
        });
      },
    );

    test(
      'C11 (I1) two roots from the same module types never cross-talk, and building the second does not repoint the first',
      () async {
        final a = Fixture();
        final b = Fixture();

        await a.app.pushSilently(profile());
        await a.auth.extra.pushSilently(profile());
        await a.shop.pushSilently(cart());
        expect(a.log, [
          'app(profile)',
          'auth(profile)',
          'app(profile)',
          'auth(profile)',
          'app(cart)',
          'shop(cart)',
        ]);
        expect(b.log, isEmpty);

        await b.app.pushSilently(totp());
        expect(b.log, ['app(totp)', 'auth(totp)', 'sec(totp)']);
        expect(a.log, hasLength(6));

        for (final rule in a.rules) {
          expect(rule.coordinators, everyElement(same(a.app)));
        }
        for (final rule in b.rules) {
          expect(rule.coordinators, everyElement(same(b.app)));
        }
        expect(a.app.redirectScopeOf(profile()), [same(a.app), same(a.auth)]);
        expect(b.app.redirectScopeOf(profile()), [same(b.app), same(b.auth)]);
        expect(
          stacksOf(a.app),
          c1Stacks(
            root: ['authShell', 'shopShell'],
            auth: ['profile', 'profile'],
            shop: ['cart'],
          ),
        );
        expect(stacksOf(b.app), c1Stacks(root: ['secShell'], sec: ['totp']));
      },
    );

    test(
      "C11 (I1) a stack created for root A and listed by a module of root B fails B's build (B4), A unaffected",
      () async {
        final a = Fixture();
        final foreign = AppStackPath(coordinator: a.app, debugLabel: 'foreign');
        final b = ScopedModularApp(
          rules: [],
          modules: (c) => [
            ListingA(c, [foreign]),
          ],
        );

        await expectLater(
          b.pushSilently(AppRoute('home')),
          throwsStateErrorWith(["stack 'foreign'", 'not part of this tree']),
        );

        await a.app.pushSilently(profile());
        expect(a.log, ['app(profile)', 'auth(profile)']);
        expect(
          stacksOf(a.app),
          c1Stacks(root: ['authShell'], auth: ['profile']),
        );
      },
    );

    test('C16 (I2) the rule lists are read live on every resolution', () async {
      final f = Fixture();

      await f.app.pushSilently(profile());
      f.authRules.add(
        RecordingRule(
          'late-stop',
          f.log,
          outcome: (_) => const RedirectResult.stop(),
        ),
      );
      final blocked = CountingRoute('profile', parentLayoutKey: 'authShell');
      await f.app.pushSilently(blocked);
      expect(f.log, [
        'app(profile)',
        'auth(profile)',
        'app(profile)',
        'auth(profile)',
        'late-stop(profile)',
      ]);
      expect(blocked.discards, 1);

      f.authRules.removeLast();
      f.appRules.add(RecordingRule('late-app', f.log));
      f.log.clear();
      await f.app.pushSilently(profile());
      expect(f.log, ['app(profile)', 'late-app(profile)', 'auth(profile)']);
      expect(
        stacksOf(f.app),
        c1Stacks(root: ['authShell'], auth: ['profile', 'profile']),
      );
    });

    test(
      'C17 scoped rules receive the tree root; the route own redirectWith receives the call site',
      () async {
        final f = Fixture();
        final ownRule = RecordingRule('own', f.log);

        await f.auth.pushSilently(
          RuledAppRoute('profile', [ownRule], parentLayoutKey: 'authShell'),
        );
        expect(f.log, ['app(profile)', 'auth(profile)', 'own(profile)']);
        expect(f.appRule.coordinators, [same(f.app)]);
        expect(f.authRule.coordinators, [same(f.app)]);
        expect(ownRule.coordinators, [same(f.auth)]);

        await f.app.pushSilently(
          RuledAppRoute('profile', [ownRule], parentLayoutKey: 'authShell'),
        );
        expect(ownRule.coordinators, [same(f.auth), same(f.app)]);
        expect(f.authRule.coordinators, [same(f.app), same(f.app)]);
      },
    );

    test(
      'C18 redirectScopeOf gives the same chain from every coordinator of the tree',
      () {
        final f = Fixture();
        for (final c in <CoordinatorCore>[f.app, f.shop, f.feed, f.auth]) {
          final at = '${c.runtimeType}';
          expect(c.redirectScopeOf(profile()), [
            same(f.app),
            same(f.auth),
          ], reason: at);
          expect(c.redirectScopeOf(totp()), [
            same(f.app),
            same(f.auth),
            same(f.sec),
          ], reason: at);
          expect(c.redirectScopeOf(post()), [same(f.app)], reason: at);
          expect(c.redirectScopeOf(home()), [same(f.app)], reason: at);
          expect(c.redirectScopeOf(cart()), [
            same(f.app),
            same(f.shop),
          ], reason: at);
        }
        expect(
          () => f.app.redirectScopeOf(home()).add(f.app),
          throwsUnsupportedError,
        );

        final d = DeepFixture();
        for (final c in <CoordinatorCore>[d.app, d.outer, d.inner]) {
          final at = '${c.runtimeType}';
          expect(
            c.redirectScopeOf(AppRoute('i', parentLayoutKey: 'innerShell')),
            [same(d.app), same(d.outer), same(d.inner)],
            reason: at,
          );
          expect(
            c.redirectScopeOf(AppRoute('f', parentLayoutKey: 'featShell')),
            [same(d.app), same(d.outer), same(d.inner), same(d.feat)],
            reason: at,
          );
          expect(
            c.redirectScopeOf(AppRoute('o', parentLayoutKey: 'outerShell')),
            [same(d.app), same(d.outer)],
            reason: at,
          );
          expect(c.redirectScopeOf(home()), [same(d.app)], reason: at);
        }
      },
    );

    test(
      'C19 an inactive shell is probed once per pass and discarded; a mounted shell is reused and never discarded',
      () async {
        final log = <String>[];
        late AuthCoordinator auth;
        final app = ScopedModularApp(
          rules: [RecordingRule('app', log)],
          modules: (c) => [
            auth = AuthCoordinator(c, rules: [RecordingRule('auth', log)]),
          ],
        );
        final shells = CountingShellConstructor(
          app,
          key: 'authShell',
          path: auth.extra,
        );

        expect(app.redirectScopeOf(profile()), [same(app), same(auth)]);
        expect(shells.constructions, 1);
        expect(shells.discards, 1);
        expect(shells.built.single.stackPath, isNull);

        // Two passes that target the inactive shell: two probes.
        final moving = AliasRoute(
          'profile',
          parentLayoutKey: 'authShell',
          to: () => AppRoute('profile-2', parentLayoutKey: 'authShell'),
        );
        final resolved = await RouteRedirect.resolve<AppRoute>(moving, app);
        expect(resolved?.id, 'profile-2');
        expect(log, [
          'app(profile)',
          'auth(profile)',
          'app(profile-2)',
          'auth(profile-2)',
        ]);
        expect(shells.constructions, 3);
        expect(shells.discards, 3);
        expect(app.root.stack, isEmpty);

        // A push probes once for the resolution, then builds the shell it
        // mounts.
        await app.pushSilently(profile());
        expect(shells.constructions, 5);
        expect(shells.discards, 4);
        final mounted = shells.built.last;
        expect(mounted.stackPath, same(app.root));
        expect(app.root.stack.single, same(mounted));

        // With the shell mounted, resolutions reuse it.
        await RouteRedirect.resolve(profile(), app);
        expect(app.redirectScopeOf(profile()), [same(app), same(auth)]);
        await app.pushSilently(profile());
        expect(shells.constructions, 5);
        expect(shells.discards, 4);
        expect(mounted.discards, 0);
        expect(stacksOf(app), {
          'root': ['authShell'],
          'nested': <String>[],
          'auth': ['profile', 'profile'],
        });
        expect(
          shells.built.take(4).map((probe) => probe.discards),
          everyElement(1),
        );
        expect(
          shells.built.take(4).map((probe) => probe.stackPath),
          everyElement(isNull),
        );
      },
    );

    test(
      'C a layout that resolves to another stack later is gated by the owner of the stack it resolves to now',
      () async {
        final log = <String>[];
        late FeatureModule guest;
        late ScopedFeature member;
        final app = ScopedModularApp(
          rules: const [],
          modules: (c) => [
            guest = FeatureModule(c, prefix: 'guest', hasPath: true),
            member = ScopedFeature(
              c,
              rules: [RecordingRule('member', log)],
              prefix: 'member',
              hasPath: true,
            ),
          ],
        );
        var signedIn = false;
        app.defineLayoutParentConstructor(
          'shell',
          (key) => SwitchingLayout(
            'shell',
            layoutKey: key,
            pick: () => signedIn ? member.featurePath : guest.featurePath,
          ),
        );
        AppRoute page() => AppRoute('page', parentLayoutKey: 'shell');

        expect(app.redirectScopeOf(page()), [same(app)]);
        await app.pushSilently(page());
        expect(log, isEmpty);
        expect(guest.featurePath.stack.map((route) => route.id), ['page']);

        // Signed in: the same key now resolves to the member's stack. A
        // landing remembered from before would skip the member's rule.
        signedIn = true;
        await app.replace(AppRoute('home'));

        expect(app.redirectScopeOf(page()), [same(app), same(member)]);
        await app.pushSilently(page());
        expect(log, contains('member(page)'));
        expect(member.featurePath.stack.map((route) => route.id), ['page']);
      },
    );

    test(
      'C sync prefix: in an opted-in tree the first root rule runs before resolve first awaits',
      () async {
        final f = Fixture();
        final route = profile();

        final resolving = RouteRedirect.resolve(route, f.app);
        // Read synchronously: callers may observe a rule's effects right
        // after starting a navigation, without awaiting it.
        expect(f.log, ['app(profile)']);

        expect(await resolving, same(route));
        expect(f.log, ['app(profile)', 'auth(profile)']);
      },
    );

    test(
      'C an equal new instance from a route redirect ends the chain on the request and is discarded once, in an opted-out tree',
      () async {
        final p = PlainFixture();
        final created = <EchoRoute>[];
        final request = EchoRoute('echo', created);

        final resolved = await RouteRedirect.resolve<AppRoute>(request, p.app);

        expect(resolved, same(request));
        expect(created, hasLength(1));
        expect(created.single, equals(request));
        expect(created.single.discards, 1);
        expect(request.discards, 0);
        expect(stacksOf(p.app), c1Stacks());
      },
    );

    test(
      'C an equal new instance from a module rule ends the chain on the request and is discarded once',
      () async {
        final f = Fixture();
        final request = CountingRoute('profile', parentLayoutKey: 'authShell');
        final fresh = <CountingRoute>[];
        f.authRule.outcome = (route) {
          final echo = CountingRoute('profile', parentLayoutKey: 'authShell');
          fresh.add(echo);
          return RedirectResult.redirectTo(echo);
        };

        final resolved = await RouteRedirect.resolve<AppRoute>(request, f.app);

        expect(resolved, same(request));
        expect(f.log, ['app(profile)', 'auth(profile)']);
        expect(fresh, hasLength(1));
        expect(fresh.single, equals(request));
        expect(fresh.single.discards, 1);
        expect(request.discards, 0);
        expect(stacksOf(f.app), c1Stacks());
      },
    );

    test(
      'C a rule that redirects to the destination itself does not end the pass: every rule below it still runs',
      () async {
        final f = Fixture();
        // A one-word mistake for `continueRedirect()`, and what a rule that
        // rebuilds its route does whenever nothing needs changing.
        f.appRule.outcome = (route) => RedirectResult.redirectTo(route);
        f.secRule.outcome = (_) => const RedirectResult.stop();
        final request = CountingRoute('keys', parentLayoutKey: 'secShell');

        final resolved = await RouteRedirect.resolve<AppRoute>(request, f.app);

        expect(resolved, isNull, reason: 'the owning module says stop');
        expect(f.log, ['app(keys)', 'auth(keys)', 'sec(keys)']);
        expect(request.discards, 1);
        expect(stacksOf(f.app), c1Stacks());
      },
    );

    test(
      'C an equal new instance from an outer rule is discarded once, and every rule below it still runs',
      () async {
        final f = Fixture();
        final fresh = <CountingRoute>[];
        f.appRule.outcome = (route) {
          final echo = CountingRoute(route.id, parentLayoutKey: 'secShell');
          fresh.add(echo);
          return RedirectResult.redirectTo(echo);
        };
        final request = CountingRoute('keys', parentLayoutKey: 'secShell');

        final resolved = await RouteRedirect.resolve<AppRoute>(request, f.app);

        expect(resolved, same(request));
        expect(f.log, ['app(keys)', 'auth(keys)', 'sec(keys)']);
        expect(fresh.single.discards, 1);
        expect(request.discards, 0);
      },
    );

    test(
      "C the route's own rules still run after every module rule echoes the destination, and an echo costs no hop",
      () async {
        final f = Fixture();
        for (final rule in f.rules) {
          rule.outcome = (route) => RedirectResult.redirectTo(route);
        }
        final own = RecordingRule('own', f.log)
          ..outcome = (_) => const RedirectResult.stop();
        final request = RuledAppRoute('keys', [
          own,
        ], parentLayoutKey: 'secShell');

        final resolved = await RouteRedirect.resolve<AppRoute>(request, f.app);

        expect(resolved, isNull, reason: 'the route\'s own rule says stop');
        expect(f.log, ['app(keys)', 'auth(keys)', 'sec(keys)', 'own(keys)']);
        expect(request.discards, 1);
      },
    );

    test(
      'C a module rule that throws discards the routes the chain abandoned, the request included',
      () async {
        final f = Fixture();
        f.authRule.outcome = (route) => throw ArgumentError('boom');
        final request = CountingRoute('profile', parentLayoutKey: 'authShell');

        await expectLater(
          RouteRedirect.resolve<AppRoute>(request, f.app),
          throwsArgumentError,
        );
        expect(f.log, ['app(profile)', 'auth(profile)']);
        expect(request.discards, 1);

        // Thrown on the second pass: the route moved away from and the
        // current target are each discarded once.
        f.log.clear();
        final signIns = <CountingRoute>[];
        f.authRule.outcome = (route) {
          if (route.id == 'sign-in') throw ArgumentError('boom');
          final signIn = CountingRoute('sign-in', parentLayoutKey: 'authShell');
          signIns.add(signIn);
          return RedirectResult.redirectTo(signIn);
        };
        final pushed = CountingRoute('profile', parentLayoutKey: 'authShell');

        await expectLater(f.app.pushSilently(pushed), throwsArgumentError);
        expect(f.log, [
          'app(profile)',
          'auth(profile)',
          'app(sign-in)',
          'auth(sign-in)',
        ]);
        expect(pushed.discards, 1);
        expect(signIns.single.discards, 1);
        expect(stacksOf(f.app), c1Stacks());
      },
    );

    test(
      'C a route redirect that throws discards the routes the chain abandoned, in an opted-out tree',
      () async {
        final p = PlainFixture();
        final request = ThrowingRoute('boom', ArgumentError('boom'));

        await expectLater(
          RouteRedirect.resolve<AppRoute>(request, p.app),
          throwsArgumentError,
        );
        expect(request.discards, 1);

        late ThrowingRoute thrower;
        final alias = AliasRoute(
          'alias',
          to: () => thrower = ThrowingRoute('boom', ArgumentError('boom')),
        );
        await expectLater(p.app.pushSilently(alias), throwsArgumentError);
        expect([alias.calls, alias.discards, thrower.discards], [1, 1, 1]);
        expect(stacksOf(p.app), c1Stacks());
      },
    );

    test(
      'C a NoSuchMethodError from a real module coordinator getter propagates instead of dropping every gate',
      () async {
        final log = <String>[];
        late NsmModule mod;
        final app = ScopedModularApp(
          rules: [
            RecordingRule(
              'app',
              log,
              outcome: (_) => const RedirectResult.stop(),
            ),
          ],
          modules: (c) => [mod = NsmModule(c)],
        );
        // The tree root is looked up lazily, so this getter runs on the
        // first resolution.
        mod.broken = true;
        final route = CountingRoute('home');

        await expectLater(
          RouteRedirect.resolve<AppRoute>(route, mod),
          throwsA(isA<NoSuchMethodError>()),
        );
        expect(log, isEmpty);
        expect(route.discards, 1);
        expect(app.root.stack, isEmpty);
      },
    );

    test(
      'C a real module whose parent is an implements-CoordinatorModular double resolves like an opted-out tree',
      () async {
        final mod = ModCoordinator(
          DoubleParent(AppStackPath(debugLabel: 'double-root')),
        );
        expect(mod.isRouteModule, isTrue);

        final route = CountingRoute('home');
        expect(await RouteRedirect.resolve<AppRoute>(route, mod), same(route));
        late CountingRoute target;
        final alias = AliasRoute(
          'alias',
          to: () => target = CountingRoute('away'),
        );
        expect(await RouteRedirect.resolve<AppRoute>(alias, mod), same(target));
        expect(mod.redirectScopeOf(route), isEmpty);
        expect([route.discards, alias.calls, alias.discards], [0, 1, 1]);
        expect(target.discards, 0);
      },
    );

    test(
      'C an app member named registeredModules neither breaks compilation nor hides modules from the scope',
      () async {
        final log = <String>[];
        late ScopedModCoordinator mod;
        final app = OwnRegistryApp(
          rules: [RecordingRule('app', log)],
          modules: (c) => [
            mod = ScopedModCoordinator(c, rules: [RecordingRule('mod', log)]),
          ],
        );
        app.registerShell(key: 'modShell', path: mod.extra);

        await app.pushSilently(AppRoute('x', parentLayoutKey: 'modShell'));

        expect(log, ['app(x)', 'mod(x)']);
        expect(
          app.redirectScopeOf(AppRoute('x', parentLayoutKey: 'modShell')),
          [same(app), same(mod)],
        );
        expect(app.registeredModules, isEmpty);
        expect(stacksOf(app), {
          'root': ['modShell'],
          'nested': <String>[],
          'mod': ['x'],
        });
      },
    );

    test(
      "C listing a stack claims it: a module that lists its ancestor's own stack gates it, because the innermost claim wins",
      () async {
        final log = <String>[];
        late ClaimsStack mod;
        final app = ScopedModularApp(
          rules: [RecordingRule('app', log)],
          // `nested` is the root's own secondary stack, like a modal stack.
          modules: (c) => [
            mod = ClaimsStack(c, c.nested, rules: [RecordingRule('mod', log)]),
          ],
        );
        app.registerShell(key: 'modal', path: app.nested);
        final sheet = CountingRoute('sheet', parentLayoutKey: 'modal');

        expect(app.redirectScopeOf(sheet), [same(app), same(mod)]);
        await app.pushSilently(sheet);

        expect(log, ['app(sheet)', 'mod(sheet)']);
        expect(app.nested.stack, [same(sheet)]);
        expect(app.root.stack.map((r) => r.id), ['modal']);
        expect(sheet.discards, 0);
      },
    );
  });

  // =========================================================================
  // C12: opted-out trees
  // =========================================================================
  group('C12 opted-out trees', () {
    test(
      'C12 route-own rules, redirect results, discards and redirect calls are the upstream ones',
      () async {
        final p = PlainFixture();

        final ruled = RuledAppRoute('r', [
          RecordingRule('own', p.log),
        ], parentLayoutKey: 'authShell');
        expect(await RouteRedirect.resolve(ruled, p.app), same(ruled));
        expect(p.log, ['own(r)']);
        expect(ruled.discards, 0);

        late CountingRoute target;
        final alias = AliasRoute('a', to: () => target = CountingRoute('b'));
        expect(
          await RouteRedirect.resolve<AppRoute>(alias, p.app),
          same(target),
        );
        expect([alias.calls, alias.discards, target.discards], [1, 1, 0]);

        final stopped = AliasRoute('s', stop: true);
        expect(await RouteRedirect.resolve<AppRoute>(stopped, p.app), isNull);
        expect([stopped.calls, stopped.discards], [1, 1]);

        final self = AliasRoute('self');
        expect(await RouteRedirect.resolve<AppRoute>(self, p.app), same(self));
        expect([self.calls, self.discards], [1, 0]);

        final plain = CountingRoute('plain', parentLayoutKey: 'authShell');
        expect(await RouteRedirect.resolve(plain, p.app), same(plain));

        final shell = AppLayout(
          'authShell',
          layoutKey: 'authShell',
          path: p.auth.extra,
        );
        for (final c in <CoordinatorCore>[p.app, p.shop, p.feed, p.auth]) {
          for (final d in [home(), cart(), post(), profile(), totp(), shell]) {
            expect(c.redirectScopeOf(d), isEmpty);
          }
        }
        expect(stacksOf(p.app), c1Stacks());
      },
    );

    test(
      'C12 configurations that throw when opted in stay inert when opted out',
      () async {
        late AppStackPath shared;
        final detached = AppStackPath(debugLabel: 'detached');
        final app = ModularAppCoordinator(
          modules: (c) {
            shared = AppStackPath(coordinator: c, debugLabel: 'shared');
            return [
              ListingA(c, [shared, detached]),
              ListingB(c, [shared]),
            ];
          },
        );
        final loose = AppStackPath(coordinator: app, debugLabel: 'loose');
        app.registerShell(key: 'sharedShell', path: shared);
        app.registerShell(key: 'looseShell', path: loose);

        await app.pushSilently(AppRoute('s', parentLayoutKey: 'sharedShell'));
        await app.pushSilently(AppRoute('l', parentLayoutKey: 'looseShell'));
        await app.pushSilently(AppRoute('x', parentLayoutKey: 'missing'));
        await detached.pushSilently(AppRoute('d'));

        expect(app.root.stack.map((r) => r.id), [
          'sharedShell',
          'looseShell',
          'x',
        ]);
        expect(shared.stack.map((r) => r.id), ['s']);
        expect(loose.stack.map((r) => r.id), ['l']);
        expect(detached.stack.map((r) => r.id), ['d']);
        expect(
          app.redirectScopeOf(AppRoute('x', parentLayoutKey: 'missing')),
          isEmpty,
        );
      },
    );
  });

  // =========================================================================
  // C13: build-time misconfiguration
  // =========================================================================
  group('C13 build-time misconfiguration throws StateError', () {
    test('B1 (LF1) a declaring module whose subtree lists no stack', () async {
      final app = ModularAppCoordinator(modules: (c) => [BlogPostsModule(c)]);
      final route = TrackingRoute('home');

      final b1 = throwsStateErrorWith([
        'BlogPostsModule declares redirectRules but no stack',
        'Give the module a stack, bind a layout to it',
      ]);
      await expectLater(app.pushSilently(route), b1);
      expect(route.events, ['onDiscard']);
      await expectLater(
        app.pushSilently(AppRoute('again')),
        b1,
        reason: 'a failed lazy build throws again on every resolution',
      );
      expect(() => app.redirectScopeOf(AppRoute('home')), throwsStateError);
      expect(stacksOf(app), {'root': <String>[], 'nested': <String>[]});
    });

    test('B2 (LF2) one stack listed by two sibling modules', () async {
      final app = ScopedModularApp(
        rules: [],
        modules: (c) {
          final shared = AppStackPath(coordinator: c, debugLabel: 'shared');
          return [
            ListingA(c, [shared]),
            ListingB(c, [shared]),
          ];
        },
      );
      await expectLater(
        app.pushSilently(AppRoute('home')),
        throwsStateErrorWith([
          "stack 'shared' is listed by both ListingA and ListingB",
          'neither encloses the other',
        ]),
      );
    });

    test('B3 a module that lists the root stack', () async {
      final app = ScopedModularApp(rules: [], modules: (c) => [RootListing(c)]);
      await expectLater(
        app.pushSilently(AppRoute('home')),
        throwsStateErrorWith(["RootListing lists the root stack 'root'"]),
      );
    });

    test('B4 a listed stack with no coordinator', () async {
      final app = ScopedModularApp(
        rules: [],
        modules: (c) => [
          ListingA(c, [AppStackPath(debugLabel: 'detached')]),
        ],
      );
      await expectLater(
        app.pushSilently(AppRoute('home')),
        throwsStateErrorWith([
          "stack 'detached' listed by ListingA has no coordinator",
        ]),
      );
    });

    test('B4 a listed stack that belongs to another root', () async {
      final other = AppCoordinator();
      final foreign = AppStackPath(coordinator: other, debugLabel: 'foreign');
      final app = ScopedModularApp(
        rules: [],
        modules: (c) => [
          ListingA(c, [foreign]),
        ],
      );
      await expectLater(
        app.pushSilently(AppRoute('home')),
        throwsStateErrorWith([
          "stack 'foreign' listed by ListingA belongs to AppCoordinator",
          'not part of this tree',
        ]),
      );
    });

    test(
      'B5 a declaring module coordinator missing from defineModules throws at its call sites',
      () async {
        final f = Fixture();
        final orphan = AuthCoordinator(
          f.app,
          rules: [RecordingRule('orphan', f.log)],
        );
        final route = TrackingRoute('profile', parentLayoutKey: 'authShell');

        await expectLater(
          orphan.pushSilently(route),
          throwsStateErrorWith([
            'AuthCoordinator declares redirectRules',
            'not registered in defineModules',
          ]),
        );
        expect(route.events, ['onDiscard']);
        expect(() => orphan.redirectScopeOf(home()), throwsStateError);
        expect(f.log, isEmpty);

        await f.auth.pushSilently(profile());
        expect(f.log, ['app(profile)', 'auth(profile)']);
        expect(
          stacksOf(f.app),
          c1Stacks(root: ['authShell'], auth: ['profile']),
        );
      },
    );

    test(
      'B5 documented gap: a plain declaring module missing from defineModules is invisible, and its rules never run',
      () async {
        final log = <String>[];
        final app = ModularAppCoordinator(); // defineModules: const []
        final orphan = ScopedFeature(
          app,
          rules: [
            RecordingRule(
              'orphan',
              log,
              outcome: (_) => const RedirectResult.stop(),
            ),
          ],
          prefix: 'orphan',
          hasPath: true,
        );
        app.registerShell(key: 'orphanShell', path: orphan.featurePath);
        final x = CountingRoute('x', parentLayoutKey: 'orphanShell');

        await app.pushSilently(x);

        // The registry has no declaring module, so the tree has no scope and
        // nothing can reach the unregistered module or its rules.
        expect(log, isEmpty);
        expect(orphan.featurePath.stack, [same(x)]);
        expect(app.root.stack.map((r) => r.id), ['orphanShell']);
        expect(x.discards, 0);
        expect(app.redirectScopeOf(x), isEmpty);
      },
    );

    test(
      'B5 documented gap: an unregistered declaring module coordinator is skipped unless a call is made on it',
      () async {
        final log = <String>[];
        final app = ModularAppCoordinator(); // the module was not registered
        final orphan = ScopedNested(
          app,
          rules: [
            RecordingRule(
              'orphan',
              log,
              outcome: (_) => const RedirectResult.stop(),
            ),
          ],
          extraLabel: 'orphan',
        );
        app.registerShell(key: 'orphanShell', path: orphan.extra);
        final x = CountingRoute('x', parentLayoutKey: 'orphanShell');
        final y = CountingRoute('y', parentLayoutKey: 'orphanShell');

        // Through the root, and at path level on the module's own stack.
        await app.pushSilently(x);
        await orphan.extra.pushSilently(y);

        expect(log, isEmpty);
        expect(orphan.extra.stack, [same(x), same(y)]);
        expect([x.discards, y.discards], [0, 0]);

        // Only a call made on the unregistered instance itself is detected.
        final z = CountingRoute('z', parentLayoutKey: 'orphanShell');
        await expectLater(
          orphan.pushSilently(z),
          throwsStateErrorWith([
            'ScopedNested declares redirectRules',
            'not registered in defineModules',
          ]),
        );
        expect(z.discards, 1);
        expect(log, isEmpty);
        expect(orphan.extra.stack, [same(x), same(y)]);
      },
    );

    test(
      'a declaring module coordinator with no stack of its own builds when a sub-module owns one',
      () async {
        final log = <String>[];
        late PathlessScoped pathless;
        late SubOwner sub;
        final app = ScopedModularApp(
          rules: [RecordingRule('app', log)],
          modules: (c) => [
            pathless = PathlessScoped(
              c,
              rules: [RecordingRule('pathless', log)],
              childModules: [
                sub = SubOwner(c, rules: [RecordingRule('sub', log)]),
              ],
            ),
          ],
        );
        app.registerShell(key: 'subShell', path: sub.featurePath);

        await app.pushSilently(AppRoute('x', parentLayoutKey: 'subShell'));
        expect(log, ['app(x)', 'pathless(x)', 'sub(x)']);
        expect(
          app.redirectScopeOf(AppRoute('x', parentLayoutKey: 'subShell')),
          [same(app), same(pathless), same(sub)],
        );
        expect(stacksOf(app), {
          'root': ['subShell'],
          'nested': <String>[],
          'sub': ['x'],
        });
      },
    );
  });

  // =========================================================================
  // C14: navigation-time misconfiguration
  // =========================================================================
  group('C14 navigation-time misconfiguration throws StateError', () {
    test(
      'N1 a parentLayoutKey the tree root cannot build throws and discards the route once',
      () async {
        final f = Fixture();
        final route = TrackingRoute('x', parentLayoutKey: 'missing');

        await expectLater(
          f.app.pushSilently(route),
          throwsStateErrorWith([
            'AppRoute(x) names parentLayoutKey missing',
            'no layout constructor',
          ]),
        );
        expect(route.events, ['onDiscard']);
        expect(f.log, isEmpty);
        expect(stacksOf(f.app), c1Stacks());
        expect(
          () =>
              f.app.redirectScopeOf(AppRoute('x', parentLayoutKey: 'missing')),
          throwsStateError,
        );
      },
    );

    test(
      'N1 a layout registered only through a module two levels down lands in an orphan table the tree root cannot read',
      () async {
        final d = DeepFixture();
        d.inner.defineLayoutParentConstructor(
          'innerOnly',
          (key) => AppLayout('innerOnly', layoutKey: key, path: d.inner.extra),
        );

        for (final site in <CoordinatorMutatable<AppRoute>>[d.app, d.inner]) {
          final route = TrackingRoute('q', parentLayoutKey: 'innerOnly');
          await expectLater(
            site.pushSilently(route),
            throwsStateErrorWith(['parentLayoutKey innerOnly']),
            reason: '${site.runtimeType}',
          );
          expect(route.events, ['onDiscard']);
        }
        expect(d.log, isEmpty);
        expect(d.inner.extra.stack, isEmpty);
        expect(d.app.root.stack, isEmpty);
      },
    );

    test('N2 a landing stack no module lists throws', () async {
      final f = Fixture();
      final loose = AppStackPath(coordinator: f.app, debugLabel: 'loose');
      f.app.registerShell(key: 'looseShell', path: loose);
      final route = TrackingRoute('x', parentLayoutKey: 'looseShell');

      await expectLater(
        f.app.pushSilently(route),
        throwsStateErrorWith([
          "AppRoute(x) lands in stack 'loose'",
          "list it in the owning module's paths",
        ]),
      );
      expect(route.events, ['onDiscard']);
      expect(loose.stack, isEmpty);
      expect(stacksOf(f.app), c1Stacks());
    });
  });

  // =========================================================================
  // C15: D1 debug check
  // =========================================================================
  group('C15 D1 debug check at path-level commits', () {
    test(
      'a layout-less route pushed into a module stack asserts; gated commits do not',
      () async {
        final f = Fixture();

        await expectLater(
          f.auth.extra.pushSilently(AppRoute('stray')),
          throwsA(
            isA<AssertionError>().having(
              (e) => '${e.message}',
              'message',
              allOf(
                contains("AppRoute(stray) was committed into stack 'auth'"),
                contains('AuthCoordinator'),
                contains('navigate through the coordinator'),
              ),
            ),
          ),
        );
        expect(f.log, ['app(stray)']);
        expect(stacksOf(f.app), c1Stacks());

        f.log.clear();
        await f.shop.extra.pushSilently(cart());
        await (f.app.root as AppStackPath).pushSilently(profile());
        expect(f.log, [
          'app(cart)',
          'shop(cart)',
          'app(profile)',
          'auth(profile)',
        ]);
        expect(stacksOf(f.app), c1Stacks(root: ['profile'], shop: ['cart']));
      },
    );

    test(
      'a layout-less route set into a module stack with replaceAll asserts, like a stray push, and before anything changes',
      () async {
        final f = Fixture();
        await f.auth.extra.pushSilently(profile());
        f.log.clear();

        expect(
          () => f.auth.extra.replaceAll([AppRoute('stray')]),
          throwsA(
            isA<AssertionError>().having(
              (e) => '${e.message}',
              'message',
              allOf(
                contains("AppRoute(stray) was committed into stack 'auth'"),
                contains('AuthCoordinator'),
              ),
            ),
          ),
        );
        // replaceAll runs no rule: it is a commit, not a navigation.
        expect(f.log, isEmpty);
        expect(stacksOf(f.app), c1Stacks(auth: ['profile']));

        // Routes that belong in the stack pass.
        f.auth.extra.replaceAll([profile(), profile()]);
        expect(stacksOf(f.app), c1Stacks(auth: ['profile', 'profile']));
      },
    );

    test(
      'a layout-less route moved to the top of a module stack asserts, like a stray push',
      () async {
        final f = Fixture();

        await expectLater(
          f.auth.extra.pushOrMoveToTop(AppRoute('stray')),
          throwsA(
            isA<AssertionError>().having(
              (e) => '${e.message}',
              'message',
              allOf(
                contains("AppRoute(stray) was committed into stack 'auth'"),
                contains('AuthCoordinator'),
                contains('navigate through the coordinator'),
              ),
            ),
          ),
        );
        expect(f.log, ['app(stray)']);
        expect(stacksOf(f.app), c1Stacks());
      },
    );

    test('the same stray push in an opted-out tree does not assert', () async {
      final p = PlainFixture();
      await p.auth.extra.pushSilently(AppRoute('stray'));
      expect(p.auth.extra.stack.map((r) => r.id), ['stray']);
    });
  });

  // =========================================================================
  // O-2: additional boundary tests
  // =========================================================================
  group('O-2 boundary tests', () {
    test(
      'S6 a non-declaring module between the root and a declaring child neither contributes nor breaks the walk',
      () async {
        final log = <String>[];
        late GapCoordinator gap;
        late BelowGap below;
        final app = ScopedModularApp(
          rules: [RecordingRule('app', log)],
          modules: (c) => [
            gap = GapCoordinator(
              c,
              childModulesBuilder: (self) => [
                below = BelowGap(self, rules: [RecordingRule('below', log)]),
              ],
            ),
          ],
        );
        app.registerShell(key: 'gapShell', path: gap.extra);
        app.registerShell(key: 'belowShell', path: below.extra);
        final deep = [
          CountingRoute('deep', parentLayoutKey: 'belowShell'),
          CountingRoute('deep-2', parentLayoutKey: 'belowShell'),
          CountingRoute('deep-3', parentLayoutKey: 'belowShell'),
        ];

        await app.pushSilently(deep[0]);
        await below.pushSilently(deep[1]);
        await gap.pushSilently(deep[2]);
        expect(log, [
          'app(deep)',
          'below(deep)',
          'app(deep-2)',
          'below(deep-2)',
          'app(deep-3)',
          'below(deep-3)',
        ]);

        log.clear();
        final mid = CountingRoute('mid', parentLayoutKey: 'gapShell');
        await app.pushSilently(mid);
        expect(log, ['app(mid)']);

        for (final c in <CoordinatorCore>[app, gap, below]) {
          expect(
            c.redirectScopeOf(AppRoute('deep', parentLayoutKey: 'belowShell')),
            [same(app), same(below)],
          );
          expect(
            c.redirectScopeOf(AppRoute('mid', parentLayoutKey: 'gapShell')),
            [same(app)],
          );
        }
        expect(stacksOf(app), {
          'root': ['belowShell', 'gapShell'],
          'nested': <String>[],
          'below': ['deep', 'deep-2', 'deep-3'],
          'gap': ['mid'],
        });
        expect([...deep, mid].map((r) => r.discards), everyElement(0));
      },
    );

    test(
      'S7 a declaring module gates its own stack when the root declares nothing',
      () async {
        final log = <String>[];
        late ScopedModCoordinator mod;
        final app = ModularAppCoordinator(
          modules: (c) => [
            mod = ScopedModCoordinator(c, rules: [RecordingRule('mod', log)]),
          ],
        );
        app.registerShell(key: 'modShell', path: mod.extra);

        final routes = [
          CountingRoute('x', parentLayoutKey: 'modShell'),
          CountingRoute('y', parentLayoutKey: 'modShell'),
          CountingRoute('home'),
        ];
        await app.pushSilently(routes[0]);
        await mod.pushSilently(routes[1]);
        await app.pushSilently(routes[2]);

        expect(routes.map((route) => route.discards), [0, 0, 0]);
        expect(log, ['mod(x)', 'mod(y)']);
        expect(
          app.redirectScopeOf(AppRoute('x', parentLayoutKey: 'modShell')),
          [same(mod)],
        );
        expect(app.redirectScopeOf(AppRoute('home')), isEmpty);
        expect(stacksOf(app), {
          'root': ['modShell', 'home'],
          'nested': <String>[],
          'mod': ['x', 'y'],
        });
      },
    );

    test(
      'S7 root-stack destinations of that tree resolve exactly as in an opted-out tree',
      () async {
        final log = <String>[];
        final opted = ModularAppCoordinator(
          modules: (c) => [
            ScopedModCoordinator(c, rules: [RecordingRule('mod', log)]),
          ],
        );
        final plain = ModularAppCoordinator(
          modules: (c) => [ModCoordinator(c)],
        );

        final optedOut = await rootStackScript(opted);
        final reference = await rootStackScript(plain);

        expect(optedOut, reference);
        expect(reference, {
          'stacks': {
            'root': ['home', 'pushed-target'],
            'nested': <String>[],
            'mod': <String>[],
          },
          'home.discards': 0,
          'alias': ['target', true, 1, 1, 0],
          'stopped': [null, 1, 1],
          'self': [true, 1, 0],
          'hops': [hop20, hop21, hop20, hop21, cycle],
        });
        expect(log, isEmpty, reason: 'the module never sees root routes');
      },
    );

    test(
      'S8 standalone, a declaring coordinator gates every destination it resolves, layout-less ones included',
      () async {
        final log = <String>[];
        final dual = DualRoleCoordinator(rules: [RecordingRule('dual', log)]);
        dual.defineLayoutParentConstructor(
          'dualShell',
          (key) => AppLayout('dualShell', layoutKey: key, path: dual.stack),
        );
        expect(dual.isRouteModule, isFalse);

        final routes = [
          CountingRoute('home'),
          CountingRoute('inside', parentLayoutKey: 'dualShell'),
        ];
        await dual.pushSilently(routes[0]);
        await dual.pushSilently(routes[1]);

        expect(routes.map((route) => route.discards), [0, 0]);
        expect(log, ['dual(home)', 'dual(inside)']);
        expect(dual.redirectScopeOf(AppRoute('home')), [same(dual)]);
        expect(stacksOf(dual), {
          'dual-root': ['home', 'dualShell'],
          'dual': ['inside'],
        });
      },
    );

    test(
      'S8 registered as a module, the same class gates only its own stack',
      () async {
        final log = <String>[];
        late DualRoleCoordinator dual;
        final app = ModularAppCoordinator(
          modules: (c) => [
            dual = DualRoleCoordinator(
              parent: c,
              rules: [RecordingRule('dual', log)],
            ),
          ],
        );
        app.registerShell(key: 'dualShell', path: dual.stack);
        expect(dual.isRouteModule, isTrue);

        final routes = [
          CountingRoute('home'),
          CountingRoute('home-2'),
          CountingRoute('inside', parentLayoutKey: 'dualShell'),
          CountingRoute('inside-2', parentLayoutKey: 'dualShell'),
        ];
        await app.pushSilently(routes[0]);
        await dual.pushSilently(routes[1]);
        await app.pushSilently(routes[2]);
        await dual.pushSilently(routes[3]);

        expect(routes.map((route) => route.discards), [0, 0, 0, 0]);
        expect(log, ['dual(inside)', 'dual(inside-2)']);
        expect(app.redirectScopeOf(AppRoute('home')), isEmpty);
        expect(
          dual.redirectScopeOf(AppRoute('x', parentLayoutKey: 'dualShell')),
          [same(dual)],
        );
        expect(stacksOf(app), {
          'root': ['home', 'home-2', 'dualShell'],
          'nested': <String>[],
          'dual': ['inside', 'inside-2'],
        });
      },
    );

    test(
      'S9 a declaring module with an empty rule list behaves exactly like the tree without the mixin',
      () async {
        late ScopedModCoordinator scopedMod;
        final scoped = ModularAppCoordinator(
          modules: (c) => [scopedMod = ScopedModCoordinator(c, rules: [])],
        );
        scoped.registerShell(key: 'modShell', path: scopedMod.extra);

        late ModCoordinator plainMod;
        final plain = ModularAppCoordinator(
          modules: (c) => [plainMod = ModCoordinator(c)],
        );
        plain.registerShell(key: 'modShell', path: plainMod.extra);

        final withMixin = await moduleScript(scoped, scopedMod);
        final withoutMixin = await moduleScript(plain, plainMod);

        expect(withMixin, withoutMixin);
        expect(withoutMixin, {
          'stacks': {
            'root': ['home', 'modShell'],
            'nested': <String>[],
            'mod': ['inside'],
          },
          'discards': {
            'home': 0,
            'inside': 0,
            'via-module': 1,
            'path-level': 1,
            'foreign': 1,
            'alias': 1,
            'landed': 1,
            'stopped': 1,
            'inside#2': 1,
          },
          'alias.calls': 1,
          'stopped.calls': 1,
          'hops': [hop20, hop21, hop20, hop21, cycle],
        });
        // The one structural difference: the module is in scope.
        expect(
          scoped.redirectScopeOf(AppRoute('x', parentLayoutKey: 'modShell')),
          [same(scopedMod)],
        );
        expect(
          plain.redirectScopeOf(AppRoute('x', parentLayoutKey: 'modShell')),
          isEmpty,
        );
      },
    );

    test(
      'O3r a root rule redirecting into a module route runs the module rules on the new target',
      () async {
        final f = Fixture();
        late CountingRoute redirected;
        f.appRule.outcome = (r) => r.id == 'x'
            ? RedirectResult.redirectTo(
                redirected = CountingRoute(
                  'profile',
                  parentLayoutKey: 'authShell',
                ),
              )
            : const RedirectResult.continueRedirect();
        final requested = CountingRoute('x');

        await f.app.pushSilently(requested);

        expect(f.log, ['app(x)', 'app(profile)', 'auth(profile)']);
        expect(
          stacksOf(f.app),
          c1Stacks(root: ['authShell'], auth: ['profile']),
        );
        expect(f.auth.extra.stack.single, same(redirected));
        expect(requested.discards, 1);
        expect(redirected.discards, 0);
      },
    );

    test(
      'O4m (O4) a Stop from a module rule leaves every stack unchanged at every coordinator entry point',
      () async {
        final f = Fixture();
        await f.app.pushSilently(home());
        await f.app.pushSilently(cart());
        f.authRule.outcome = (_) => const RedirectResult.stop();

        final sites = <String, CoordinatorRecoverable<AppRoute>>{
          'root': f.app,
          'auth': f.auth,
        };
        final entryPoints =
            <
              String,
              Future<Object?> Function(
                CoordinatorRecoverable<AppRoute>,
                AppRoute,
              )
            >{
              'push': (c, r) => c.push<Object>(r),
              'pushSilently': (c, r) async {
                await c.pushSilently(r);
                return null;
              },
              'pushOrMoveToTop': (c, r) async {
                await c.pushOrMoveToTop(r);
                return null;
              },
              'pushReplacement': (c, r) => c.pushReplacement<Object, Object>(r),
              'replace': (c, r) async {
                await c.replace(r);
                return null;
              },
              'navigate': (c, r) async {
                await c.navigate(r);
                return null;
              },
              'recover': (c, r) async {
                await c.recover(r);
                return null;
              },
            };

        for (final site in sites.entries) {
          for (final entry in entryPoints.entries) {
            final label = '${entry.key} via ${site.key}';
            final before = snapshotOf(f.app);
            f.log.clear();
            final requested = CountingRoute(
              'profile',
              parentLayoutKey: 'authShell',
            );

            final result = await entry.value(site.value, requested);

            expect(result, isNull, reason: label);
            expectSameStacks(snapshotOf(f.app), before, reason: label);
            expect(requested.discards, 1, reason: label);
            expect(f.log, ['app(profile)', 'auth(profile)'], reason: label);
          }
        }
        expect(
          stacksOf(f.app),
          c1Stacks(root: ['home', 'shopShell'], shop: ['cart']),
        );
      },
    );

    test(
      'O5 async and sync rules keep their order at root, module and route level',
      () async {
        final log = <String>[];
        late AuthCoordinator auth;
        final app = ScopedModularApp(
          rules: [
            OrderedRule('a1', log),
            OrderedRule('a2', log, delay: const Duration(milliseconds: 3)),
            OrderedRule('a3', log),
          ],
          modules: (c) => [
            auth = AuthCoordinator(
              c,
              rules: [
                OrderedRule('m1', log, delay: const Duration(milliseconds: 1)),
                OrderedRule('m2', log),
                OrderedRule('m3', log, delay: Duration.zero),
              ],
            ),
          ],
        );
        app.registerShell(key: 'authShell', path: auth.extra);
        final route = RuledAppRoute('profile', [
          OrderedRule('o1', log, delay: Duration.zero),
          OrderedRule('o2', log),
        ], parentLayoutKey: 'authShell');

        await app.pushSilently(route);

        expect(log, [
          'a1(profile)',
          'a2:start(profile)',
          'a2:end(profile)',
          'a3(profile)',
          'm1:start(profile)',
          'm1:end(profile)',
          'm2(profile)',
          'm3:start(profile)',
          'm3:end(profile)',
          'o1:start(profile)',
          'o1:end(profile)',
          'o2(profile)',
        ]);
        expect(stacksOf(app), {
          'root': ['authShell'],
          'nested': <String>[],
          'auth': ['profile'],
        });
        expect(auth.extra.stack.single, same(route));
        expect(route.discards, 0);
      },
    );

    test(
      'O5 an async module RedirectTo and an async root Stop take effect in order',
      () async {
        final log = <String>[];
        late AuthCoordinator auth;
        final app = ScopedModularApp(
          rules: [
            OrderedRule('a1', log),
            OrderedRule(
              'a2',
              log,
              delay: const Duration(milliseconds: 2),
              outcome: (r) => r.id == 'secret'
                  ? const RedirectResult.stop()
                  : const RedirectResult.continueRedirect(),
            ),
          ],
          modules: (c) => [
            auth = AuthCoordinator(
              c,
              rules: [
                OrderedRule(
                  'm1',
                  log,
                  delay: const Duration(milliseconds: 1),
                  outcome: (r) => r.id == 'profile'
                      ? RedirectResult.redirectTo(
                          AppRoute('sign-in', parentLayoutKey: 'authShell'),
                        )
                      : const RedirectResult.continueRedirect(),
                ),
                OrderedRule('m2', log),
              ],
            ),
          ],
        );
        app.registerShell(key: 'authShell', path: auth.extra);

        final requested = CountingRoute(
          'profile',
          parentLayoutKey: 'authShell',
        );
        await app.pushSilently(requested);
        expect(log, [
          'a1(profile)',
          'a2:start(profile)',
          'a2:end(profile)',
          'm1:start(profile)',
          'm1:end(profile)',
          'a1(sign-in)',
          'a2:start(sign-in)',
          'a2:end(sign-in)',
          'm1:start(sign-in)',
          'm1:end(sign-in)',
          'm2(sign-in)',
        ]);
        expect(requested.discards, 1);

        log.clear();
        final secret = CountingRoute('secret', parentLayoutKey: 'authShell');
        await app.pushSilently(secret);
        expect(log, ['a1(secret)', 'a2:start(secret)', 'a2:end(secret)']);
        expect(secret.discards, 1);
        expect(stacksOf(app), {
          'root': ['authShell'],
          'nested': <String>[],
          'auth': ['sign-in'],
        });
      },
    );

    test(
      'O8 a module rule typed to its own route base is never offered another route',
      () async {
        final log = <String>[];
        final vaultRule = VaultOnlyRule();
        late ShopCoordinator shop;
        late FeedCoordinator feed;
        late VaultCoordinator vault;
        final app = ScopedModularApp(
          rules: [RecordingRule('app', log)],
          modules: (c) => [
            shop = ShopCoordinator(c, rules: [RecordingRule('shop', log)]),
            feed = FeedCoordinator(c),
            vault = VaultCoordinator(c, rules: [vaultRule]),
          ],
        );
        app.registerShell(key: 'shopShell', path: shop.extra);
        app.registerShell(key: 'feedShell', path: feed.extra);
        app.registerShell(key: 'vaultShell', path: vault.extra);

        final others = <AppRoute Function()>[
          home,
          cart,
          post,
          () => RuledAppRoute('ruled', [const ContinueRule()]),
          () => AliasRoute('alias', to: () => AppRoute('alias-target')),
        ];
        final perSite = <String, List<String>>{
          'root': ['home', 'shopShell', 'feedShell', 'ruled', 'alias-target'],
          'nested': <String>[],
          'shop': ['cart'],
          'feed': ['post'],
          'vault': <String>[],
        };
        for (final site in <CoordinatorMutatable<AppRoute>>[app, vault, shop]) {
          resetAll(app);
          for (final destination in others) {
            await site.pushSilently(destination());
          }
          expect(stacksOf(app), perSite, reason: '${site.runtimeType}');
        }
        expect(vaultRule.calls, 0);
        expect(log.where((e) => e.startsWith('shop(')), [
          'shop(cart)',
          'shop(cart)',
          'shop(cart)',
        ]);

        await app.pushSilently(VaultRoute('secret'));
        expect(vaultRule.calls, 1);
        expect(stacksOf(app), {
          ...perSite,
          'root': [...perSite['root']!, 'vaultShell'],
          'vault': ['secret'],
        });
      },
    );
  });

  // =========================================================================
  // B-HOP: the budget matrix (brief override O-1)
  // =========================================================================
  group('B-HOP the hop budget counts moves in every tree and for every terminal', () {
    final trees = <String, HopTree Function()>{
      'opted out': optedOutTree,
      'opted in with rules': optedInWithRules,
      'opted in with an empty rule list': optedInEmpty,
    };
    final terminals = <String, (CountingRoute Function(), bool)>{
      'a plain route': (() => CountingRoute('t'), false),
      'a self-returning RouteRedirect': (() => SelfRedirectRoute('t'), false),
      'a RouteRedirectRule route whose rules all continue': (
        () => RuledAppRoute('t', [const ContinueRule()]),
        false,
      ),
      'a plain route under a scoped rule that continues': (
        () => CountingRoute('t', parentLayoutKey: 'modShell'),
        true,
      ),
    };

    for (final tree in trees.entries) {
      for (final terminal in terminals.entries) {
        test(
          'B-HOP ${tree.key}, ending on ${terminal.key}: 20 moves resolve, 21 throw',
          () async {
            final t = tree.value();
            final (build, scoped) = terminal.value;
            final hasRules = tree.key == 'opted in with rules';

            expect(await hopOutcome(t.app, 20, build), hop20);
            expect(t.log, [
              if (hasRules) ...[
                for (var i = 0; i < 20; i++) 'app(c$i)',
                'app(t)',
                if (scoped) 'mod(t)',
              ],
            ]);

            t.log.clear();
            expect(await hopOutcome(t.app, 21, build), hop21);
            expect(t.log, [
              if (hasRules)
                for (var i = 0; i < 21; i++) 'app(c$i)',
            ]);

            expect(stacksOf(t.app), {
              'root': <String>[],
              'nested': <String>[],
              'mod': <String>[],
            }, reason: 'resolve alone commits nothing');
          },
        );
      }

      test('B-HOP ${tree.key}: A → B → A throws', () async {
        final t = tree.value();
        expect(await cycleOutcome(t.app), cycle);
        expect(t.log, [
          if (tree.key == 'opted in with rules') ...[
            'app(a)',
            'app(b)',
            'app(a)',
          ],
        ]);
      });

      test(
        'B-HOP ${tree.key}: a chain that comes back to its first route (gated → splash → gated) returns that route undiscarded',
        () async {
          final t = tree.value();
          final gated = GatedRoute(
            'gated',
            SplashSession(),
            parentLayoutKey: 'modShell',
          );

          final resolved = await RouteRedirect.resolve<AppRoute>(gated, t.app);

          expect(resolved, same(gated));
          expect(gated.discards, 0);
          expect(gated.splashes.map((splash) => splash.discards), [1]);
          expect(t.log, [
            if (tree.key == 'opted in with rules') ...[
              'app(gated)',
              'mod(gated)',
              'app(splash)',
              'app(gated)',
              'mod(gated)',
            ],
          ]);
          expect(stacksOf(t.app), {
            'root': <String>[],
            'nested': <String>[],
            'mod': <String>[],
          });
        },
      );

      test(
        'B-HOP ${tree.key}: a push that comes back to its first route keeps its result pending until the route is popped',
        () async {
          final t = tree.value();
          final gated = GatedRoute(
            'gated',
            SplashSession(),
            parentLayoutKey: 'modShell',
          );
          Object? value = 'pending';
          unawaited(t.app.push<String>(gated).then((v) => value = v));
          await settle();

          expect(value, 'pending');
          expect(gated.discards, 0);
          expect(stacksOf(t.app), {
            'root': ['modShell'],
            'nested': <String>[],
            'mod': ['gated'],
          });

          await (gated.stackPath! as AppStackPath).pop('result');
          await settle();

          expect(value, 'result');
          expect(gated.splashes.single.discards, 1);
          expect(stacksOf(t.app), {
            'root': ['modShell'],
            'nested': <String>[],
            'mod': <String>[],
          });
        },
      );
    }
  });
}
