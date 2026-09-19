// =============================================================================
// SecurityModule: two levels deep, root > auth > security
// =============================================================================
// A plain RouteModule with RouteModuleRedirectRule. The host registers it
// under AuthRouteModuleCoordinator, so a destination in its stack is gated by
// the root, then the auth coordinator, then this module:
// OnboardingGate > RequireSession > RequireTwoFactor.
//
// Its shell (SecurityLayout) sits on the root stack; the registry, not the
// widget tree, decides the chain.
//
// Without 2FA, RequireTwoFactor redirects to TwoFactorSetupRoute, a page in
// this module's own stack, and continues for it: it is the rule's own target.
// "Turn on" continues to where the user was going; "Not now" returns where
// they came from. The settings page watches its own condition: when 2FA is
// turned off it enters itself again, so the rule, not the page, decides what
// happens. That is how a rule that guards entry is made to guard presence.
//
// The module owns its routing as a RouteManifest: the shell, the routes under
// it and their URL patterns. RouteModuleBinding matches URLs against it, the
// bindings turn a match into a route, and toUri builds the same URL back from
// it, so there is no parser to keep in step. The host composes every module's
// manifest into one graph and checks it for conflicts.
//
// This file imports only flutter and zenrouter. Its state (TwoFactorStatus)
// and the trace come from the host, through the constructor.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';

/// The security module's own state, created and injected by the host.
class TwoFactorStatus {
  final enabled = ValueNotifier<bool>(false);

  void reset() => enabled.value = false;
}

/// The IDs of this module's manifest: its shell, then its routes.
enum SecurityRouteId { shell, settings, twoFactor }

class SecurityModule extends RouteModule<RouteUnique>
    with
        RouteModuleBinding<RouteUnique, SecurityRouteId>,
        RouteModuleRedirectRule<RouteUnique> {
  SecurityModule(
    super.coordinator, {
    required this.status,
    required this.trace,
  });

  /// The module's routing graph. `parentId` names the shell a route sits
  /// behind; it must be the shell the route's `layout` names.
  static final manifest = RouteManifest<SecurityRouteId>(
    name: 'security',
    idCodec: RouteIdCodec.enumValues(SecurityRouteId.values),
    layouts: [
      RouteManifestLayout.stack(
        id: SecurityRouteId.shell,
        path: '/account/security',
      ),
    ],
    routes: [
      RouteManifestRoute(
        id: SecurityRouteId.settings,
        path: '/account/security',
        parentId: SecurityRouteId.shell,
      ),
      RouteManifestRoute(
        id: SecurityRouteId.twoFactor,
        path: '/account/security/two-factor',
        parentId: SecurityRouteId.shell,
      ),
    ],
  );

  /// From a manifest match to a route. No `notFound`: a URL this module does
  /// not own falls through to the next module.
  @override
  late final routeBindings = manifest.bind<RouteUnique>(
    bindings: [
      RouteBinding(
        id: SecurityRouteId.settings,
        create: (_) => SecuritySettingsRoute(),
      ),
      RouteBinding(
        id: SecurityRouteId.twoFactor,
        create: (match) =>
            TwoFactorSetupRoute(queries: match.uri.queryParameters),
      ),
    ],
  );

  final TwoFactorStatus status;
  final void Function(String line) trace;

  /// Read on every resolution pass, so it is built once.
  @override
  late final List<RedirectRule> redirectRules = [
    RequireTwoFactor(status, trace),
  ];

  late final NavigationPath<RouteUnique> securityStack =
      NavigationPath<RouteUnique>.createWith(
        label: 'security',
        coordinator: coordinator,
      )..bindLayout(SecurityLayout.new);

  @override
  List<StackPath> get paths => [securityStack];
}

SecurityModule _securityOf(CoordinatorCore coordinator) =>
    (coordinator as CoordinatorModular<RouteUnique>)
        .getModule<SecurityModule>();

