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
// The coordinator parses its own URIs in parseRouteFromUri, then falls back
// to super, which asks its sub-modules.
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

  /// The destination RequireSession sent to sign-in, so signing in can
  /// continue there.
  final lastAttempt = ValueNotifier<Uri?>(null);

  void reset() {
    signedIn.value = false;
    lastAttempt.value = null;
  }
}

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

  @override
  FutureOr<RouteUnique?> parseRouteFromUri(Uri uri) {
    switch (uri.pathSegments) {
      case ['account', 'sign-in']:
        return SignInRoute();
      case ['account', 'profile']:
        return ProfileRoute();
    }
    return super.parseRouteFromUri(uri);
  }

  /// Not reached while this coordinator is a module: for an unknown URI it
  /// returns null, and the host's own fallback applies.
  @override
  RouteUnique notFoundRoute(Uri uri) => SignInRoute();
}

AuthRouteModuleCoordinator _authOf(CoordinatorCore coordinator) =>
    (coordinator as CoordinatorModular<RouteUnique>)
        .getModule<AuthRouteModuleCoordinator>();

/// Sends a signed-out user to sign-in.
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
    // stack, so the rule continues for it.
    if (route is SignInRoute || session.signedIn.value) {
      trace('$label($name) → continue');
      return const RedirectResult.continueRedirect();
    }
    session.lastAttempt.value = route.toUri();
    trace('$label($name) → SignInRoute (no session)');
    return RedirectResult.redirectTo(SignInRoute());
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

class SignInRoute extends AuthRoute {
  @override
  String get label => 'SignInRoute';

  @override
  Uri toUri() => Uri.parse('/account/sign-in');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final session = _authOf(coordinator).session;
    return _Page(
      heading: 'Sign in',
      children: [
        ValueListenableBuilder<Uri?>(
          valueListenable: session.lastAttempt,
          builder: (context, attempt, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              attempt == null
                  ? 'You opened this page yourself.'
                  : 'RequireSession sent you here: $attempt needs a session.',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton(
            key: const Key('auth-sign-in'),
            onPressed: () {
              session.signedIn.value = true;
              final next =
                  session.lastAttempt.value ?? Uri.parse('/account/profile');
              session.lastAttempt.value = null;
              // Replaces this page with where the user was going. By URI:
              // the destination may belong to a module this file cannot see.
              coordinator.pushReplacementUri(next);
            },
            child: const Text('Sign in and continue'),
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
  Uri toUri() => Uri.parse('/account/profile');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final session = _authOf(coordinator).session;
    return _Page(
      heading: 'Your profile',
      lines: const [
        'Signed in. OnboardingGate and RequireSession let this through.',
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
