// =============================================================================
// AuthRouteModuleCoordinator: a coordinator used as a module (the user's case)
// =============================================================================
// A Coordinator with CoordinatorModular and RouteModuleRedirectRule, used as a
// module of the host. RequireSession gates what lands in `authStack`, and in
// the stacks of the sub-modules registered under this coordinator. It never
// gates a route that lands on the root stack or in a sibling's stack.
//
// Sub-modules are not imported here: the host passes them in through
// `subModules`. The host registers SecurityModule that way, which makes it
// the two-levels-deep case, root > auth > security.
//
// The coordinator owns its routing as a RouteManifest, like every module. It
// cannot mix in RouteModuleBinding: that mixin and CoordinatorModular both
// implement parseRouteFromUri. A coordinator that groups sub-modules gives its
// own graph to the composed one through localRouteManifestFragment instead,
// resolves its own URLs through its bindings, then falls back to super, which
// asks its sub-modules.
//
// This file imports only flutter and zenrouter. Its state (AuthSession) and
// the trace come from the host, through the constructor. A link to another
// feature goes by URI.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';

/// The auth module's own state, created and injected by the host.
class AuthSession {
  final signedIn = ValueNotifier<bool>(false);

  void reset() => signedIn.value = false;
}

/// The IDs of this coordinator's manifest: its shell, then its routes.
enum AuthRouteId { shell, signIn, profile }

class AuthRouteModuleCoordinator extends Coordinator<RouteUnique>
    with CoordinatorModular<RouteUnique>, RouteModuleRedirectRule<RouteUnique> {
  AuthRouteModuleCoordinator(
    this.coordinator, {
    required this.session,
    required this.trace,
    required this.subModules,
  });

  @override
  final CoordinatorModular<RouteUnique> coordinator;

  final AuthSession session;
  final void Function(String line) trace;

  /// Builds the sub-modules. The host supplies them: this file never
  /// imports a sub-module.
  final Iterable<RouteModule<RouteUnique>> Function(
    CoordinatorModular<RouteUnique> auth,
  )
  subModules;

  /// Read on every resolution pass, so it is built once.
  @override
  late final List<RedirectRule> redirectRules = [
    RequireSession(session, trace),
  ];

  late final NavigationPath<RouteUnique> authStack =
      NavigationPath<RouteUnique>.createWith(label: 'auth', coordinator: this)
        ..bindLayout(AuthLayout.new);

  /// The sub-modules' stacks (super) and this module's own.
  @override
  List<StackPath> get paths => [...super.paths, authStack];

  @override
  Iterable<RouteModule<RouteUnique>> defineModules() => subModules(this);

  /// This coordinator's own routing graph; its sub-modules bring theirs.
  static final manifest = RouteManifest<AuthRouteId>(
    name: 'auth',
    idCodec: RouteIdCodec.enumValues(AuthRouteId.values),
    layouts: [
      RouteManifestLayout.stack(id: AuthRouteId.shell, path: '/account'),
    ],
    routes: [
      RouteManifestRoute(
        id: AuthRouteId.signIn,
        path: '/account/sign-in',
        parentId: AuthRouteId.shell,
      ),
      RouteManifestRoute(
        id: AuthRouteId.profile,
        path: '/account/profile',
        parentId: AuthRouteId.shell,
      ),
    ],
  );

  /// From a manifest match to a route. No `notFound`: a URL this coordinator
  /// does not own goes on to its sub-modules, then to its siblings.
  late final routeBindings = manifest.bind<RouteUnique>(
    bindings: [
      RouteBinding(
        id: AuthRouteId.signIn,
        create: (match) => SignInRoute(queries: match.uri.queryParameters),
      ),
      RouteBinding(id: AuthRouteId.profile, create: (_) => ProfileRoute()),
    ],
  );

  /// What this coordinator adds to the composed graph, next to what its
  /// sub-modules add.
  @override
  RouteManifestFragment<Object> get localRouteManifestFragment =>
      manifest.fragment;

  @override
  FutureOr<RouteUnique?> parseRouteFromUri(Uri uri) async =>
      await routeBindings.resolve(uri) ?? await super.parseRouteFromUri(uri);

  /// Never reached: this coordinator is only used as a module, where an
  /// unknown URI returns null and the host's own not-found page applies. A
  /// sign-in page would be the wrong answer to a mistyped URL.
  @override
  RouteUnique notFoundRoute(Uri uri) => throw UnsupportedError(
    'AuthRouteModuleCoordinator is used as a module; the host supplies the '
    'not-found page for $uri.',
  );
}

AuthRouteModuleCoordinator _authOf(CoordinatorCore coordinator) =>
    (coordinator as CoordinatorModular<RouteUnique>)
        .getModule<AuthRouteModuleCoordinator>();

