// One RedirectRule, two levels (brief O-5, L1-L6).
//
// The rule a module declares in RouteModuleRedirectRule.redirectRules is the
// same RedirectRule class, with the same RedirectResult semantics, as the one
// a route declares in RouteRedirectRule.redirectRules, and the two compose:
// module rules first, then the route's own. Two differences are deliberate
// and pinned here so changing either is a visible decision:
// - the coordinator argument (L4): module rules receive the tree root,
//   route rules receive the call-site coordinator;
// - typing (L6): a rule typed to one route is safe on that route, but a
//   module offers it every destination landing in its stacks.
//
// Every test drives the real coordinators of the harness and asserts on the
// resolve result, the full stacks, onDiscard counts and the rule log.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

import '../support/harness.dart';

// ===========================================================================
// Routes
// ===========================================================================

/// A destination that counts its `onDiscard` calls.
class LevelRoute extends AppRoute {
  LevelRoute(super.id, {super.parentLayoutKey});

  int discards = 0;

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }
}

/// A destination with its own rule list: the route level.
class RuledRoute extends LevelRoute
    with RouteRedirect<AppRoute>, RouteRedirectRule<AppRoute> {
  RuledRoute(super.id, this.rules, {super.parentLayoutKey});

  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

class ProfilePage extends LevelRoute {
  ProfilePage() : super('profile', parentLayoutKey: 'authShell');
}

class RuledProfilePage extends ProfilePage
    with RouteRedirect<AppRoute>, RouteRedirectRule<AppRoute> {
  RuledProfilePage(this.rules);

  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

class SignInPage extends LevelRoute {
  SignInPage() : super('sign-in', parentLayoutKey: 'authShell');
}

// ===========================================================================
// Rules
// ===========================================================================

enum Verdict { pass, stop, toSignIn }

class FlagState {
  Verdict verdict = Verdict.pass;
}

/// Stops, redirects to a fresh SignIn, or continues, depending on [state].
/// It continues for SignIn itself, its own redirect target. The same class
/// is used at module level and at route level.
class RequireFlag extends RedirectRule<AppRoute> {
  RequireFlag(this.state, this.log, {required this.signIn});

  final FlagState state;
  final List<String> log;
  final LevelRoute Function() signIn;

  final coordinators = <CoordinatorCore>[];
  final signIns = <LevelRoute>[];

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    log.add('flag(${route.id})');
    coordinators.add(coordinator);
    if (route.id == 'sign-in') return const RedirectResult.continueRedirect();
    switch (state.verdict) {
      case Verdict.pass:
        return const RedirectResult.continueRedirect();
      case Verdict.stop:
        return const RedirectResult.stop();
      case Verdict.toSignIn:
        final next = signIn();
        signIns.add(next);
        return RedirectResult.redirectTo(next);
    }
  }
}

/// A route-level rule that redirects to a fresh shop route.
class ToCart extends RedirectRule<AppRoute> {
  ToCart(this.log);

  final List<String> log;
  final carts = <LevelRoute>[];

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    log.add('own(${route.id})');
    final cart = LevelRoute('cart', parentLayoutKey: 'shopShell');
    carts.add(cart);
    return RedirectResult.redirectTo(cart);
  }
}

/// The user's app-wide rule: SignIn while signed out, and a Stop for the
/// banned destination.
class RequireSignIn extends RedirectRule<AppRoute> {
  RequireSignIn(this.log, {required this.signIn});

  final List<String> log;
  final LevelRoute Function() signIn;
  bool signedIn = false;
  final signIns = <LevelRoute>[];

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    log.add('signin(${route.id})');
    if (route.id == 'sign-in') return const RedirectResult.continueRedirect();
    if (route.id == 'banned') return const RedirectResult.stop();
    if (signedIn) return const RedirectResult.continueRedirect();
    final next = signIn();
    signIns.add(next);
    return RedirectResult.redirectTo(next);
  }
}

/// A rule typed to one route.
class ProfileOnlyRule extends RedirectRule<ProfilePage> {
  int calls = 0;

  @override
  RedirectResult<ProfilePage> redirectResult(
    CoordinatorCore coordinator,
    ProfilePage route,
  ) {
    calls++;
    return const RedirectResult.continueRedirect();
  }
}

// ===========================================================================
// Modules (one runtime type per module of a level)
// ===========================================================================

class AuthPlain extends NestedCoordinator {
  AuthPlain(super.parent) : super(extraLabel: 'auth');
}

class AuthScoped extends ScopedNested {
  AuthScoped(super.parent, {required super.rules}) : super(extraLabel: 'auth');
}