/// A URL taken from a query, followed only when it stays in this app: no
/// scheme, no host, an absolute path. Anything else, such as another site or
/// an empty value, is dropped.
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
/// origin is inherited instead, so a chain of detours keeps the first one. The
/// two query names are the only thing the detour pages of different modules
/// share; no import is needed.
Uri? _originOf(CoordinatorCore coordinator) {
  final onScreen = coordinator.activePath.activeRoute;
  if (onScreen == null) return null;
  if (onScreen case RouteQueryParameters(:final queries)
      when queries.containsKey(TwoFactorSetupRoute.originQuery) ||
          queries.containsKey(TwoFactorSetupRoute.attemptQuery)) {
    return _localUri(queries[TwoFactorSetupRoute.originQuery]);
  }
  return coordinator.currentUri;
}

/// Sends everything in this module's stack to the two-factor page while
/// 2FA is off.
///
/// Typed to [SecurityRoute]: only security routes land in this module's
/// stack. Layout parents are never offered.
class RequireTwoFactor extends RedirectRule<SecurityRoute> {
  RequireTwoFactor(this.status, this.trace);

  /// This rule's name in the trace. Spelled out, never read from the type:
  /// a release web build minifies type names.
  static const label = 'RequireTwoFactor';

  final TwoFactorStatus status;
  final void Function(String line) trace;

  @override
  RedirectResult<SecurityRoute> redirectResult(
    covariant CoordinatorCore coordinator,
    SecurityRoute route,
  ) {
    final name = route.label;
    // TwoFactorSetupRoute is this rule's own redirect target and lands in the
    // same stack, so the rule continues for it.
    if (route is TwoFactorSetupRoute || status.enabled.value) {
      trace('$label($name) → continue');
      return const RedirectResult.continueRedirect();
    }
    trace('$label($name) → TwoFactorSetupRoute (2FA is off)');
    // The page the user is kept out of is not where they came from: when the
    // settings page enters itself again, it is the page on screen.
    final attempt = route.toUri();
    final origin = _originOf(coordinator);
    return RedirectResult.redirectTo(
      TwoFactorSetupRoute.after(
        attempt,
        from: origin?.path == attempt.path ? null : origin,
      ),
    );
  }
}

// =============================================================================
// Routes
// =============================================================================

/// The security module's route base. Every security destination sits behind
/// [SecurityLayout].
///
/// [label] names a route in the rule trace and the path inspector, and
/// [toString] returns it, so a rule typed to any route can name a security
/// route without importing this file. It is spelled out, never read from the
/// type: a release web build minifies type names.
abstract class SecurityRoute extends RouteTarget with RouteUnique {
  String get label;

  @override
  String toString() => label;

  @override
  Type? get layout => SecurityLayout;
}

/// The security shell, on the root stack. A layout parent: never gated.
class SecurityLayout extends SecurityRoute with RouteLayout<RouteUnique> {
  @override
  String get label => 'SecurityLayout';

  @override
  Type? get layout => null;

  @override
  NavigationPath<RouteUnique> resolvePath(
    covariant CoordinatorCore coordinator,
  ) => _securityOf(coordinator).securityStack;

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      Scaffold(
        appBar: AppBar(title: const Text('Security')),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Banner(
              'SecurityModule · under AuthRouteModuleCoordinator · '
              'RequireTwoFactor',
            ),
            Expanded(child: buildPath(coordinator)),
          ],
        ),
      );
}

class SecuritySettingsRoute extends SecurityRoute {
  @override
  String get label => 'SecuritySettingsRoute';

  @override
  Uri toUri() => SecurityModule.manifest.location(SecurityRouteId.settings);

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      _SecuritySettingsPage(
        route: this,
        coordinator: coordinator,
        status: _securityOf(coordinator).status,
      );
}

/// The two-factor page: where [RequireTwoFactor] sends a user without 2FA.
///
/// An ordinary page of the security stack that shows its question as an
/// [AlertDialog] card. The module owns and gates it like any of its routes,
/// and it is that stack's only page, so it closes with its two buttons or the
/// shell's back arrow.
///
/// It is a detour page like sign-in and welcome: [RouteQueryParameters] keeps
/// both ends of the trip in its URL,
/// `/account/security/two-factor?from=/account/profile&continue=/account/security`.
/// "Turn on and continue" goes on to `continue`. "Not now" returns to the page
/// under the shell, or to `from` after a reload, when nothing is under it.
class TwoFactorSetupRoute extends SecurityRoute with RouteQueryParameters {
  TwoFactorSetupRoute({Map<String, String> queries = const {}})
    : queryNotifier = ValueNotifier(queries);

