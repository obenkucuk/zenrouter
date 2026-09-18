// F3-F5 of the scoped-redirect plan: router entry points, restoration and the
// NavigationStack defaultRoute debug check.
//
// The app is a compact scoped tree: a root with an app-wide rule, an auth
// module coordinator that gates its stack with RequireSession, and a plain
// shop module with its own rule. Tests drive MaterialApp.router (initial
// route, routerDelegate.setNewRoutePath, tester.restartAndRestore) or a real
// NavigationStack, and assert on the rule log, the full stacks, onDiscard
// counts and what is on screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ===========================================================================
// Routes
// ===========================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {
  /// The name the rules log.
  String get id;

  int discards = 0;

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      Scaffold(body: Text('$id page'));

  @override
  String toString() => '$runtimeType';
}

class HomeRoute extends AppRoute {
  @override
  String get id => 'home';

  @override
  Uri toUri() => Uri.parse('/');
}

/// Parsed by the auth module but layout-less: it lands on the root stack.
class HelpRoute extends AppRoute {
  @override
  String get id => 'help';

  @override
  Uri toUri() => Uri.parse('/account/help');
}

/// Layout-less; used as a NavigationStack defaultRoute.
class StrayRoute extends AppRoute {
  @override
  String get id => 'stray';

  @override
  Uri toUri() => Uri.parse('/stray');
}

/// A page behind the auth shell: it lands in the auth stack.
abstract class AuthPage extends AppRoute {
  @override
  Type get layout => AuthLayout;
}

class SignInRoute extends AuthPage {
  @override
  String get id => 'sign-in';

  @override
  Uri toUri() => Uri.parse('/account/sign-in');
}

class ProfileRoute extends AuthPage {
  @override
  String get id => 'profile';

  @override
  Uri toUri() => Uri.parse('/account/profile');
}

class DevicesRoute extends AuthPage {
  @override
  String get id => 'devices';

  @override
  Uri toUri() => Uri.parse('/account/devices');
}

class CartRoute extends AppRoute {
  @override
  String get id => 'cart';

  @override
  Type get layout => ShopLayout;

  @override
  Uri toUri() => Uri.parse('/shop/cart');
}

class AuthLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  String get id => 'auth-layout';

  @override
  StackPath<RouteUnique> resolvePath(covariant RouterApp coordinator) =>
      coordinator.auth.authStack;

  @override
  Widget build(covariant CoordinatorCore coordinator, BuildContext context) =>
      Column(
        children: [
          const Text('auth shell'),
          Expanded(child: buildPath(coordinator as Coordinator)),
        ],
      );
}

class ShopLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  String get id => 'shop-layout';

  @override
  StackPath<RouteUnique> resolvePath(covariant RouterApp coordinator) =>
      coordinator.shop.shopStack;
}

// ===========================================================================
// Rules
// ===========================================================================

class Session {
  bool signedIn = false;
}

/// Logs `'$name(${route.id})'`, records the coordinator, and continues.
class RecordingRule extends RedirectRule<AppRoute> {
  RecordingRule(this.name, this.log);

  final String name;
  final List<String> log;
  final coordinators = <CoordinatorCore>[];

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    log.add('$name(${route.id})');
    coordinators.add(coordinator);
    return const RedirectResult.continueRedirect();
  }
}

/// Redirects every destination it gates to a fresh SignIn while signed out.
/// It continues for SignIn itself, which lands in the same scope.
class RequireSession extends RedirectRule<AppRoute> {
  RequireSession(this.session, this.log);

  final Session session;
  final List<String> log;

  /// Every route offered, in order.
  final offered = <AppRoute>[];

  /// Every SignIn this rule redirected to, in order.
  final signIns = <SignInRoute>[];

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    log.add('session(${route.id})');
    offered.add(route);
    if (route is SignInRoute || session.signedIn) {
      return const RedirectResult.continueRedirect();
    }
    final signIn = SignInRoute();
    signIns.add(signIn);
    return RedirectResult.redirectTo(signIn);
  }
}

// ===========================================================================
// Modules and apps. The plain classes are the opted-out twins; the Scoped
// subclasses only add the mixin and their rules.
// ===========================================================================

class AuthModule extends Coordinator<AppRoute> {
  AuthModule(this.coordinator, {required this.session, required this.log});

  @override
  final CoordinatorModular<AppRoute> coordinator;

  final Session session;
  final List<String> log;

  /// Every route this module parsed, in order.
  final parsed = <AppRoute>[];

  late final NavigationPath<AppRoute> authStack =
      NavigationPath<AppRoute>.createWith(label: 'auth', coordinator: this)
        ..bindLayout(AuthLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, authStack];