class ShopScoped extends ScopedNested {
  ShopScoped(super.parent, {required super.rules}) : super(extraLabel: 'shop');
}

// ===========================================================================
// Fixtures
// ===========================================================================

/// Root plus an auth module coordinator whose stack sits behind 'authShell'.
/// With [moduleRules] the module declares them (opted in); without, the tree
/// has no mixin anywhere (opted out).
class AuthTree {
  AuthTree({List<RedirectRule>? moduleRules}) {
    app = ModularAppCoordinator(
      modules: (c) => [
        auth = moduleRules == null
            ? AuthPlain(c)
            : AuthScoped(c, rules: moduleRules),
      ],
    );
    app.registerShell(key: 'authShell', path: auth.extra);
  }

  late final ModularAppCoordinator app;
  late final NestedCoordinator auth;
}

/// L1 and L5 compare a route-level placement with a module-level one.
abstract class Placement {
  List<String> get log;
  ModularAppCoordinator get app;

  /// A fresh gated destination behind the auth shell.
  LevelRoute profile();

  /// Every SignIn the rule created, in order.
  List<LevelRoute> get signIns;
}

/// L1 (a): RequireFlag in the routes' own rules, in an opted-out tree.
class FlagAtRouteLevel implements Placement {
  FlagAtRouteLevel(Verdict verdict) {
    state.verdict = verdict;
  }

  @override
  final log = <String>[];
  final state = FlagState();
  late final RequireFlag flag = RequireFlag(
    state,
    log,
    signIn: () => RuledRoute('sign-in', [flag], parentLayoutKey: 'authShell'),
  );
  late final tree = AuthTree();

  @override
  ModularAppCoordinator get app => tree.app;

  @override
  LevelRoute profile() =>
      RuledRoute('profile', [flag], parentLayoutKey: 'authShell');

  @override
  List<LevelRoute> get signIns => flag.signIns;
}

/// L1 (b): the same RequireFlag in the owning module's rules.
class FlagAtModuleLevel implements Placement {
  FlagAtModuleLevel(Verdict verdict) {
    state.verdict = verdict;
  }

  @override
  final log = <String>[];
  final state = FlagState();
  late final RequireFlag flag = RequireFlag(
    state,
    log,
    signIn: () => LevelRoute('sign-in', parentLayoutKey: 'authShell'),
  );
  late final tree = AuthTree(moduleRules: [flag]);

  @override
  ModularAppCoordinator get app => tree.app;

  @override
  LevelRoute profile() => LevelRoute('profile', parentLayoutKey: 'authShell');

  @override
  List<LevelRoute> get signIns => flag.signIns;
}

/// A route base whose redirectRules getter returns the app-wide rules.
class LegacyRoute extends RuledRoute {
  LegacyRoute(super.id, super.rules, {super.parentLayoutKey});
}

/// L5 old pattern: every route of the base carries the app-wide rules.
class LegacyPattern implements Placement {
  LegacyPattern({required bool signedIn}) {
    rule.signedIn = signedIn;
  }

  @override
  final log = <String>[];
  late final RequireSignIn rule = RequireSignIn(
    log,
    signIn: () =>
        LegacyRoute('sign-in', appRules, parentLayoutKey: 'authShell'),
  );
  late final List<RedirectRule> appRules = [rule];
  late final tree = AuthTree();

  @override
  ModularAppCoordinator get app => tree.app;

  @override
  LevelRoute profile() =>
      LegacyRoute('profile', appRules, parentLayoutKey: 'authShell');

  LevelRoute banned() => LegacyRoute('banned', appRules);

  @override
  List<LevelRoute> get signIns => rule.signIns;
}

/// L5 new pattern: the root declares the same rules; routes are plain.
class RootRulePattern implements Placement {
  RootRulePattern({required bool signedIn}) {
    rule.signedIn = signedIn;
    app = ScopedModularApp(
      rules: [rule],
      modules: (c) => [auth = AuthPlain(c)],
    );
    app.registerShell(key: 'authShell', path: auth.extra);
  }

  @override
  final log = <String>[];
  late final RequireSignIn rule = RequireSignIn(
    log,
    signIn: () => LevelRoute('sign-in', parentLayoutKey: 'authShell'),
  );

  @override
  late final ScopedModularApp app;
  late final AuthPlain auth;

  @override
  LevelRoute profile() => LevelRoute('profile', parentLayoutKey: 'authShell');

  LevelRoute banned() => LevelRoute('banned');

  @override
  List<LevelRoute> get signIns => rule.signIns;
}

