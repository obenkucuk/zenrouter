// Drives the real scoped-redirect example (lib/main_coordinator_redirect.dart
// and lib/coordinator_redirect/) through MaterialApp.router, with real taps
// where a user would tap. Every test asserts on what is on screen and on the
// host's rule trace; most also pin the full stack of every path.
//
// E1-E13 are the example tests of the scoped-redirect plan (#104). The hub is
// the host's home page (brief O-4), so a cold start runs OnboardingGate only.
//
// A tab destination reached through the coordinator resolves twice: the
// coordinator operation resolves it, then IndexedStackPath.activateRoute
// switches through goToIndexed, which resolves the entry again. E7 pins it
// for the hub's Billing button; the bottom bar, which calls goToIndexed
// directly, resolves once.

import 'dart:async';

import 'package:example/coordinator_redirect/app_module.dart';
import 'package:example/coordinator_redirect/auth_module.dart';
import 'package:example/coordinator_redirect/feed_module.dart';
import 'package:example/coordinator_redirect/security_module.dart';
import 'package:example/coordinator_redirect/shop_module.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

/// Every layout parent of the app: shells and branch roots.
const layouts = [
  'ShopShell',
  'FeedLayout',
  'ForYouBranch',
  'FollowingBranch',
  'AuthLayout',
  'SecurityLayout',
];

/// One pass of [rule] on [route] that continued.
String pass(String rule, String route) => '$rule($route) → continue';

/// Matches a list of modules element by element, by identity: coordinators
/// extend Equatable, so `==` alone could match another of the same type.
Matcher sameModules(List<Object> modules) =>
    equals([for (final module in modules) same(module)]);

/// One route of every type the app shows, layouts included.
List<RouteTarget> everyRoute() => [
  HubRoute(),
  OnboardingRoute(),
  NotFoundRoute(Uri.parse('/x')),
  ShopShell(),
  HomeTab(),
  CatalogTab(),
  BillingTab(),
  FeedLayout(),
  ForYouBranch(),
  FollowingBranch(),
  FeedListRoute(FeedBranch.forYou),
  PostRoute(FeedBranch.forYou, 1),
  AuthLayout(),
  SignInRoute(),
  ProfileRoute(),
  SecurityLayout(),
  SecuritySettingsRoute(),
];

/// The label [route] declares through its module's route base.
String labelOf(RouteTarget route) => switch (route) {
  HostRoute(:final label) ||
  ShopRoute(:final label) ||
  FeedRoute(:final label) ||
  AuthRoute(:final label) ||
  SecurityRoute(:final label) => label,
  _ => throw ArgumentError.value(route, 'route', 'declares no label'),
};

/// [route] as the path inspector should show it: its label, then its props.
String shownAs(RouteTarget route) => route.props.isEmpty
    ? labelOf(route)
    : '${labelOf(route)}[${route.props.join(',')}]';

// Types renamed the way dart2js renames them in a release web build. Each one
// keeps the label it inherits while its runtimeType says something else, so a
// name read from the type shows up as `Renamed…` instead of the label. The VM
// never minifies, so these stand in for a release build.

class RenamedAppCoordinator extends AppCoordinator {
  late final List<RedirectRule> _rules = [RenamedOnboardingGate(host)];

  @override
  List<RedirectRule> get redirectRules => _rules;
}

class RenamedOnboardingGate extends OnboardingGate {
  RenamedOnboardingGate(super.host);
}

class RenamedSubscriptionGate extends SubscriptionGate {
  RenamedSubscriptionGate(super.account, super.trace);
}

class RenamedRequireSession extends RequireSession {
  RenamedRequireSession(super.session, super.trace);
}

class RenamedRequireTwoFactor extends RequireTwoFactor {
  RenamedRequireTwoFactor(super.status, super.trace);
}

class RenamedHub extends HubRoute {}

class RenamedCatalog extends CatalogTab {}

class RenamedPost extends PostRoute {
  RenamedPost(super.branch, super.id);
}

class RenamedProfile extends ProfileRoute {}

class RenamedSecuritySettings extends SecuritySettingsRoute {}

class RenamedShopModule extends ShopModule {
  RenamedShopModule(
    super.coordinator, {
    required super.account,
    required super.trace,
  });
}

class RenamedFeedModule extends NewsFeedModule {
  RenamedFeedModule(super.coordinator);
}

class RenamedAuthCoordinator extends AuthRouteModuleCoordinator {
  RenamedAuthCoordinator(
    super.coordinator, {
    required super.session,
    required super.trace,
    required super.subModules,
  });
}