  AppRoute? parseSync(Uri uri) {
    final AppRoute? route = switch (uri.pathSegments) {
      ['account', 'sign-in'] => SignInRoute(),
      ['account', 'profile'] => ProfileRoute(),
      ['account', 'devices'] => DevicesRoute(),
      ['account', 'help'] => HelpRoute(),
      _ => null,
    };
    if (route != null) parsed.add(route);
    return route;
  }

  @override
  AppRoute? parseRouteFromUri(Uri uri) => parseSync(uri);
}

class ScopedAuthModule extends AuthModule
    with RouteModuleRedirectRule<AppRoute> {
  ScopedAuthModule(
    super.coordinator, {
    required super.session,
    required super.log,
  });

  late final requireSession = RequireSession(session, log);

  @override
  late final List<RedirectRule> redirectRules = [requireSession];
}

class ShopModule extends RouteModule<AppRoute> {
  ShopModule(super.coordinator, {required this.log});

  final List<String> log;

  late final NavigationPath<AppRoute> shopStack =
      NavigationPath<AppRoute>.createWith(
        label: 'shop',
        coordinator: coordinator,
      )..bindLayout(ShopLayout.new);

  @override
  List<StackPath> get paths => [shopStack];

  AppRoute? parseSync(Uri uri) => switch (uri.pathSegments) {
    ['shop', 'cart'] => CartRoute(),
    _ => null,
  };

  @override
  AppRoute? parseRouteFromUri(Uri uri) => parseSync(uri);
}

class ScopedShopModule extends ShopModule
    with RouteModuleRedirectRule<AppRoute> {
  ScopedShopModule(super.coordinator, {required super.log});

  late final shopRule = RecordingRule('shop', log);

  @override
  late final List<RedirectRule> redirectRules = [shopRule];
}

class RouterApp extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute> {
  RouterApp({super.initialRoutePath});

  final session = Session();
  final log = <String>[];

  late final AuthModule auth = createAuth();
  late final ShopModule shop = createShop();

  AuthModule createAuth() => AuthModule(this, session: session, log: log);

  ShopModule createShop() => ShopModule(this, log: log);

  @override
  Iterable<RouteModule<AppRoute>> defineModules() => [auth, shop];

  @override
  AppRoute notFoundRoute(Uri uri) => HomeRoute();

  /// Restoration parses synchronously; CoordinatorModular parses async.
  @override
  RouteUriParserSync<AppRoute> get parseRouteFromUriSync =>
      (uri) => auth.parseSync(uri) ?? shop.parseSync(uri) ?? notFoundRoute(uri);
}

class ScopedRouterApp extends RouterApp with RouteModuleRedirectRule<AppRoute> {
  ScopedRouterApp({super.initialRoutePath});

  late final appRule = RecordingRule('app', log);

  @override
  late final List<RedirectRule> redirectRules = [appRule];

  @override
  AuthModule createAuth() => ScopedAuthModule(this, session: session, log: log);

  @override
  ShopModule createShop() => ScopedShopModule(this, log: log);

  ScopedAuthModule get scopedAuth => auth as ScopedAuthModule;
}

// ===========================================================================
// Helpers
// ===========================================================================

/// Every path of [app], by label, as route ids.
Map<String, List<String>> stacksOf(RouterApp app) => {
  for (final path in app.paths)
    path.debugLabel!: [for (final route in path.stack) (route as AppRoute).id],
};

Future<void> pumpApp(
  WidgetTester tester,
  RouterApp app, {
  String? restorationScopeId,
}) async {
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: app,
      restorationScopeId: restorationScopeId,
    ),
  );
  await tester.pumpAndSettle();
}

const signedOutProfilePass = [
  'app(profile)',
  'session(profile)',
  'app(sign-in)',
  'session(sign-in)',
];

// ===========================================================================
// Tests
// ===========================================================================