// ===========================================================================
// Helpers
// ===========================================================================

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

void resetAll(CoordinatorCore coordinator) {
  for (final path in coordinator.paths) {
    path.reset();
  }
}

/// Resolves one fresh destination, then pushes another through the root,
/// and records everything L1 compares. The coordinator argument is left out.
Future<Map<String, Object?>> observe(
  Placement placement,
  LevelRoute Function() destination,
) async {
  final resolvedRoute = destination();
  final resolved = await RouteRedirect.resolve(resolvedRoute, placement.app);
  final resolveLog = [...placement.log];
  final resolveSignIns = [...placement.signIns];
  placement.log.clear();

  final pushed = destination();
  unawaited(placement.app.push(pushed));
  await settle();
  final pushSignIns = placement.signIns.skip(resolveSignIns.length).toList();

  return {
    'resolved': (resolved as AppRoute?)?.id,
    'resolve log': resolveLog,
    'resolved route discards': resolvedRoute.discards,
    'resolve sign-in discards': [for (final s in resolveSignIns) s.discards],
    'push log': [...placement.log],
    'stacks': stacksOf(placement.app),
    'pushed route discards': pushed.discards,
    'push sign-in discards': [for (final s in pushSignIns) s.discards],
  };
}

// ===========================================================================
// Tests
// ===========================================================================