/// A URL taken from a query, followed only when it stays in this app: no
/// scheme, no host, an absolute path. Anything else, such as another site or
/// an empty value, is dropped: a sign-in link must not be able to send the
/// user somewhere its author chose.
///
/// Each module file keeps its own copy: modules share no file.
Uri? _localUri(String? value) {
  if (value == null || !value.startsWith('/') || value.startsWith('//')) {
    return null;
  }
  final uri = Uri.tryParse(value);
  return uri == null || uri.hasScheme || uri.hasAuthority ? null : uri;
}

/// Where the user comes from when a rule sends them on a detour: the page on
/// screen. On a cold start there is none.
///
/// A page that is itself a detour, one that carries `from` or `continue`, is
/// not where the user came from, and it is gone once the detour ends. Its own
/// origin is inherited instead, so a chain of detours (the host's welcome
/// page, then sign-in) keeps the first one, and a second gated URL typed over
/// the sign-in page keeps it too. The two query names are the only thing the
/// detour pages of different modules share; no import is needed.
Uri? _originOf(CoordinatorCore coordinator) {
  final onScreen = coordinator.activePath.activeRoute;
  if (onScreen == null) return null;
  if (onScreen case RouteQueryParameters(:final queries)
      when queries.containsKey(SignInRoute.originQuery) ||
          queries.containsKey(SignInRoute.attemptQuery)) {
    return _localUri(queries[SignInRoute.originQuery]);
  }
  return coordinator.currentUri;
}

/// Sends a signed-out user to sign-in, and a signed-in user away from it.
///
/// Typed to [RouteUnique], not [AuthRoute]: it also gates what lands in the
/// sub-modules' stacks, and their routes have their own base.
class RequireSession extends RedirectRule<RouteUnique> {
  RequireSession(this.session, this.trace);

  /// This rule's name in the trace. Spelled out, never read from the type:
  /// a release web build minifies type names.
  static const label = 'RequireSession';

  final AuthSession session;
  final void Function(String line) trace;

  @override
  RedirectResult<RouteUnique> redirectResult(
    covariant CoordinatorCore coordinator,
    RouteUnique route,
  ) {
    // Every module's route base returns its label from toString, so this
    // also names a sub-module's route, whose type this file cannot see.
    final name = '$route';
    // SignInRoute is this rule's own redirect target and lands in the same
    // stack, so the rule continues for it while there is no session. A
    // signed-in user has no business on it: they get their profile, whether
    // they typed the URL, went back to it, or tapped a link.
    if (route is SignInRoute && session.signedIn.value) {
      trace('$label($name) → ProfileRoute (already signed in)');
      return RedirectResult.redirectTo(ProfileRoute());
    }
    if (route is SignInRoute || session.signedIn.value) {
      trace('$label($name) → continue');
      return const RedirectResult.continueRedirect();
    }
    trace('$label($name) → SignInRoute (no session)');
    // The sign-in URL carries both ends of the trip in its query: where the
    // user was going, so signing in can continue there, and where they came
    // from, so "Not now" can return there. It is this page's own, not shared
    // state: a sign-in page opened directly has neither.
    //
    return RedirectResult.redirectTo(
      SignInRoute.after(route.toUri(), from: _originOf(coordinator)),
    );
  }
}

// =============================================================================
// Routes
// =============================================================================

/// The auth module's route base. Every auth destination sits behind
/// [AuthLayout].
///
/// [label] names a route in the rule trace and the path inspector, and
/// [toString] returns it, so a rule typed to any route can name an auth route
/// without importing this file. It is spelled out, never read from the type:
/// a release web build minifies type names.
abstract class AuthRoute extends RouteTarget with RouteUnique {
  String get label;

  @override
  String toString() => label;

  @override
  Type? get layout => AuthLayout;
}

/// The auth shell, on the root stack. A layout parent: never gated.
class AuthLayout extends AuthRoute with RouteLayout<RouteUnique> {
  @override
  String get label => 'AuthLayout';

  @override
  Type? get layout => null;

  @override
  NavigationPath<RouteUnique> resolvePath(
    covariant CoordinatorCore coordinator,
  ) => _authOf(coordinator).authStack;

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      Scaffold(
        appBar: AppBar(title: const Text('Account')),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Banner(
              'auth shell · AuthRouteModuleCoordinator · RequireSession',
            ),
            Expanded(child: buildPath(coordinator)),
          ],
        ),
      );
}

/// The sign-in page keeps both ends of the trip in its URL query:
/// `/account/sign-in?from=/shop&continue=/account/profile`.
///
/// `continue` is where the user was going: "Sign in and continue" goes on
/// there. `from` is the page they were on: "Not now" returns there. While that
/// page is still under this one, returning is a plain back; after a reload
/// nothing is under it, and the URL still says where it was.
///
/// [RouteQueryParameters] does the rest. The query is not part of the route's
/// identity, so it is the same page whatever the attempt. Navigating to a
/// sign-in page while one is open keeps the open one and hands it the new
/// query through `onUpdate`, so the latest attempt wins: a user who types a
/// second gated URL continues there, and one who opens sign-in directly has
/// no attempt left. And the attempt survives a reload, because it is in the
/// URL.
class SignInRoute extends AuthRoute with RouteQueryParameters {
  SignInRoute({Map<String, String> queries = const {}})
    : queryNotifier = ValueNotifier(queries);