  /// The page [RequireTwoFactor] sends a user to on their way to [attempt],
  /// from the page at [from].
  TwoFactorSetupRoute.after(Uri attempt, {Uri? from})
    : this(
        queries: {
          if (from != null) originQuery: '$from',
          attemptQuery: '$attempt',
        },
      );

  /// The queries of a detour page, the same in every module: where the user
  /// was going, and the page they were on.
  static const attemptQuery = 'continue';
  static const originQuery = 'from';

  @override
  final ValueNotifier<Map<String, String>> queryNotifier;

  @override
  String get label => 'TwoFactorSetupRoute';

  @override
  Uri toUri() => SecurityModule.manifest.location(
    SecurityRouteId.twoFactor,
    queryParameters: queries,
  );

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final status = _securityOf(coordinator).status;
    return ValueListenableBuilder<Map<String, String>>(
      valueListenable: queryNotifier,
      builder: (context, queries, _) {
        final attempt =
            _localUri(queries[attemptQuery]) ?? SecuritySettingsRoute().toUri();
        final from = _localUri(queries[originQuery]);
        return Material(
          child: AlertDialog(
            title: const Text('Turn on two-factor authentication'),
            content: Text(
              'RequireTwoFactor sent you here: $attempt needs two-factor '
              'authentication.${from == null ? '' : ' You came from $from.'}',
            ),
            actions: [
              TextButton(
                key: const Key('security-2fa-not-now'),
                onPressed: () async {
                  // Leave Security. This is the shell's only page, so a pop
                  // takes the shell with it and shows the page under it.
                  // After a reload nothing is under it, and the URL still says
                  // where the user came from.
                  final popped = await coordinator.tryPop();
                  if (popped != null) return;
                  coordinator.replaceUri(from ?? Uri.parse('/'));
                },
                child: const Text('Not now'),
              ),
              FilledButton(
                key: const Key('security-2fa-turn-on'),
                onPressed: () {
                  status.enabled.value = true;
                  // Inside this shell: the settings page replaces this one.
                  coordinator.pushReplacementUri(attempt);
                },
                child: const Text('Turn on and continue'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The settings page watches the condition that let it open.
///
/// Rules guard entry, not presence: nothing closes this page when 2FA is
/// turned off. So the page asks again: it enters itself, the chain runs, and
/// [RequireTwoFactor] sends the user to the two-factor page. The rule stays
/// the one place that decides, and the page needs no `pop` of its own.
class _SecuritySettingsPage extends StatefulWidget {
  const _SecuritySettingsPage({
    required this.route,
    required this.coordinator,
    required this.status,
  });

  final SecuritySettingsRoute route;
  final Coordinator coordinator;
  final TwoFactorStatus status;

  @override
  State<_SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<_SecuritySettingsPage> {
  @override
  void initState() {
    super.initState();
    widget.status.enabled.addListener(_enterAgain);
  }

  @override
  void dispose() {
    widget.status.enabled.removeListener(_enterAgain);
    super.dispose();
  }

  void _enterAgain() {
    if (widget.status.enabled.value) return;
    // Only while this is the page on screen: a replacement acts on that one.
    final onScreen = widget.coordinator.activePath.activeRoute;
    if (!identical(onScreen, widget.route)) return;
    widget.coordinator.pushReplacement(SecuritySettingsRoute());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Material(
      color: Colors.amber,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Security settings',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'OnboardingGate (root), RequireSession (auth) and '
              'RequireTwoFactor (this module) let this through, in that '
              'order.',
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: widget.status.enabled,
            builder: (context, enabled, _) => SwitchListTile(
              key: const Key('security-two-factor'),
              title: const Text('Two-factor authentication'),
              subtitle: const Text(
                'Rules guard entry, not presence. This page watches its own '
                'condition: turn it off and the page enters itself again, so '
                'RequireTwoFactor decides what happens.',
              ),
              value: enabled,
              onChanged: (value) => widget.status.enabled.value = value,
            ),
          ),
        ],
      ),
    ),
  );
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