void main() {
  group('L1 same rule class at both levels', () {
    final expected = <Verdict, Map<String, Object?>>{
      Verdict.pass: {
        'resolved': 'profile',
        'resolve log': ['flag(profile)'],
        'resolved route discards': 0,
        'resolve sign-in discards': <int>[],
        'push log': ['flag(profile)'],
        'stacks': {
          'root': ['authShell'],
          'nested': <String>[],
          'auth': ['profile'],
        },
        'pushed route discards': 0,
        'push sign-in discards': <int>[],
      },
      Verdict.stop: {
        'resolved': null,
        'resolve log': ['flag(profile)'],
        'resolved route discards': 1,
        'resolve sign-in discards': <int>[],
        'push log': ['flag(profile)'],
        'stacks': {
          'root': <String>[],
          'nested': <String>[],
          'auth': <String>[],
        },
        'pushed route discards': 1,
        'push sign-in discards': <int>[],
      },
      Verdict.toSignIn: {
        'resolved': 'sign-in',
        'resolve log': ['flag(profile)', 'flag(sign-in)'],
        'resolved route discards': 1,
        'resolve sign-in discards': [0],
        'push log': ['flag(profile)', 'flag(sign-in)'],
        'stacks': {
          'root': ['authShell'],
          'nested': <String>[],
          'auth': ['sign-in'],
        },
        'pushed route discards': 1,
        'push sign-in discards': [0],
      },
    };

    for (final verdict in Verdict.values) {
      test('L1 ${verdict.name}: route level and module level give the same '
          'result, stacks, discards and rule log', () async {
        final routeLevel = FlagAtRouteLevel(verdict);
        final moduleLevel = FlagAtModuleLevel(verdict);
        expect(routeLevel.app.redirectScopeOf(routeLevel.profile()), isEmpty);
        expect(moduleLevel.app.redirectScopeOf(moduleLevel.profile()), [
          moduleLevel.tree.auth,
        ]);

        final atRouteLevel = await observe(routeLevel, routeLevel.profile);
        final atModuleLevel = await observe(moduleLevel, moduleLevel.profile);

        expect(atModuleLevel, atRouteLevel);
        expect(atModuleLevel, expected[verdict]);
      });
    }
  });

  group('L2 the same rule instance at both levels', () {
    test('L2 it runs twice per pass: module level first, then route '
        'level', () async {
      final log = <String>[];
      final state = FlagState();
      late final RequireFlag flag;
      flag = RequireFlag(
        state,
        log,
        signIn: () => LevelRoute('sign-in', parentLayoutKey: 'authShell'),
      );
      final tree = AuthTree(moduleRules: [flag]);
      final profile = RuledRoute('profile', [
        flag,
      ], parentLayoutKey: 'authShell');

      // Called on the module instance, so the two levels receive different
      // coordinators: the tree root at module level, the call site at route
      // level. That tells the two invocations apart.
      unawaited(tree.auth.push(profile));
      await settle();

      expect(log, ['flag(profile)', 'flag(profile)']);
      expect(flag.coordinators, [same(tree.app), same(tree.auth)]);
      expect(stacksOf(tree.app), {
        'root': ['authShell'],
        'nested': <String>[],
        'auth': ['profile'],
      });
      expect(profile.discards, 0);
    });

    test('L2 a Stop at module level means the route-level copy never '
        'runs', () async {
      final log = <String>[];
      final state = FlagState()..verdict = Verdict.stop;
      late final RequireFlag flag;
      flag = RequireFlag(
        state,
        log,
        signIn: () => LevelRoute('sign-in', parentLayoutKey: 'authShell'),
      );
      final tree = AuthTree(moduleRules: [flag]);
      final profile = RuledRoute('profile', [
        flag,
      ], parentLayoutKey: 'authShell');

      unawaited(tree.auth.push(profile));
      await settle();

      expect(log, ['flag(profile)']);
      expect(flag.coordinators, [same(tree.app)]);
      final routeLevelCalls = flag.coordinators
          .where((c) => identical(c, tree.auth))
          .length;
      expect(routeLevelCalls, 0);
      expect(stacksOf(tree.app), {
        'root': <String>[],
        'nested': <String>[],
        'auth': <String>[],
      });
      expect(profile.discards, 1);
    });
  });

  group('L3 RedirectTo from a route-level rule', () {
    test('L3 a route-level RedirectTo into another module stack gets that '
        'module chain from the top', () async {
      final log = <String>[];
      late final NestedCoordinator auth;
      late final NestedCoordinator shop;
      final app = ScopedModularApp(
        rules: [RecordingRule('app', log)],
        modules: (c) => [
          auth = AuthScoped(c, rules: [RecordingRule('auth', log)]),
          shop = ShopScoped(c, rules: [RecordingRule('shop', log)]),
        ],
      );
      app.registerShell(key: 'authShell', path: auth.extra);
      app.registerShell(key: 'shopShell', path: shop.extra);
      final toCart = ToCart(log);
      expect(
        app.redirectScopeOf(LevelRoute('c', parentLayoutKey: 'shopShell')),
        [app, shop],
      );

      for (final (label, CoordinatorMutatable<AppRoute> callSite) in [
        ('root', app),
        ('auth instance', auth),
      ]) {
        log.clear();
        resetAll(app);
        await settle();
        final profile = RuledRoute('profile', [
          toCart,
        ], parentLayoutKey: 'authShell');

        unawaited(callSite.push(profile));
        await settle();

        expect(log, [
          'app(profile)',
          'auth(profile)',
          'own(profile)',
          'app(cart)',
          'shop(cart)',
        ], reason: label);
        expect(stacksOf(app), {
          'root': ['shopShell'],
          'nested': <String>[],
          'auth': <String>[],
          'shop': ['cart'],
        }, reason: label);
        expect(profile.discards, 1, reason: label);
        expect(toCart.carts.last.discards, 0, reason: label);
      }
    });
  });

  group('L4 the coordinator argument', () {
    test('L4 module-level rules receive the tree root from every call site; '
        'route-level rules receive the call site', () async {
      // The one deliberate difference between the levels. Module rules are
      // scoped to a tree, so they get its root whatever the entry point;
      // route rules keep upstream behaviour (back-compat) and get whichever
      // coordinator or path the navigation went through. A path's
      // coordinator is the erased parent, which is the root at depth 1.
      // Rules that need module state should capture it at construction.
      final log = <String>[];
      final moduleRule = RecordingRule('module', log);
      final routeRule = RecordingRule('route', log);
      late final NestedCoordinator auth;
      late final NestedCoordinator shop;
      final app = ScopedModularApp(
        rules: [],
        modules: (c) => [
          auth = AuthScoped(c, rules: [moduleRule]),
          shop = ShopScoped(c, rules: []),
        ],
      );
      app.registerShell(key: 'authShell', path: auth.extra);
      expect(auth.extra.coordinator, same(app));

      final callSites = <(String, Future<void> Function(AppRoute), Object)>[
        ('root', (r) => app.pushSilently(r), app),
        ('auth instance', (r) => auth.pushSilently(r), auth),
        ('shop instance', (r) => shop.pushSilently(r), shop),
        ('path level', (r) => auth.extra.pushSilently(r), app),
      ];
      for (final (label, push, routeLevelCoordinator) in callSites) {
        log.clear();
        moduleRule.coordinators.clear();
        routeRule.coordinators.clear();
        resetAll(app);
        await settle();
        final profile = RuledRoute('profile', [
          routeRule,
        ], parentLayoutKey: 'authShell');

        await push(profile);

        expect(log, ['module(profile)', 'route(profile)'], reason: label);
        expect(moduleRule.coordinators, [same(app)], reason: label);
        expect(routeRule.coordinators, [
          same(routeLevelCoordinator),
        ], reason: label);
        expect(auth.extra.stack, [same(profile)], reason: label);
        expect(profile.discards, 0, reason: label);
      }
    });
  });

  group('L5 migration from a route-base redirectRules getter', () {
    Future<void> expectSameFlow(
      String flow,
      Placement Function() legacy,
      Placement Function() rootRule,
      LevelRoute Function(Placement) destination,
      Map<String, Object?> expected,
    ) async {
      final old = legacy();
      final migrated = rootRule();
      final before = await observe(old, () => destination(old));
      final after = await observe(migrated, () => destination(migrated));
      expect(after, before, reason: flow);
      expect(after, expected, reason: flow);
    }

    test('L5 signed out, push the gated route: SignIn in both patterns', () {
      return expectSameFlow(
        'signed out',
        () => LegacyPattern(signedIn: false),
        () => RootRulePattern(signedIn: false),
        (p) => p.profile(),
        {
          'resolved': 'sign-in',
          'resolve log': ['signin(profile)', 'signin(sign-in)'],
          'resolved route discards': 1,
          'resolve sign-in discards': [0],
          'push log': ['signin(profile)', 'signin(sign-in)'],
          'stacks': {
            'root': ['authShell'],
            'nested': <String>[],
            'auth': ['sign-in'],
          },
          'pushed route discards': 1,
          'push sign-in discards': [0],
        },
      );
    });

    test('L5 signed in, push the gated route: Profile in both patterns', () {
      return expectSameFlow(
        'signed in',
        () => LegacyPattern(signedIn: true),
        () => RootRulePattern(signedIn: true),
        (p) => p.profile(),
        {
          'resolved': 'profile',
          'resolve log': ['signin(profile)'],
          'resolved route discards': 0,
          'resolve sign-in discards': <int>[],
          'push log': ['signin(profile)'],
          'stacks': {
            'root': ['authShell'],
            'nested': <String>[],
            'auth': ['profile'],
          },
          'pushed route discards': 0,
          'push sign-in discards': <int>[],
        },
      );
    });

    test('L5 a Stop: nothing is committed in both patterns', () {
      return expectSameFlow(
        'stop',
        () => LegacyPattern(signedIn: true),
        () => RootRulePattern(signedIn: true),
        (p) => switch (p) {
          LegacyPattern() => p.banned(),
          RootRulePattern() => p.banned(),
          _ => throw StateError('unknown pattern $p'),
        },
        {
          'resolved': null,
          'resolve log': ['signin(banned)'],
          'resolved route discards': 1,
          'resolve sign-in discards': <int>[],
          'push log': ['signin(banned)'],
          'stacks': {
            'root': <String>[],
            'nested': <String>[],
            'auth': <String>[],
          },
          'pushed route discards': 1,
          'push sign-in discards': <int>[],
        },
      );
    });
  });

  group('L6 the typed-rule pitfall', () {
    test(
      'L6 a RedirectRule<ProfilePage> is safe on ProfilePage, but moved '
      'to the auth module it is offered SignIn and throws TypeError',
      () async {
        // Documented, not filtered: type module rules to the base the module's
        // stacks host. Switching to type filtering must be a visible change.
        final routeLevelRule = ProfileOnlyRule();
        final plain = AuthTree();
        final ruled = RuledProfilePage([routeLevelRule]);
        expect(await RouteRedirect.resolve(ruled, plain.app), same(ruled));
        expect(routeLevelRule.calls, 1);

        final moduleRule = ProfileOnlyRule();
        final tree = AuthTree(moduleRules: [moduleRule]);
        final profile = ProfilePage();
        expect(await RouteRedirect.resolve(profile, tree.app), same(profile));
        expect(moduleRule.calls, 1);

        // SignIn lands in the same stack, so the module offers it the rule.
        final signIn = SignInPage();
        await expectLater(
          RouteRedirect.resolve(signIn, tree.app),
          throwsA(isA<TypeError>()),
        );
        final pushed = SignInPage();
        await expectLater(tree.app.push(pushed), throwsA(isA<TypeError>()));
        await settle();

        expect(moduleRule.calls, 1);
        expect(stacksOf(tree.app), {
          'root': <String>[],
          'nested': <String>[],
          'auth': <String>[],
        });
        // The rule's TypeError propagates. resolve discards only on its own
        // errors, as upstream does, so the fresh route is not discarded.
        expect([signIn.discards, pushed.discards], [0, 0]);
      },
    );
  });
}