  /// The sign-in page RequireSession sends a user to on their way to
  /// [attempt], from the page at [from].
  SignInRoute.after(Uri attempt, {Uri? from})
    : this(
        queries: {
          if (from != null) originQuery: '$from',
          attemptQuery: '$attempt',
        },
      );

  /// The query that holds where the user was going: where "Sign in and
  /// continue" continues.
  static const attemptQuery = 'continue';

  /// The query that holds the page the user was on: where "Not now" returns.
  static const originQuery = 'from';

  @override
  final ValueNotifier<Map<String, String>> queryNotifier;

  /// Where the user was going when RequireSession sent them here, or null
  /// when they opened this page themselves.
  static Uri? attemptIn(Map<String, String> queries) =>
      _localUri(queries[attemptQuery]);

  /// The page the user was on when RequireSession sent them here, or null
  /// when there was none: a cold start, or a page opened directly.
  static Uri? originIn(Map<String, String> queries) =>
      _localUri(queries[originQuery]);

  @override
  String get label => 'SignInRoute';

  @override
  Uri toUri() => AuthRouteModuleCoordinator.manifest.location(
    AuthRouteId.signIn,
    queryParameters: queries,
  );

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final session = _authOf(coordinator).session;
    return _Page(
      heading: 'Sign in',
      children: [
        ValueListenableBuilder<Map<String, String>>(
          valueListenable: queryNotifier,
          builder: (context, queries, _) {
            final attempt = attemptIn(queries);
            final from = originIn(queries);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attempt == null
                        ? 'You opened this page yourself.'
                        : 'RequireSession sent you here: $attempt needs a '
                              'session.',
                  ),
                  if (from != null) Text('You came from $from.'),
                ],
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton(
            key: const Key('auth-sign-in'),
            onPressed: () {
              session.signedIn.value = true;
              // The profile replaces this page, inside this shell. Then the
              // user goes on to where they were going, by URI: it may belong
              // to a module this file cannot see. A rule deeper in the tree
              // may still stop that (Security needs 2FA); the user is then
              // on their profile, signed in, not on a sign-in page that did
              // nothing. Navigations run in the order they were started.
              final attempt = attemptIn(queries);
              coordinator.pushReplacement(ProfileRoute());
              // The profile is already where the user lands, and the sign-in
              // page sends a signed-in user to the profile too: going on to
              // either would put a second profile on the stack.
              final here = {toUri().path, ProfileRoute().toUri().path};
              if (attempt != null && !here.contains(attempt.path)) {
                coordinator.pushUri(attempt);
              }
            },
            child: const Text('Sign in and continue'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextButton(
            key: const Key('auth-not-now'),
            onPressed: () async {
              // Back to where the user came from. That page is under this
              // one, unless the app was reloaded here: then nothing is, and
              // the URL still says where it was.
              final popped = await coordinator.tryPop();
              if (popped != null) return;
              coordinator.replaceUri(originIn(queries) ?? Uri.parse('/'));
            },
            child: const Text('Not now'),
          ),
        ),
      ],
    );
  }
}

class ProfileRoute extends AuthRoute {
  @override
  String get label => 'ProfileRoute';

  @override
  Uri toUri() =>
      AuthRouteModuleCoordinator.manifest.location(AuthRouteId.profile);

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final session = _authOf(coordinator).session;
    return _Page(
      heading: 'Your profile',
      lines: const [
        'OnboardingGate and RequireSession let this page open.',
        'Rules guard entry, not presence: a session that ends later does not '
            'close it.',
      ],
      children: [
        ListTile(
          key: const Key('auth-link-security'),
          leading: const Icon(Icons.link),
          title: const Text('Security settings (by URI)'),
          subtitle: const Text(
            '/account/security · SecurityModule, registered under this '
            'coordinator by the host',
          ),
          onTap: () => coordinator.pushUri(Uri.parse('/account/security')),
        ),
        ListTile(
          key: const Key('auth-sign-out'),
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          onTap: () {
            session.signedIn.value = false;
            coordinator.replaceUri(Uri.parse('/'));
          },
        ),
      ],
    );
  }
}

// =============================================================================
// Widgets (each module file keeps its own: modules share no file)
// =============================================================================

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer)),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.heading,
    this.lines = const [],
    this.children = const [],
  });

  final String heading;
  final List<String> lines;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            heading,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(line),
          ),
        ...children,
      ],
    ),
  );
}