void main() {
  group('F3 router entry points', () {
    testWidgets(
      'F3 the initial route to a gated URL lands on SignIn in the auth shell, '
      'and the URL reflects SignIn',
      (tester) async {
        final app = ScopedRouterApp(
          initialRoutePath: Uri.parse('/account/profile'),
        );
        await pumpApp(tester, app);

        expect(find.text('sign-in page'), findsOneWidget);
        expect(find.text('auth shell'), findsOneWidget);
        expect(find.text('profile page'), findsNothing);
        expect(app.log, signedOutProfilePass);
        expect(stacksOf(app), {
          'root': ['auth-layout'],
          'auth': ['sign-in'],
          'shop': <String>[],
        });
        expect(app.auth.parsed, [isA<ProfileRoute>()]);
        expect(app.auth.parsed.single.discards, 1);
        expect(
          app.auth.authStack.stack.single,
          same(app.scopedAuth.requireSession.signIns.single),
        );
        expect(app.currentUri, Uri.parse('/account/sign-in'));
        expect(
          app.routeInformationProvider.value.uri,
          Uri.parse('/account/sign-in'),
        );
        expect(app.appRule.coordinators, everyElement(same(app)));
      },
    );

    testWidgets(
      'F3 setNewRoutePath to the profile URL while signed out lands on '
      'SignIn; a shop deep link gets the shop chain only',
      (tester) async {
        final app = ScopedRouterApp();
        await pumpApp(tester, app);
        expect(find.text('home page'), findsOneWidget);
        expect(app.log, ['app(home)']);

        app.log.clear();
        await app.routerDelegate.setNewRoutePath(Uri.parse('/account/profile'));
        await tester.pumpAndSettle();

        expect(find.text('sign-in page'), findsOneWidget);
        expect(app.log, signedOutProfilePass);
        expect(stacksOf(app), {
          'root': ['home', 'auth-layout'],
          'auth': ['sign-in'],
          'shop': <String>[],
        });
        expect(app.auth.parsed.single.discards, 1);
        expect(app.currentUri, Uri.parse('/account/sign-in'));

        app.log.clear();
        await app.routerDelegate.setNewRoutePath(Uri.parse('/shop/cart'));
        await tester.pumpAndSettle();

        expect(find.text('cart page'), findsOneWidget);
        expect(app.log, ['app(cart)', 'shop(cart)']);
        expect(stacksOf(app), {
          'root': ['home', 'auth-layout', 'shop-layout'],
          'auth': ['sign-in'],
          'shop': ['cart'],
        });
      },
    );

    testWidgets(
      'F3 after sign-out, browser back to the profile URL lands on SignIn; '
      'the live Profile below it is not discarded',
      (tester) async {
        final app = ScopedRouterApp();
        await pumpApp(tester, app);

        app.session.signedIn = true;
        final profile = ProfileRoute();
        unawaited(app.push(profile));
        await tester.pumpAndSettle();
        expect(find.text('profile page'), findsOneWidget);
        unawaited(app.push(HelpRoute()));
        await tester.pumpAndSettle();
        expect(stacksOf(app), {
          'root': ['home', 'auth-layout', 'help'],
          'auth': ['profile'],
          'shop': <String>[],
        });

        // Sign out without resetting any stack.
        app.session.signedIn = false;
        app.log.clear();
        app.auth.parsed.clear();

        // Browser back: the router hands the profile URL to navigate, which
        // resolves before it looks for an existing entry.
        await app.routerDelegate.setNewRoutePath(Uri.parse('/account/profile'));
        await tester.pumpAndSettle();

        expect(find.text('sign-in page'), findsOneWidget);
        expect(app.log, signedOutProfilePass);
        // The auth shell is not in the active chain (help is on top), so a
        // fresh shell is moved to the top and the old one is replaced.
        expect(stacksOf(app), {
          'root': ['home', 'help', 'auth-layout'],
          'auth': ['profile', 'sign-in'],
          'shop': <String>[],
        });
        expect(app.auth.authStack.stack.first, same(profile));
        expect(profile.discards, 0);
        expect(app.auth.parsed.single.discards, 1);
        expect(app.currentUri, Uri.parse('/account/sign-in'));
      },
    );

    testWidgets(
      'F3 a root push and a module-instance push of a layout-less route '
      'render the same page with the same chain',
      (tester) async {
        final app = ScopedRouterApp();
        await pumpApp(tester, app);

        app.log.clear();
        unawaited(app.push(HelpRoute()));
        await tester.pumpAndSettle();
        expect(find.text('help page'), findsOneWidget);
        final logViaRoot = [...app.log];
        final stacksViaRoot = stacksOf(app);
        final uriViaRoot = app.currentUri;

        await app.root.pop();
        await tester.pumpAndSettle();
        expect(find.text('home page'), findsOneWidget);

        app.log.clear();
        unawaited(app.auth.push(HelpRoute()));
        await tester.pumpAndSettle();

        expect(find.text('help page'), findsOneWidget);
        expect(logViaRoot, ['app(help)']);
        expect(app.log, logViaRoot);
        expect(stacksViaRoot, {
          'root': ['home', 'help'],
          'auth': <String>[],
          'shop': <String>[],
        });
        expect(stacksOf(app), stacksViaRoot);
        expect(app.currentUri, uriViaRoot);
        expect(app.appRule.coordinators, everyElement(same(app)));
      },
    );
  });

  group('F4 restoration', () {
    testWidgets(
      'F4 the restored active Profile is re-navigated through [root, auth] '
      'and redirected to SignIn; restored entries are not re-gated and not '
      'discarded',
      (tester) async {
        final app = ScopedRouterApp();
        await pumpApp(tester, app, restorationScopeId: 'app');

        app.session.signedIn = true;
        unawaited(app.push(DevicesRoute()));
        await tester.pumpAndSettle();
        unawaited(app.push(ProfileRoute()));
        await tester.pumpAndSettle();
        expect(find.text('profile page'), findsOneWidget);
        expect(stacksOf(app), {
          'root': ['home', 'auth-layout'],
          'auth': ['devices', 'profile'],
          'shop': <String>[],
        });

        // Sign out without resetting any stack, then restart the process:
        // the in-memory stacks are cleared, as a new process would have them.
        app.session.signedIn = false;
        app.log.clear();
        app.auth.parsed.clear();
        app.scopedAuth.requireSession.offered.clear();
        app.scopedAuth.requireSession.signIns.clear();
        final restart = tester.restartAndRestore();
        for (final path in app.paths) {
          path.reset();
        }
        await restart;
        await tester.pumpAndSettle();

        expect(find.text('sign-in page'), findsOneWidget);
        expect(app.log, signedOutProfilePass);
        expect(stacksOf(app), {
          'root': ['home', 'auth-layout'],
          'auth': ['devices', 'profile', 'sign-in'],
          'shop': <String>[],
        });

        final [devices, profile, signIn] = app.auth.authStack.stack
            .cast<AppRoute>();
        // Restoration rebinds the saved stacks without resolving them: the
        // restored non-active Devices entry was never offered to a rule, and
        // neither restored entry is discarded.
        expect(app.log.where((entry) => entry.contains('devices')), isEmpty);
        expect(devices.discards, 0);
        expect(profile.discards, 0);
        expect(app.auth.parsed, containsAll([same(devices), same(profile)]));

        // Only the saved active route is re-navigated, as its own fresh
        // instance: that instance is gated and discarded when redirected.
        final navigated = app.scopedAuth.requireSession.offered.first;
        expect(navigated, isA<ProfileRoute>());
        expect(navigated, isNot(same(profile)));
        expect(navigated.discards, 1);
        expect(signIn, same(app.scopedAuth.requireSession.signIns.single));
        expect(app.currentUri, Uri.parse('/account/sign-in'));

        // What that costs a user: rules guard entry, and a pop enters
        // nothing. One back from the sign-in page shows the restored Profile
        // to a signed-out user, and no rule runs. An app that must not allow
        // it clears its gated stacks when the session ends.
        app.log.clear();
        expect(await app.tryPop(), isTrue);
        await tester.pumpAndSettle();

        expect(find.text('profile page'), findsOneWidget);
        expect(app.log, isEmpty);
        expect(app.currentUri, Uri.parse('/account/profile'));
      },
    );
  });

  group('F5 D1 through NavigationStack', () {
    Widget stackWithDefault(RouterApp app, AppRoute defaultRoute) =>
        MaterialApp(
          home: NavigationStack<AppRoute>(
            path: app.auth.authStack,
            coordinator: app,
            defaultRoute: defaultRoute,
            resolver: (route) =>
                StackTransition.material(Text('${route.id} page')),
          ),
        );

    testWidgets(
      'F5 a layout-less defaultRoute in the auth stack asserts in an opted-in '
      'app',
      (tester) async {
        final app = ScopedRouterApp();
        final stray = StrayRoute();
        final errors = <Object>[];

        await runZonedGuarded(() async {
          await tester.pumpWidget(stackWithDefault(app, stray));
          await tester.pump();
        }, (error, stack) => errors.add(error));

        expect(errors, [
          isA<AssertionError>().having(
            (error) => '${error.message}',
            'message',
            allOf(
              contains('StrayRoute'),
              contains("'auth'"),
              contains('ScopedAuthModule'),
              contains('navigate through the coordinator'),
            ),
          ),
        ]);
        // Only the root chain ran for the layout-less route: the auth rule
        // that gates the stack was skipped, which is what D1 reports.
        expect(app.log, ['app(stray)']);
        expect(app.auth.authStack.stack, isEmpty);
        expect(stray.discards, 0);
        expect(find.text('stray page'), findsNothing);
      },
    );

    testWidgets(
      'F5 the same defaultRoute in the same app without the mixin commits '
      'without asserting',
      (tester) async {
        final app = RouterApp();
        final stray = StrayRoute();
        final errors = <Object>[];

        await runZonedGuarded(() async {
          await tester.pumpWidget(stackWithDefault(app, stray));
          await tester.pump();
        }, (error, stack) => errors.add(error));

        expect(errors, isEmpty);
        expect(app.log, isEmpty);
        expect(app.auth.authStack.stack, [same(stray)]);
        expect(stray.discards, 0);
        expect(find.text('stray page'), findsOneWidget);
      },
    );
  });
}