class RenamedSecurityModule extends SecurityModule {
  RenamedSecurityModule(
    super.coordinator, {
    required super.status,
    required super.trace,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppCoordinator c;

  setUp(() {
    // A fresh tree per test: new host state, new module state and new
    // stacks, composed exactly as the entry point composes them.
    //
    // One tree cannot be carried into the next test. Its router delegate
    // chains every URL navigation on a completed future created in the
    // fake-async zone of the test that first used it; Dart runs that
    // future's callbacks in that zone, which is never flushed again, so from
    // the second test on the router would not even open the initial route.
    c = AppCoordinator();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CoordinatorRedirectApp(coordinator: c));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) =>
      tap(tester, find.byKey(Key(key)));

  Future<void> back(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  Finder navBar(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  Finder branchControl(String label) => find.descendant(
    of: find.byKey(const Key('feed-branch-control')),
    matching: find.text(label),
  );

  Finder inRow(String label, String text) => find.descendant(
    of: find.byKey(Key('path-$label')),
    matching: find.text(text),
  );

  List<String> trace() => [...c.host.trace.value];

  /// The routes [rule] was offered, in order.
  List<String> saw(String rule) => [
    for (final line in c.host.trace.value)
      if (line.startsWith('$rule('))
        line.substring(rule.length + 1, line.indexOf(')')),
  ];

  /// Every path of the app, by label, with its entries named as the path
  /// inspector names them.
  Map<String, List<String>> stacks() => {
    for (final path in c.paths)
      path.debugLabel!: [for (final route in path.stack) entryLabel(route)],
  };

  /// The stacks of a fresh app, with [changes] applied.
  Map<String, List<String>> stacksWith(Map<String, List<String>> changes) => {
    'root': <String>[],
    'shop-tabs': ['HomeTab', 'CatalogTab', 'BillingTab'],
    'feed-branches': ['ForYouBranch', 'FollowingBranch'],
    'feed-for-you': <String>[],
    'feed-following': <String>[],
    'auth': <String>[],
    'security': <String>[],
    ...changes,
  };

  testWidgets('E1 a cold start opens the hub on the root stack, gated by the '
      'root rule only', (tester) async {
    await pumpApp(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'HubRoute')]);
    expect(find.text(pass('OnboardingGate', 'HubRoute')), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );
    expect(c.currentUri, Uri.parse('/'));
  });

  testWidgets('E2 signed out, tapping Profile lands on SignIn inside the auth '
      'shell; signing in continues to Profile', (tester) async {
    await pumpApp(tester);
    c.host.clearTrace();

    await tapKey(tester, 'hub-profile');

    expect(
      find.text('auth shell · AuthRouteModuleCoordinator · RequireSession'),
      findsOneWidget,
    );
    expect(
      find.text(
        'RequireSession sent you here: /account/profile needs a '
        'session.',
      ),
      findsOneWidget,
    );
    expect(trace(), [
      pass('OnboardingGate', 'ProfileRoute'),
      'RequireSession(ProfileRoute) → SignInRoute (no session)',
      pass('OnboardingGate', 'SignInRoute'),
      pass('RequireSession', 'SignInRoute'),
    ]);
    expect(saw('SubscriptionGate'), isEmpty);
    expect(saw('RequireTwoFactor'), isEmpty);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['SignInRoute'],
      }),
    );
    expect(c.currentUri, Uri.parse('/account/sign-in'));

    c.host.clearTrace();
    await tapKey(tester, 'auth-sign-in');

    expect(
      find.text(
        'Signed in. OnboardingGate and RequireSession let this through.',
      ),
      findsOneWidget,
    );
    expect(trace(), [
      pass('OnboardingGate', 'ProfileRoute'),
      pass('RequireSession', 'ProfileRoute'),
    ]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['ProfileRoute'],
      }),
    );
    expect(c.currentUri, Uri.parse('/account/profile'));
  });

  testWidgets('E3 after tab taps, the feed and back home, the auth and '
      'security rules have seen nothing', (tester) async {
    await pumpApp(tester);
    c.host.clearTrace();

    await tapKey(tester, 'hub-shop-home');
    await tap(tester, navBar('Catalog'));
    await tap(tester, navBar('Billing'));
    await tap(tester, navBar('Home'));
    await back(tester);
    await tapKey(tester, 'hub-feed');
    await tapKey(tester, 'post-for-you-1');
    // Back to the list, then out of the feed.
    await back(tester);
    await back(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(trace(), [
      pass('OnboardingGate', 'HomeTab'),
      pass('SubscriptionGate', 'HomeTab'),
      pass('OnboardingGate', 'CatalogTab'),
      pass('SubscriptionGate', 'CatalogTab'),
      pass('OnboardingGate', 'BillingTab'),
      'SubscriptionGate(BillingTab) → stop (no subscription)',
      pass('OnboardingGate', 'HomeTab'),
      pass('SubscriptionGate', 'HomeTab'),
      pass('OnboardingGate', 'FeedListRoute'),
      pass('OnboardingGate', 'PostRoute'),
    ]);
    expect(saw('RequireSession'), isEmpty);
    expect(saw('RequireTwoFactor'), isEmpty);
    expect(saw('SubscriptionGate').toSet(), {
      'HomeTab',
      'CatalogTab',
      'BillingTab',
    });
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );

    await tap(tester, find.text('Rule trace'));
    expect(find.text('RequireSession: nothing'), findsOneWidget);
    expect(find.text('RequireTwoFactor: nothing'), findsOneWidget);
    expect(
      find.text('SubscriptionGate: HomeTab, CatalogTab, BillingTab'),
      findsOneWidget,
    );
    expect(
      find.text(
        'OnboardingGate: HomeTab, CatalogTab, BillingTab, FeedListRoute, '
        'PostRoute',
      ),
      findsOneWidget,
    );
  });

  testWidgets('E4 feed pages, by coordinator, deep link and path-level push, '
      'never reach SubscriptionGate; Billing from the feed is stopped', (
    tester,
  ) async {
    await pumpApp(tester);
    final all = <String>[];

    // Deep link.
    c.host.clearTrace();
    await c.routerDelegate.setNewRoutePath(Uri.parse('/feed'));
    await tester.pumpAndSettle();

    expect(find.text('For you feed'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'FeedListRoute')]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
      }),
    );
    expect(c.currentUri, Uri.parse('/feed/for-you'));
    all.addAll(trace());

    // Through the coordinator.
    await back(tester);
    c.host.clearTrace();
    unawaited(c.push(FeedListRoute(FeedBranch.forYou)));
    await tester.pumpAndSettle();

    expect(find.text('For you feed'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'FeedListRoute')]);
    all.addAll(trace());

    // The feed page's link to Billing, by URI, without a subscription.
    c.host.clearTrace();
    await tapKey(tester, 'feed-for-you-link-billing');

    expect(trace(), [
      pass('OnboardingGate', 'BillingTab'),
      'SubscriptionGate(BillingTab) → stop (no subscription)',
    ]);
    expect(
      find.text('SubscriptionGate(BillingTab) → stop (no subscription)'),
      findsOneWidget,
    );
    expect(find.text('For you feed'), findsOneWidget);
    expect(c.shop.tabs.activeIndex, 0);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
      }),
    );
    all.addAll(trace());

    // Path-level push into the branch child stack.
    c.host.clearTrace();
    unawaited(c.feed.forYouStack.push(PostRoute(FeedBranch.forYou, 7)));
    await tester.pumpAndSettle();

    expect(find.text('Post 7 · For you'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'PostRoute')]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]', 'PostRoute[for-you,7]'],
      }),
    );
    all.addAll(trace());

    final subscription = [
      for (final line in all)
        if (line.startsWith('SubscriptionGate(')) line,
    ];
    expect(subscription, [
      'SubscriptionGate(BillingTab) → stop (no subscription)',
    ]);
    expect(all.where((line) => line.startsWith('RequireSession(')), isEmpty);
  });

  testWidgets('E5 the security module, two levels deep, runs after the root '
      'and auth rules; a Stop cancels', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'flag-signed-in');
    c.host.clearTrace();

    // Signed in, 2FA off: the chain runs root, auth, security, and stops.
    await tapKey(tester, 'hub-security');

    expect(trace(), [
      pass('OnboardingGate', 'SecuritySettingsRoute'),
      pass('RequireSession', 'SecuritySettingsRoute'),
      'RequireTwoFactor(SecuritySettingsRoute) → stop (2FA is off)',
    ]);
    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(find.text('Security settings'), findsNothing);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );

    // 2FA on: the same tap opens the page.
    await tapKey(tester, 'flag-two-factor');
    c.host.clearTrace();
    await tapKey(tester, 'hub-security');

    expect(find.text('Security settings'), findsOneWidget);
    expect(trace(), [
      pass('OnboardingGate', 'SecuritySettingsRoute'),
      pass('RequireSession', 'SecuritySettingsRoute'),
      pass('RequireTwoFactor', 'SecuritySettingsRoute'),
    ]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'SecurityLayout'],
        'security': ['SecuritySettingsRoute'],
      }),
    );

    // RequireTwoFactor never sees the auth module's own pages.
    await back(tester);
    c.host.clearTrace();
    await tapKey(tester, 'hub-profile');

    expect(find.text('Your profile'), findsOneWidget);
    expect(trace(), [
      pass('OnboardingGate', 'ProfileRoute'),
      pass('RequireSession', 'ProfileRoute'),
    ]);

    // Signed out: RequireSession redirects first, so RequireTwoFactor, which
    // runs after it, is never consulted.
    await back(tester);
    await tapKey(tester, 'flag-signed-in');
    c.host.clearTrace();
    await tapKey(tester, 'hub-security');

    expect(find.text('Sign in'), findsOneWidget);
    expect(trace(), [
      pass('OnboardingGate', 'SecuritySettingsRoute'),
      'RequireSession(SecuritySettingsRoute) → SignInRoute (no session)',
      pass('OnboardingGate', 'SignInRoute'),
      pass('RequireSession', 'SignInRoute'),
    ]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['SignInRoute'],
      }),
    );
  });

  testWidgets('E6 ProfileRoute gets the same chain from every entry point, '
      'including links from two other modules', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'flag-signed-in');

    const profilePass = [
      'OnboardingGate(ProfileRoute) → continue',
      'RequireSession(ProfileRoute) → continue',
    ];
    List<String> passes(int count) => [
      for (var i = 0; i < count; i++) ...profilePass,
    ];

    Future<List<String>> traceOf(Future<void> Function() navigation) async {
      unawaited(c.replace(HubRoute()));
      await tester.pumpAndSettle();
      c.host.clearTrace();
      await navigation();
      await tester.pumpAndSettle();
      return trace();
    }

    // The number of passes is the number of times the operation resolves:
    // replace also resolves in NavigationPath.activateRoute, and recover
    // resolves, then replaces.
    expect(
      await traceOf(() async => unawaited(c.push(ProfileRoute()))),
      passes(1),
    );
    expect(find.text('Your profile'), findsOneWidget);
    expect(await traceOf(() => c.navigate(ProfileRoute())), passes(1));
    expect(find.text('Your profile'), findsOneWidget);
    expect(await traceOf(() => c.replace(ProfileRoute())), passes(2));
    expect(find.text('Your profile'), findsOneWidget);
    expect(await traceOf(() => c.pushOrMoveToTop(ProfileRoute())), passes(1));
    expect(find.text('Your profile'), findsOneWidget);
    expect(await traceOf(() => c.recover(ProfileRoute())), passes(3));
    expect(find.text('Your profile'), findsOneWidget);
    expect(
      await traceOf(
        () => c.routerDelegate.setNewRoutePath(Uri.parse('/account/profile')),
      ),
      passes(1),
    );
    expect(find.text('Your profile'), findsOneWidget);

    // Path level: the route commits into the auth stack only; the shell is
    // not mounted, as for any path-level push.
    expect(
      await traceOf(
        () async => unawaited(c.auth.authStack.push(ProfileRoute())),
      ),
      passes(1),
    );
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
        'auth': ['ProfileRoute'],
      }),
    );

    // A link from the feed module, by URI.
    unawaited(c.replace(HubRoute()));
    await tester.pumpAndSettle();
    await tapKey(tester, 'hub-feed');
    c.host.clearTrace();
    await tapKey(tester, 'feed-for-you-link-profile');

    expect(find.text('Your profile'), findsOneWidget);
    expect(trace(), passes(1));
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout', 'AuthLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
        'auth': ['ProfileRoute'],
      }),
    );

    // A link from the shop module, by URI.
    unawaited(c.replace(HubRoute()));
    await tester.pumpAndSettle();
    await tapKey(tester, 'hub-shop-home');
    c.host.clearTrace();
    await tapKey(tester, 'shop-link-profile');

    expect(find.text('Your profile'), findsOneWidget);
    expect(trace(), passes(1));
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'ShopShell', 'AuthLayout'],
        'auth': ['ProfileRoute'],
      }),
    );
  });

  // Signed out, ProfileRoute is redirected to SignInRoute by RequireSession,
  // and SignInRoute runs its own chain from the top: the same trace as the
  // hub's Profile button (E2), whichever module's page the link is on.
  final signedOutProfile = [
    pass('OnboardingGate', 'ProfileRoute'),
    'RequireSession(ProfileRoute) → SignInRoute (no session)',
    pass('OnboardingGate', 'SignInRoute'),
    pass('RequireSession', 'SignInRoute'),
  ];

  testWidgets('E6 signed out, the profile link on a shop page lands on SignIn '
      'with the same chain as from the hub, and SubscriptionGate never sees '
      'it', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-shop-home');
    c.host.clearTrace();

    await tapKey(tester, 'shop-link-profile');

    expect(find.text('Sign in'), findsOneWidget);
    expect(
      find.text(
        'RequireSession sent you here: /account/profile needs a session.',
      ),
      findsOneWidget,
    );
    expect(trace(), signedOutProfile);
    expect(saw('SubscriptionGate'), isEmpty);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'ShopShell', 'AuthLayout'],
        'auth': ['SignInRoute'],
      }),
    );
    expect(c.currentUri, Uri.parse('/account/sign-in'));
  });

  testWidgets('E6 signed out, the profile link on a feed page lands on SignIn '
      'with the same chain as from the hub', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-feed');
    c.host.clearTrace();

    await tapKey(tester, 'feed-for-you-link-profile');

    expect(find.text('Sign in'), findsOneWidget);
    expect(
      find.text(
        'RequireSession sent you here: /account/profile needs a session.',
      ),
      findsOneWidget,
    );
    expect(trace(), signedOutProfile);
    expect(saw('SubscriptionGate'), isEmpty);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout', 'AuthLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
        'auth': ['SignInRoute'],
      }),
    );
    expect(c.currentUri, Uri.parse('/account/sign-in'));
  });

  testWidgets('E7 tapping Billing on the bottom bar calls goToIndexed '
      'directly: SubscriptionGate stops it unsubscribed, and lets it through '
      'subscribed', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-shop-home');
    c.host.clearTrace();

    await tap(tester, navBar('Billing'));

    expect(c.shop.tabs.activeIndex, 0);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    expect(find.text('Shop home'), findsOneWidget);
    expect(trace(), [
      pass('OnboardingGate', 'BillingTab'),
      'SubscriptionGate(BillingTab) → stop (no subscription)',
    ]);
    expect(
      find.text('SubscriptionGate(BillingTab) → stop (no subscription)'),
      findsOneWidget,
    );
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'ShopShell'],
      }),
    );
    await tap(tester, find.text('Rule trace'));
    expect(find.text('SubscriptionGate: BillingTab'), findsOneWidget);

    // Subscribe on the shop's own page; the same tap now switches.
    await tapKey(tester, 'shop-subscribed');
    c.host.clearTrace();
    await tap(tester, navBar('Billing'));

    expect(c.shop.tabs.activeIndex, 2);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(
      find.text('Subscribed: SubscriptionGate let this tab through.'),
      findsOneWidget,
    );
    expect(trace(), [
      pass('OnboardingGate', 'BillingTab'),
      pass('SubscriptionGate', 'BillingTab'),
    ]);

    // Through the coordinator, from the hub's Billing button, the tab
    // resolves twice: push resolves it, then activateRoute switches through
    // goToIndexed, which resolves the entry again.
    await back(tester);
    expect(c.shop.tabs.activeIndex, 0);
    c.host.clearTrace();
    await tapKey(tester, 'hub-billing');

    expect(c.shop.tabs.activeIndex, 2);
    expect(
      find.text('Subscribed: SubscriptionGate let this tab through.'),
      findsOneWidget,
    );
    expect(trace(), [
      pass('OnboardingGate', 'BillingTab'),
      pass('SubscriptionGate', 'BillingTab'),
      pass('OnboardingGate', 'BillingTab'),
      pass('SubscriptionGate', 'BillingTab'),
    ]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'ShopShell'],
      }),
    );
  });

  testWidgets('E8 not onboarded, the root rule redirects before any module '
      'rule runs; finishing onboarding lets the same tap through', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapKey(tester, 'flag-onboarded');
    c.host.clearTrace();

    await tapKey(tester, 'hub-feed');

    expect(
      find.text('OnboardingGate sent you here: the app is not onboarded yet.'),
      findsOneWidget,
    );
    expect(trace(), [
      'OnboardingGate(FeedListRoute) → OnboardingRoute (not onboarded)',
      pass('OnboardingGate', 'OnboardingRoute'),
    ]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'OnboardingRoute'],
      }),
    );

    c.host.clearTrace();
    await tapKey(tester, 'finish-onboarding');

    expect(find.text('For you feed'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'FeedListRoute')]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
      }),
    );

    // Profile: RequireSession is not consulted for the original route.
    await back(tester);
    await tapKey(tester, 'flag-onboarded');
    c.host.clearTrace();
    await tapKey(tester, 'hub-profile');

    expect(trace(), [
      'OnboardingGate(ProfileRoute) → OnboardingRoute (not onboarded)',
      pass('OnboardingGate', 'OnboardingRoute'),
    ]);
    expect(saw('RequireSession'), isEmpty);
    expect(saw('SubscriptionGate'), isEmpty);

    c.host.clearTrace();
    await tapKey(tester, 'finish-onboarding');

    expect(find.text('Sign in'), findsOneWidget);
    expect(trace(), [
      pass('OnboardingGate', 'ProfileRoute'),
      'RequireSession(ProfileRoute) → SignInRoute (no session)',
      pass('OnboardingGate', 'SignInRoute'),
      pass('RequireSession', 'SignInRoute'),
    ]);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['SignInRoute'],
      }),
    );
  });

  test('E9 redirectScopeOf pins the chain of every destination, the same '
      'from the root and from the auth coordinator', () {
    final root = same(c);
    final shop = same(c.shop);
    final auth = same(c.auth);
    final security = same(c.security);

    for (final from in <CoordinatorCore>[c, c.auth]) {
      expect(from.redirectScopeOf(HubRoute()), [root]);
      expect(from.redirectScopeOf(OnboardingRoute()), [root]);
      expect(from.redirectScopeOf(NotFoundRoute(Uri.parse('/x'))), [root]);
      expect(from.redirectScopeOf(HomeTab()), [root, shop]);
      expect(from.redirectScopeOf(CatalogTab()), [root, shop]);
      expect(from.redirectScopeOf(BillingTab()), [root, shop]);
      for (final branch in FeedBranch.values) {
        expect(from.redirectScopeOf(FeedListRoute(branch)), [root]);
        expect(from.redirectScopeOf(PostRoute(branch, 1)), [root]);
      }
      expect(from.redirectScopeOf(SignInRoute()), [root, auth]);
      expect(from.redirectScopeOf(ProfileRoute()), [root, auth]);
      expect(from.redirectScopeOf(SecuritySettingsRoute()), [
        root,
        auth,
        security,
      ]);
      for (final layout in <RouteTarget>[
        ShopShell(),
        FeedLayout(),
        ForYouBranch(),
        FollowingBranch(),
        AuthLayout(),
        SecurityLayout(),
      ]) {
        expect(from.redirectScopeOf(layout), isEmpty, reason: '$layout');
      }
    }
  });

  testWidgets('E10 after visiting every page, no layout parent was ever '
      'offered to a rule', (tester) async {
    await pumpApp(tester);
    final mounted = <String>{};
    void noteMounted() =>
        mounted.addAll([for (final route in c.root.stack) '$route']);

    // The session comes from the sign-in page below, not from its flag: a
    // signed-in user is sent away from that page, and this walk visits it.
    await tapKey(tester, 'flag-subscribed');
    await tapKey(tester, 'flag-two-factor');

    await tapKey(tester, 'hub-shop-home');
    noteMounted();
    await tap(tester, navBar('Catalog'));
    await tap(tester, navBar('Billing'));
    await tap(tester, navBar('Home'));
    await back(tester);

    await tapKey(tester, 'hub-feed');
    noteMounted();
    await tapKey(tester, 'post-for-you-1');
    await tap(tester, branchControl('Following'));
    await tapKey(tester, 'feed-open-following');
    await tapKey(tester, 'post-following-1');
    expect(find.text('Post 1 · Following'), findsOneWidget);
    await tap(tester, branchControl('For you'));
    // Back to the For you list, then out of the feed.
    await back(tester);
    await back(tester);

    await tapKey(tester, 'hub-sign-in');
    noteMounted();
    await tapKey(tester, 'auth-sign-in');
    expect(find.text('Your profile'), findsOneWidget);
    await tapKey(tester, 'auth-link-security');
    noteMounted();
    expect(find.text('Security settings'), findsOneWidget);
    await back(tester);
    await back(tester);

    await tapKey(tester, 'flag-onboarded');
    await tapKey(tester, 'hub-catalog');
    noteMounted();
    await tapKey(tester, 'finish-onboarding');
    noteMounted();
    expect(find.text('Catalog'), findsWidgets);

    expect(
      mounted,
      containsAll([
        'ShopShell',
        'FeedLayout',
        'AuthLayout',
        'SecurityLayout',
        'OnboardingRoute',
      ]),
    );
    for (final rule in c.ruleNames) {
      expect(saw(rule), isNotEmpty, reason: '$rule ran during the walk');
    }
    for (final layout in layouts) {
      expect(
        trace().where((line) => line.contains('($layout)')),
        isEmpty,
        reason: '$layout is a layout parent',
      );
    }
  });

  testWidgets('E11 switching feed branches with the branch control offers '
      'nothing to any rule, and each branch keeps its depth', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-feed');
    await tapKey(tester, 'post-for-you-1');
    await tapKey(tester, 'post-next');
    expect(find.text('Post 2 · For you'), findsOneWidget);
    const forYouDepth3 = [
      'FeedListRoute[for-you]',
      'PostRoute[for-you,1]',
      'PostRoute[for-you,2]',
    ];

    c.host.clearTrace();
    await tap(tester, branchControl('Following'));

    expect(trace(), isEmpty);
    expect(c.feed.branches.activeBranchIndex, 1);
    expect(find.text('Nothing in Following yet.'), findsOneWidget);
    expect(c.feed.forYouStack.stack.map(entryLabel), forYouDepth3);

    await tapKey(tester, 'feed-open-following');

    expect(find.text('Following feed'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'FeedListRoute')]);

    c.host.clearTrace();
    await tap(tester, branchControl('For you'));

    expect(trace(), isEmpty);
    expect(c.feed.branches.activeBranchIndex, 0);
    expect(find.text('Post 2 · For you'), findsOneWidget);

    await tap(tester, branchControl('Following'));

    expect(trace(), isEmpty);
    expect(find.text('Following feed'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': forYouDepth3,
        'feed-following': ['FeedListRoute[following]'],
      }),
    );

    // A coordinator push into the other branch switches branches through
    // goToIndexed too; the branch root is still never offered.
    c.host.clearTrace();
    unawaited(c.push(PostRoute(FeedBranch.forYou, 9)));
    await tester.pumpAndSettle();

    expect(c.feed.branches.activeBranchIndex, 0);
    expect(find.text('Post 9 · For you'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'PostRoute')]);
    for (final layout in layouts) {
      expect(
        c.host.trace.value.where((line) => line.contains('($layout)')),
        isEmpty,
      );
    }
  });

  testWidgets('E12 a post pushed through the coordinator, the child path or a '
      'URI is gated by OnboardingGate only', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-feed');
    final all = <String>[];

    // Through the coordinator: a real tap on a post.
    c.host.clearTrace();
    await tapKey(tester, 'post-for-you-1');
    expect(find.text('Post 1 · For you'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'PostRoute')]);
    all.addAll(trace());

    // Through the branch child path.
    c.host.clearTrace();
    unawaited(c.feed.forYouStack.push(PostRoute(FeedBranch.forYou, 12)));
    await tester.pumpAndSettle();
    expect(find.text('Post 12 · For you'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'PostRoute')]);
    all.addAll(trace());

    // Through a URI the feed parses, into the other branch.
    c.host.clearTrace();
    unawaited(c.pushUri(Uri.parse('/feed/following/post/13')));
    await tester.pumpAndSettle();
    expect(find.text('Post 13 · Following'), findsOneWidget);
    expect(trace(), [pass('OnboardingGate', 'PostRoute')]);
    all.addAll(trace());

    expect(c.feed.branches.activeBranchIndex, 1);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': [
          'FeedListRoute[for-you]',
          'PostRoute[for-you,1]',
          'PostRoute[for-you,12]',
        ],
        'feed-following': ['PostRoute[following,13]'],
      }),
    );
    expect(all.where((line) => !line.startsWith('OnboardingGate(')), isEmpty);
  });

  testWidgets('E13 the path inspector shows one row per path, with its type, '
      'owner and chain, and marks the active entry', (tester) async {
    await pumpApp(tester);
    await tap(tester, find.text('Paths'));

    final rows = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('path-'),
    );
    expect(tester.widgetList(rows).map((row) => (row.key! as ValueKey).value), [
      for (final row in c.pathRows) 'path-${row.label}',
    ]);
    expect(
      {for (final row in c.pathRows) row.label},
      {for (final path in c.paths) path.debugLabel},
    );

    // Each row's chain is the real redirect scope of a destination landing
    // in its path, compared by identity. A row with an active destination
    // reads it from the scope; the others fall back to the owners the host
    // composed. Both are checked against redirectScopeOf.
    final representative = <String, RouteTarget>{
      'root': HubRoute(),
      'shop-tabs': HomeTab(),
      'feed-for-you': PostRoute(FeedBranch.forYou, 1),
      'feed-following': PostRoute(FeedBranch.following, 1),
      'auth': SignInRoute(),
      'security': SecuritySettingsRoute(),
    };
    expect(
      representative.keys,
      everyElement(isIn(c.pathRows.map((r) => r.label))),
    );
    for (final row in c.pathRows) {
      final destination = representative[row.label];
      if (destination == null) {
        // Only branch roots land in a branched path, and they are layouts.
        expect(row.path, isA<BranchedStackPath>(), reason: row.label);
        expect(row.chain(c), isEmpty, reason: row.label);
        continue;
      }
      expect(
        row.chain(c),
        sameModules(c.redirectScopeOf(destination)),
        reason: row.label,
      );
    }

    // The chain comes from the active destination's scope, not from the
    // owners a row was built with: a row whose owners are wrong still
    // reports the chain of its active entry.
    final shopTabs = c.pathRows.singleWhere((row) => row.label == 'shop-tabs');
    final misattributed = PathRow(
      shopTabs.path,
      owner: c.feed,
      enclosing: const [],
    );
    expect(
      misattributed.chain(c),
      sameModules(c.redirectScopeOf(shopTabs.path.activeRoute!)),
    );
    expect(misattributed.chain(c), sameModules([c, c.shop]));

    // A NavigationPath row: the root.
    expect(
      inRow('root', 'root · NavigationPath · owner AppCoordinator'),
      findsOneWidget,
    );
    expect(inRow('root', 'gated by AppCoordinator'), findsOneWidget);
    expect(inRow('root', 'stack [HubRoute]'), findsOneWidget);

    // An IndexedStackPath row.
    expect(
      inRow('shop-tabs', 'shop-tabs · IndexedStackPath · owner ShopModule'),
      findsOneWidget,
    );
    expect(
      inRow('shop-tabs', 'gated by AppCoordinator › ShopModule'),
      findsOneWidget,
    );
    expect(
      inRow(
        'shop-tabs',
        'stack [HomeTab] · CatalogTab · BillingTab · active 0',
      ),
      findsOneWidget,
    );

    // A BranchedStackPath row.
    expect(
      inRow(
        'feed-branches',
        'feed-branches · BranchedStackPath · owner NewsFeedModule',
      ),
      findsOneWidget,
    );
    expect(
      inRow(
        'feed-branches',
        'gated by nothing · branch roots are layouts, never offered',
      ),
      findsOneWidget,
    );
    expect(
      inRow(
        'feed-branches',
        'stack [ForYouBranch] · FollowingBranch · active 0',
      ),
      findsOneWidget,
    );

    // A branch child path row.
    expect(
      inRow(
        'feed-for-you',
        'feed-for-you · NavigationPath · owner NewsFeedModule',
      ),
      findsOneWidget,
    );
    expect(inRow('feed-for-you', 'gated by AppCoordinator'), findsOneWidget);
    expect(inRow('feed-for-you', 'stack (empty)'), findsOneWidget);

    // The module coordinator and the sub-module two levels deep.
    expect(
      inRow('auth', 'auth · NavigationPath · owner AuthRouteModuleCoordinator'),
      findsOneWidget,
    );
    expect(
      inRow('auth', 'gated by AppCoordinator › AuthRouteModuleCoordinator'),
      findsOneWidget,
    );
    expect(
      inRow('security', 'security · NavigationPath · owner SecurityModule'),
      findsOneWidget,
    );
    expect(
      inRow(
        'security',
        'gated by AppCoordinator › AuthRouteModuleCoordinator › '
            'SecurityModule',
      ),
      findsOneWidget,
    );

    // The active entry moves with navigation.
    await tapKey(tester, 'hub-shop-home');
    await tap(tester, navBar('Catalog'));

    expect(inRow('root', 'stack HubRoute › [ShopShell]'), findsOneWidget);
    expect(
      inRow(
        'shop-tabs',
        'stack HomeTab · [CatalogTab] · BillingTab · active 1',
      ),
      findsOneWidget,
    );

    await back(tester);
    await tapKey(tester, 'hub-feed');
    await tapKey(tester, 'post-for-you-1');

    expect(inRow('root', 'stack HubRoute › [FeedLayout]'), findsOneWidget);
    expect(
      inRow(
        'feed-for-you',
        'stack FeedListRoute[for-you] › [PostRoute[for-you,1]]',
      ),
      findsOneWidget,
    );
    expect(inRow('feed-for-you', 'gated by AppCoordinator'), findsOneWidget);

    await tap(tester, branchControl('Following'));

    expect(
      inRow(
        'feed-branches',
        'stack ForYouBranch · [FollowingBranch] · active 1',
      ),
      findsOneWidget,
    );
  });

  test('every module parses its own URIs through the root; an unknown URI is '
      'not found', () async {
    Future<RouteUnique?> parse(String uri) async =>
        await c.parseRouteFromUri(Uri.parse(uri));

    expect(await parse('/'), isA<HubRoute>());
    expect(await parse('/welcome'), isA<OnboardingRoute>());
    expect(await parse('/shop'), isA<HomeTab>());
    expect(await parse('/shop/catalog'), isA<CatalogTab>());
    expect(await parse('/shop/billing'), isA<BillingTab>());
    expect(await parse('/feed'), FeedListRoute(FeedBranch.forYou));
    expect(await parse('/feed/following'), FeedListRoute(FeedBranch.following));
    expect(
      await parse('/feed/for-you/post/4'),
      PostRoute(FeedBranch.forYou, 4),
    );
    expect(await parse('/account/sign-in'), isA<SignInRoute>());
    expect(await parse('/account/profile'), isA<ProfileRoute>());
    expect(await parse('/account/security'), isA<SecuritySettingsRoute>());
    expect(await parse('/nope'), NotFoundRoute(Uri.parse('/nope')));
  });

  // Names on screen. A release web build minifies type names, so every name
  // the example shows is a label, never read from a type.
  // coordinator_redirect_architecture_test.dart pins that no example file
  // reads runtimeType; these pin the labels and what the dock shows.

  test('every label is the name its type has in a debug build, so the trace '
      'reads the same in a debug and a release build', () {
    for (final route in everyRoute()) {
      expect(labelOf(route), '${route.runtimeType}');
      expect('$route', labelOf(route));
    }
    for (final module in <RouteModule<RouteUnique>>[
      c,
      c.shop,
      c.feed,
      c.auth,
      c.security,
    ]) {
      expect(moduleLabel(module), '${module.runtimeType}');
    }
    final rules = [
      for (final module in <RouteModuleRedirectRule<RouteUnique>>[
        c,
        c.shop,
        c.auth,
        c.security,
      ])
        ...module.redirectRules,
    ];
    expect(
      [for (final rule in rules) ruleLabel(rule)],
      [for (final rule in rules) '${rule.runtimeType}'],
    );
    expect(c.ruleNames, [
      'OnboardingGate',
      'SubscriptionGate',
      'RequireSession',
      'RequireTwoFactor',
    ]);
  });

  test('a type renamed as in a release web build still shows its label: one '
      'route of each route base, every rule and every module', () {
    for (final (route, label) in <(RouteTarget, String)>[
      (RenamedHub(), 'HubRoute'),
      (RenamedCatalog(), 'CatalogTab'),
      (RenamedPost(FeedBranch.forYou, 2), 'PostRoute'),
      (RenamedProfile(), 'ProfileRoute'),
      (RenamedSecuritySettings(), 'SecuritySettingsRoute'),
    ]) {
      expect('${route.runtimeType}', startsWith('Renamed'));
      expect('$route', label);
      expect(entryLabel(route), shownAs(route));
    }

    final onboarding = RenamedOnboardingGate(c.host);
    final subscription = RenamedSubscriptionGate(c.shopAccount, c.host.log);
    final session = RenamedRequireSession(c.authSession, c.host.log);
    final twoFactor = RenamedRequireTwoFactor(c.twoFactor, c.host.log);
    onboarding.redirectResult(c, RenamedPost(FeedBranch.forYou, 2));
    subscription.redirectResult(c, RenamedCatalog());
    session.redirectResult(c, RenamedProfile());
    twoFactor.redirectResult(c, RenamedSecuritySettings());

    expect(trace(), [
      pass('OnboardingGate', 'PostRoute'),
      pass('SubscriptionGate', 'CatalogTab'),
      'RequireSession(ProfileRoute) → SignInRoute (no session)',
      'RequireTwoFactor(SecuritySettingsRoute) → stop (2FA is off)',
    ]);
    for (final (rule, label) in <(RedirectRule, String)>[
      (onboarding, 'OnboardingGate'),
      (subscription, 'SubscriptionGate'),
      (session, 'RequireSession'),
      (twoFactor, 'RequireTwoFactor'),
    ]) {
      expect('${rule.runtimeType}', startsWith('Renamed'));
      expect(ruleLabel(rule), label);
    }

    for (final (module, label) in <(RouteModule<RouteUnique>, String)>[
      (RenamedAppCoordinator(), 'AppCoordinator'),
      (
        RenamedShopModule(c, account: c.shopAccount, trace: c.host.log),
        'ShopModule',
      ),
      (RenamedFeedModule(c), 'NewsFeedModule'),
      (
        RenamedAuthCoordinator(
          c,
          session: c.authSession,
          trace: c.host.log,
          subModules: (_) => const [],
        ),
        'AuthRouteModuleCoordinator',
      ),
      (
        RenamedSecurityModule(c, status: c.twoFactor, trace: c.host.log),
        'SecurityModule',
      ),
    ]) {
      expect('${module.runtimeType}', startsWith('Renamed'));
      expect(moduleLabel(module), label);
    }
  });

  // The dock read back from the screen after a walk. The second run renames
  // the root, its rule and every route it pushes, the way dart2js renames
  // types: the names on screen must not change.
  for (final renamed in [false, true]) {
    testWidgets('the rule trace and the path inspector show every route, rule '
        'and module by its label: no minified name, no type name'
        '${renamed ? ', with types renamed as in a release web build' : ''}', (
      tester,
    ) async {
      if (renamed) c = RenamedAppCoordinator();
      await pumpApp(tester);
      Future<void> open(RouteUnique route) async {
        unawaited(c.push(route));
        await tester.pumpAndSettle();
      }

      if (renamed) {
        unawaited(c.replace(RenamedHub()));
        await tester.pumpAndSettle();
      }
      // A Stop, a redirect and a Stop two levels deep: unsubscribed, signed
      // out, 2FA off.
      await tapKey(tester, 'hub-billing');
      await tapKey(tester, 'hub-profile');
      await tapKey(tester, 'auth-sign-in');
      await tapKey(tester, 'auth-link-security');
      await back(tester);
      // Then every shell open at once, and something in every stack.
      await tapKey(tester, 'flag-subscribed');
      await tapKey(tester, 'flag-two-factor');
      await tapKey(tester, 'hub-shop-home');
      if (renamed) {
        await open(RenamedProfile());
        await open(RenamedSecuritySettings());
        await open(RenamedPost(FeedBranch.forYou, 5));
      } else {
        await tapKey(tester, 'shop-link-profile');
        await tapKey(tester, 'auth-link-security');
        await open(PostRoute(FeedBranch.forYou, 5));
      }
      await tap(tester, branchControl('Following'));
      await tapKey(tester, 'feed-open-following');
      await tapKey(tester, 'post-following-1');
      expect(c.paths.where((path) => path.stack.isEmpty), isEmpty);

      await tap(tester, find.text('Rule trace'));
      await tap(tester, find.text('Paths'));
      List<String> textsIn(Finder area) => [
        for (final text in tester.widgetList<Text>(
          find.descendant(of: area, matching: find.byType(Text)),
        ))
          text.data!,
      ];
      final traceTexts = textsIn(find.byType(TracePanel));
      final inspectorTexts = textsIn(find.byType(PathInspector));
      expect(inspectorTexts, hasLength(3 * c.pathRows.length));
      for (final text in [...traceTexts, ...inspectorTexts]) {
        expect(text, isNot(contains('minified:')));
        expect(text, isNot(contains('Renamed')));
      }

      // The trace: every decision names a rule and a route by its label, and
      // "Which rules saw what" groups by rule label, one group per rule.
      final routeLabels = {for (final route in everyRoute()) labelOf(route)};
      const ruleLabels = [
        OnboardingGate.label,
        SubscriptionGate.label,
        RequireSession.label,
        RequireTwoFactor.label,
      ];
      final decision = RegExp(r'^\d+\. (\w+)\((\w+)\) → (.+)$');
      final sawLine = RegExp(r'^(\w+): (.+)$');
      const headings = {
        'Which rules saw what',
        'Every decision, oldest first',
        'Clear',
      };
      final groups = <String>[];
      final verdicts = <String>[];
      for (final text in traceTexts) {
        if (headings.contains(text)) continue;
        if (decision.firstMatch(text) case final match?) {
          expect(ruleLabels, contains(match[1]), reason: text);
          expect(routeLabels, contains(match[2]), reason: text);
          verdicts.add(match[3]!);
        } else if (sawLine.firstMatch(text) case final match?) {
          groups.add(match[1]!);
          if (match[2] != 'nothing') {
            expect(
              routeLabels,
              containsAll(match[2]!.split(', ')),
              reason: text,
            );
          }
        } else {
          fail('The trace panel shows a line this test cannot read: $text');
        }
      }
      expect(groups, ruleLabels);
      expect(
        verdicts,
        containsAll([
          'continue',
          'stop (no subscription)',
          'SignInRoute (no session)',
          'stop (2FA is off)',
        ]),
      );

      // The inspector: each owner and gating module by the name the host
      // gave it, and each entry by its label, then its props.
      final names = <(Object, String)>[
        (c, 'AppCoordinator'),
        (c.shop, 'ShopModule'),
        (c.feed, 'NewsFeedModule'),
        (c.auth, 'AuthRouteModuleCoordinator'),
        (c.security, 'SecurityModule'),
      ];
      String nameOf(Object module) =>
          names.singleWhere((entry) => identical(entry.$1, module)).$2;
      List<String> entriesIn(String stack) {
        final body = stack
            .substring('stack '.length)
            .replaceFirst(RegExp(r' · active \d+$'), '');
        if (body == '(empty)') return const [];
        return [
          for (final entry in body.split(RegExp(' › | · ')))
            entry.startsWith('[')
                ? entry.substring(1, entry.length - 1)
                : entry,
        ];
      }

      for (final row in c.pathRows) {
        final [title, chain, stack] = textsIn(
          find.byKey(Key('path-${row.label}')),
        );
        expect(
          title,
          endsWith(' · owner ${nameOf(row.owner)}'),
          reason: row.label,
        );
        final gating = row.chain(c);
        if (gating.isNotEmpty) {
          expect(
            chain,
            'gated by ${gating.map(nameOf).join(' › ')}',
            reason: row.label,
          );
        }
        expect(entriesIn(stack), [
          for (final route in row.path.stack) shownAs(route),
        ], reason: row.label);
      }
    });
  }

  // Back in the feed, as a user expects it: a back pops the page on screen,
  // the active branch's top post first, then the feed shell itself. It never
  // pops a branch's first page, and no branch shows its empty page on the way,
  // not even for one frame of a transition.

  final emptyBranch = find.textContaining(RegExp(r'^Nothing in .+ yet\.$'));

  /// Pumps every frame until the app settles, checking on each one that no
  /// branch shows its empty page.
  Future<void> settleWithoutEmptyBranch(WidgetTester tester) async {
    var frame = 0;
    do {
      await tester.pump(const Duration(milliseconds: 16));
      frame++;
      expect(emptyBranch, findsNothing, reason: 'frame $frame');
    } while (tester.binding.hasScheduledFrame && frame < 300);
    expect(tester.binding.hasScheduledFrame, isFalse);
  }

  /// Taps the feed's back arrow, then watches every frame.
  Future<void> feedBack(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Back'));
    await settleWithoutEmptyBranch(tester);
  }

  testWidgets('back in the feed: on the list, back leaves the feed, the hub '
      'shows, and the branch never shows empty on the way out', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-feed');
    expect(find.text('For you feed'), findsOneWidget);
    c.host.clearTrace();

    await feedBack(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    // Leaving the shell resets its branches, so the next visit starts fresh.
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );
    expect(c.currentUri, Uri.parse('/'));
    expect(trace(), isEmpty);
  });

  testWidgets('back in the feed: on a post, back returns to the list one page '
      'at a time, then leaves the feed', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-feed');
    await tapKey(tester, 'post-for-you-1');
    await tapKey(tester, 'post-next');
    expect(find.text('Post 2 · For you'), findsOneWidget);
    c.host.clearTrace();

    await feedBack(tester);

    expect(find.text('Post 1 · For you'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]', 'PostRoute[for-you,1]'],
      }),
    );
    expect(c.currentUri, Uri.parse('/feed/for-you/post/1'));

    await feedBack(tester);

    expect(find.text('For you feed'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
      }),
    );
    expect(c.currentUri, Uri.parse('/feed/for-you'));

    await feedBack(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );
    // A back is a pop: it offers nothing to any rule.
    expect(trace(), isEmpty);
  });

  testWidgets('back in the feed: back pops the active branch only, and on its '
      'list leaves the feed, whatever the other branch holds', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-feed');
    await tapKey(tester, 'post-for-you-1');
    await tap(tester, branchControl('Following'));
    await tapKey(tester, 'feed-open-following');
    await tapKey(tester, 'post-following-1');
    expect(find.text('Post 1 · Following'), findsOneWidget);

    await feedBack(tester);

    expect(find.text('Following feed'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]', 'PostRoute[for-you,1]'],
        'feed-following': ['FeedListRoute[following]'],
      }),
    );

    await feedBack(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );
  });

  testWidgets('back in the feed: the system back goes the same way as the back '
      'arrow, post, then list, then out of the feed', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'hub-feed');
    await tapKey(tester, 'post-for-you-1');

    await tester.binding.handlePopRoute();
    await settleWithoutEmptyBranch(tester);

    expect(find.text('For you feed'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
      }),
    );

    await tester.binding.handlePopRoute();
    await settleWithoutEmptyBranch(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );
  });

  testWidgets('back in the feed: the back arrow shows only when a back has '
      'somewhere to go', (tester) async {
    await pumpApp(tester);
    // The feed as the only page of the root stack, as after a cold deep link.
    unawaited(c.replace(FeedListRoute(FeedBranch.forYou)));
    await tester.pumpAndSettle();
    expect(
      stacks(),
      stacksWith({
        'root': ['FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
      }),
    );
    expect(find.byTooltip('Back'), findsNothing);

    await tapKey(tester, 'post-for-you-1');

    expect(find.byTooltip('Back'), findsOneWidget);

    await feedBack(tester);

    expect(find.text('For you feed'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(
      stacks(),
      stacksWith({
        'root': ['FeedLayout'],
        'feed-for-you': ['FeedListRoute[for-you]'],
      }),
    );
  });

  // ===========================================================================
  // The browser walk of 2026-09-19: what a user sees around a Stop, the
  // sign-in continuation, and a cold start on a URL a rule stops.
  // ===========================================================================

  /// The notice the host shows when a rule stops a navigation.
  Finder stopNotice(String decision) => find.descendant(
    of: find.byKey(const Key('stop-notice')),
    matching: find.textContaining(decision),
  );

  /// No shell sits on the root stack with nothing in it: that is a blank
  /// page with a back arrow.
  void expectNoEmptyShell() {
    for (final route in c.root.stack) {
      if (route is RouteLayout) {
        expect(
          route.resolvePath(c).stack,
          isNotEmpty,
          reason: '${labelOf(route)} is on the root stack with an empty stack',
        );
      }
    }
  }

  testWidgets('walk: a rule that stops a navigation says so on screen, from '
      'the hub and on a tab tap', (tester) async {
    c.authSession.signedIn.value = true;
    await pumpApp(tester);

    await tapKey(tester, 'hub-security');

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(
      stopNotice('RequireTwoFactor(SecuritySettingsRoute) → stop (2FA is off)'),
      findsOneWidget,
    );

    await tapKey(tester, 'hub-billing');

    expect(
      stopNotice('SubscriptionGate(BillingTab) → stop (no subscription)'),
      findsOneWidget,
    );

    await tapKey(tester, 'hub-shop-home');
    await tap(tester, navBar('Billing'));

    expect(find.text('Shop home'), findsOneWidget);
    expect(
      stopNotice('SubscriptionGate(BillingTab) → stop (no subscription)'),
      findsOneWidget,
    );
  });

  testWidgets('walk: signing in leaves the sign-in page even when a deeper '
      'rule stops where the user was going', (tester) async {
    await pumpApp(tester);

    await tapKey(tester, 'hub-security');
    expect(
      find.text(
        'RequireSession sent you here: /account/security needs a session.',
      ),
      findsOneWidget,
    );

    await tapKey(tester, 'auth-sign-in');

    // Signed in, but Security needs 2FA: the user is on the profile, and the
    // stop is on screen.
    expect(find.text('Your profile'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    expect(
      stopNotice('RequireTwoFactor(SecuritySettingsRoute) → stop (2FA is off)'),
      findsOneWidget,
    );
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['ProfileRoute'],
      }),
    );
  });

  testWidgets('walk: signing in with 2FA on opens Security over the profile, '
      'and no back ever shows an empty shell', (tester) async {
    c.twoFactor.enabled.value = true;
    await pumpApp(tester);

    await tapKey(tester, 'hub-security');
    await tapKey(tester, 'auth-sign-in');

    expect(find.text('Security settings'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout', 'SecurityLayout'],
        'auth': ['ProfileRoute'],
        'security': ['SecuritySettingsRoute'],
      }),
    );
    expectNoEmptyShell();

    await back(tester);

    expect(find.text('Your profile'), findsOneWidget);
    expectNoEmptyShell();

    await back(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );
  });

  testWidgets('walk: a sign-in page opened directly never shows an attempt '
      'the user walked away from', (tester) async {
    await pumpApp(tester);

    await tapKey(tester, 'hub-security');
    await back(tester);
    await tapKey(tester, 'hub-sign-in');

    expect(find.text('You opened this page yourself.'), findsOneWidget);
    expect(find.textContaining('sent you here'), findsNothing);
  });

  testWidgets('walk: a cold start on a URL a rule stops opens the hub, not a '
      'blank app', (tester) async {
    c = AppCoordinator(initialRoutePath: Uri.parse('/shop/billing'));
    await pumpApp(tester);

    expect(find.text('Scoped redirect rules'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute'],
      }),
    );
    expect(
      stopNotice('SubscriptionGate(BillingTab) → stop (no subscription)'),
      findsOneWidget,
    );
  });

  testWidgets('walk: entering and leaving Security three times leaves every '
      'stack as it was', (tester) async {
    c.authSession.signedIn.value = true;
    c.twoFactor.enabled.value = true;
    await pumpApp(tester);

    for (var round = 1; round <= 3; round++) {
      await tapKey(tester, 'hub-security');
      expect(find.text('Security settings'), findsOneWidget, reason: '$round');
      await back(tester);
      expect(
        stacks(),
        stacksWith({
          'root': ['HubRoute'],
        }),
        reason: '$round',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // The address-bar walk of 2026-09-19: every navigation typed as a URL into
  // a running app.
  // ---------------------------------------------------------------------------

  /// Types [location] into the address bar of the running app.
  Future<void> typeUrl(WidgetTester tester, String location) async {
    unawaited(c.routerDelegate.setNewRoutePath(Uri.parse(location)));
    await tester.pumpAndSettle();
  }

  testWidgets('walk: with a sign-in page open, the latest gated URL typed is '
      'where signing in continues', (tester) async {
    await pumpApp(tester);

    await typeUrl(tester, '/account/security');
    expect(
      find.text(
        'RequireSession sent you here: /account/security needs a session.',
      ),
      findsOneWidget,
    );

    // The same sign-in page stays; it now carries the new attempt.
    await typeUrl(tester, '/account/profile');
    expect(
      find.text(
        'RequireSession sent you here: /account/profile needs a session.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('/account/security'), findsNothing);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['SignInRoute'],
      }),
    );

    await tapKey(tester, 'auth-sign-in');

    expect(find.text('Your profile'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['ProfileRoute'],
      }),
    );
  });

  testWidgets('walk: typing the sign-in URL over an open sign-in page drops '
      'its attempt', (tester) async {
    await pumpApp(tester);

    await typeUrl(tester, '/account/security');
    await typeUrl(tester, '/account/sign-in');

    expect(find.text('You opened this page yourself.'), findsOneWidget);
  });

  testWidgets('walk: a signed-in user who asks for the sign-in page gets their '
      'profile, from the address bar and from the hub', (tester) async {
    c.authSession.signedIn.value = true;
    await pumpApp(tester);

    await typeUrl(tester, '/account/sign-in');

    expect(find.text('Your profile'), findsOneWidget);
    expect(
      trace().last,
      anyOf(
        pass('RequireSession', 'ProfileRoute'),
        contains('RequireSession(ProfileRoute)'),
      ),
    );
    expect(
      saw('RequireSession'),
      containsAllInOrder(['SignInRoute', 'ProfileRoute']),
    );
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['ProfileRoute'],
      }),
    );

    await back(tester);
    await tapKey(tester, 'hub-sign-in');

    expect(find.text('Your profile'), findsOneWidget);
    expect(
      stacks(),
      stacksWith({
        'root': ['HubRoute', 'AuthLayout'],
        'auth': ['ProfileRoute'],
      }),
    );
  });
}
