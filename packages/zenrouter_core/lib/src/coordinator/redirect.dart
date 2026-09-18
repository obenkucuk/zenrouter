part of 'base.dart';

/// Redirect rules for the destinations that land in a stack this module owns.
///
/// Mix into the root coordinator, a coordinator used as a [RouteModule], or a
/// plain [RouteModule]. It is one mixin for all three, like
/// `RouteModuleBinding`.
///
/// ```dart
/// class AuthRouteModuleCoordinator extends Coordinator<AppRoute>
///     with CoordinatorModular<AppRoute>, RouteModuleRedirectRule<AppRoute> {
///   AuthRouteModuleCoordinator(this.coordinator, {required this.session});
///
///   @override
///   final CoordinatorModular<AppRoute> coordinator;
///
///   final AuthSession session;
///
///   // Read on every navigation, so build the list once.
///   @override
///   late final List<RedirectRule> redirectRules = [RequireSession(session)];
///
///   late final authStack = NavigationPath<AppRoute>.createWith(
///     label: 'auth',
///     coordinator: coordinator,
///   )..bindLayout(AuthLayout.new);
///
///   @override
///   List<StackPath> get paths => [...super.paths, authStack];
///
///   @override
///   Iterable<RouteModule<AppRoute>> defineModules() => const [];
///
///   @override
///   AppRoute notFoundRoute(Uri uri) => NotFoundRoute(uri);
/// }
/// ```
///
/// ## Scope
///
/// A module owns the stacks it lists in [paths]. Its rules gate every
/// destination that lands in one of them, or in a stack of one of its
/// sub-modules. The root lists every stack, so root rules gate every
/// destination. Listing a stack claims it: two sibling modules cannot list
/// the same stack, a module cannot list the root stack, and a module that
/// lists a stack its ancestor owns takes that stack over, because the
/// innermost claim wins. List each stack only in the module that owns it.
///
/// A destination lands where the coordinator commits it: the stack its parent
/// layout resolves to, otherwise the root stack. This is decided at the tree
/// root, not by the coordinator, module instance or path the call went
/// through. To gate a destination, give it a layout hosted in one of the
/// module's stacks. A layout-less route lands on the root stack and belongs
/// to the root; pin that with [RouteModuleRedirectScope.redirectScopeOf].
///
/// ## Order
///
/// The root's rules run first, then each enclosing declaring module, then the
/// owning module, then the destination's own [RouteRedirectRule]. The first
/// [StopRedirect] or [RedirectTo] wins. A [RedirectTo] target is resolved
/// again from the top, in its own scope, so a rule must continue for its own
/// redirect target when that target lands in the same scope. A [RedirectTo]
/// to the destination itself moves nothing, so it wins nothing: the rules
/// below it still run, as after a [ContinueRedirect]. Layout parents are
/// never offered.
///
/// ## Writing rules
///
/// Rules receive the tree root (the coordinator used as `routerConfig`),
/// whatever the call site. A rule that needs its module's state should
/// capture it at construction:
/// `late final redirectRules = [RequireSession(session)]`.
///
/// Type a rule to the route base the module's stacks host, and type-test
/// inside it. A rule typed narrower than what lands in its stacks throws a
/// [TypeError] when it is offered another route.
///
/// Rules should be pure decisions: some operations resolve twice (replace,
/// recover, tab activation).
///
/// ## Failure handling
///
/// Misconfiguration throws [StateError], at the latest on the first
/// resolution: a declaring module whose subtree lists no stack, a stack listed
/// by two sibling modules, a module listing the root stack, a listed stack
/// with no coordinator or with one from another tree, a call made on a
/// declaring module coordinator that is missing from `defineModules`, a
/// parent layout the tree root cannot build, and a landing stack no module
/// lists. A tree in which no module mixes this in behaves as before.
///
/// Not detected: a declaring module that is not returned from
/// `defineModules`, or from a sub-module's, is invisible to the scope, and
/// its rules never run. Only a call made on such a module coordinator itself
/// throws. Register every declaring module.
///
/// Rules run when a destination is navigated to, and only then. They are
/// routing gates, not a security boundary:
/// - State restoration binds every saved stack as it was and runs the rules
///   for the active route only. A page under it that a rule would refuse now
///   is one back away. Clear a gated stack yourself when its condition ends
///   (sign-out), or check again in the page.
/// - A path-level commit of a route that lands elsewhere (`stack.push` of a
///   route without this stack's layout) is caught by an assert, so in debug
///   only.
/// Keep the checks that protect data on the server.
mixin RouteModuleRedirectRule<T extends RouteUri> on RouteModule<T> {
  /// Rules for destinations landing in this module's stacks, in order.
  ///
  /// Read on every resolution pass, so cache the list (`late final`).
  List<RedirectRule> get redirectRules;
}

/// Read-only view of the redirect scope: which modules gate a destination.
///
/// This is the supported way to ask whether a destination is gated.
/// Navigation asks it too: a tab switch takes its synchronous path when no
/// rule gates the entry. Tests and tooling use it to pin a chain.
extension RouteModuleRedirectScope on CoordinatorCore {
  /// The modules whose rules gate [destination], in the order they run.
  ///
  /// Returns the same answer from any coordinator of the tree. Empty for a
  /// layout parent and for a tree where no module declares rules. A module
  /// that mixes in [RouteModuleRedirectRule] with an empty rule list is
  /// listed, although it gates nothing. Throws whatever navigating to
  /// [destination] would throw.
  ///
  /// Compare with `same`: coordinators extend `Equatable`, so `==` alone
  /// could match another coordinator of the same type.
  ///
  /// ```dart
  /// expect(app.redirectScopeOf(ProfileRoute()), [same(app), same(auth)]);
  /// ```
  List<RouteModuleRedirectRule> redirectScopeOf(RouteTarget destination) =>
      moduleTreeUsingRedirectRules?.redirectLineageOf(destination) ?? const [];
}

/// Redirect rules on a [RouteModuleTree]: which modules gate a destination,
/// and whether the tree is fit to be gated.
///
/// It only filters the tree by [RouteModuleRedirectRule] and validates it for
/// redirects; ancestry, ownership and landing come from the tree.
@internal
extension RouteModuleTreeRedirect on RouteModuleTree {
  /// Whether some module of this tree mixes in [RouteModuleRedirectRule]. A
  /// tree where none does is opted out and navigates as before.
  bool get usesRedirectRules => declares<RouteModuleRedirectRule>();

  /// Throws [StateError] listing every misconfiguration of this tree's
  /// redirect scope: its [problems], then each module that mixes in
  /// [RouteModuleRedirectRule] but owns no stack, directly or through its
  /// sub-modules.
  ///
  /// Checked once per tree: a tree that passes is not checked again, and one
  /// that fails throws on every call.
  void validateRedirectScope() {
    _once(_redirectScopeValidated, () {
      final misconfigurations = [
        for (final problem in problems) _describe(problem),
        for (final node in nodes)
          if (node.module is RouteModuleRedirectRule &&
              !subtreeOwnsAStack(node))
            _ownsNoStack(node),
      ];
      if (misconfigurations.isNotEmpty) {
        throw StateError(
          'Redirect scope of ${root.runtimeType} is misconfigured:\n'
          '- ${misconfigurations.join('\n- ')}',
        );
      }
      return true;
    });
  }

  /// The modules whose rules gate [destination], root first: the
  /// [scopeOf] of [RouteModuleRedirectRule]. Empty for a layout parent.
  ///
  /// In debug, a live [destination] (a tab entry being switched to, or a
  /// route navigated to again) must also be gated by the owners of the stack
  /// it sits in, as a commit must
  /// ([StackPathRedirectDebug.debugAssertRedirectOwnersGated]): a tab entry
  /// without its tab set's layout lands on the root stack, and its owners'
  /// rules would never run for it.
  List<RouteModuleRedirectRule> redirectLineageOf(RouteTarget destination) {
    assert(
      destination.stackPath == null ||
          destination.stackPath!.debugAssertRedirectOwnersGated(destination),
    );
    return scopeOf<RouteModuleRedirectRule>(destination);
  }
}

/// The redirect-gated module tree of a coordinator.
@internal
extension CoordinatorRedirectTree on CoordinatorCore {
  /// The module tree of this coordinator if it uses redirect rules,
  /// validated ([RouteModuleTreeRedirect.validateRedirectScope]); `null` for
  /// an opted-out tree and for a test double. Every coordinator of the tree
  /// returns the same tree.
  ///
  /// Throws [StateError] when the redirect scope is misconfigured, and when
  /// this coordinator declares rules and is used as a module but is not
  /// registered in its tree root's `defineModules`.
  RouteModuleTree? get moduleTreeUsingRedirectRules {
    final tree = RouteModuleTree.of(this);
    if (tree == null) return null;
    final usesRedirectRules = tree.usesRedirectRules;
    if (usesRedirectRules) tree.validateRedirectScope();
    if (this is RouteModuleRedirectRule &&
        isRouteModule &&
        !tree.contains(this)) {
      throw StateError(_unregistered(this, tree.root));
    }
    return usesRedirectRules ? tree : null;
  }
}

/// The redirect check of a path-level commit.
@internal
extension StackPathRedirectDebug on StackPath {
  /// Asserts that every owner of this stack that has redirect rules gates
  /// [route]. Run before this path commits [route], and when a live [route]
  /// is navigated to again.
  ///
  /// Throws [AssertionError] when a module that gates this stack and has
  /// rules does not gate [route]: the route was committed, at path level,
  /// into a stack whose owners' rules never ran for it. Returns `true`
  /// otherwise, including for layout parents, paths without a coordinator,
  /// opted-out trees and unlisted paths. A module with an empty rule list
  /// skipped nothing, so it behaves exactly like a module without the mixin.
  ///
  /// Decided with the owners' rule lists as they are at commit time, after
  /// resolution has awaited its rules; keep `redirectRules` stable between
  /// navigations.
  ///
  /// It sees a route in the wrong stack, not rules that never ran: a commit
  /// that runs no rule at all (`replaceAll`, a restored stack) passes when its
  /// routes belong in this stack.
  bool debugAssertRedirectOwnersGated(RouteTarget route) {
    if (route is RouteLayoutParent) return true;
    final coordinator = this.coordinator;
    if (coordinator == null) return true;
    final tree = RouteModuleTree.of(coordinator);
    if (tree == null || !tree.usesRedirectRules) return true;
    tree.validateRedirectScope();
    // The usual case: the route lands in this stack, so both owner chains are
    // one and nothing can have been skipped.
    final owner = tree.ownerOf(this);
    if (identical(owner, tree.ownerOf(tree.landingOf(route)))) return true;
    final owners = owner?.ancestry.whereType<RouteModuleRedirectRule>();
    if (owners == null || owners.isEmpty) return true;
    final gated =
        tree.ancestryOf(route)?.whereType<RouteModuleRedirectRule>() ??
        const <RouteModuleRedirectRule>[];
    final skipped = [
      for (final module in owners)
        if (module.redirectRules.isNotEmpty &&
            !gated.any((gate) => identical(gate, module)))
          module,
    ];
    if (skipped.isEmpty) return true;
    throw AssertionError(_skippedAtCommit(route, this, skipped));
  }
}

/// The memo key of [RouteModuleTreeRedirect.validateRedirectScope].
final Object _redirectScopeValidated = Object();

String _describe(RouteModuleTreeProblem problem) => switch (problem) {
  RootStackListed(:final path, :final node) => _listsRootStack(node, path),
  SiblingSharedStack(:final path, :final node, :final owner) => _sharedStack(
    path,
    owner,
    node,
  ),
  StackWithoutCoordinator(:final path, :final node) => _noCoordinator(
    path,
    node,
  ),
  StackFromOtherTree(:final path, :final node, :final coordinator) =>
    _otherTree(path, node, coordinator),
};

String _ownsNoStack(RouteModuleTreeNode node) =>
    '${node.module.runtimeType} declares redirectRules but no stack it or '
    'its sub-modules list in paths, so its routes land on the root stack and '
    'its rules could gate nothing. Give the module a stack, bind a layout to '
    'it and give its routes that layout; or declare the rules on the root '
    'coordinator, which owns the root stack.';

String _sharedStack(
  StackPath path,
  RouteModuleTreeNode first,
  RouteModuleTreeNode second,
) =>
    'stack ${_stackLabel(path)} is listed by both ${first.module.runtimeType} '
    'and ${second.module.runtimeType}, and neither encloses the other; '
    'list each stack in exactly one module.';

String _listsRootStack(RouteModuleTreeNode node, StackPath path) =>
    '${node.module.runtimeType} lists the root stack ${_stackLabel(path)} in '
    'paths, which would make its rules gate every layout-less route; only '
    'the tree root owns the root stack, so remove it from the module paths.';

String _noCoordinator(StackPath path, RouteModuleTreeNode node) =>
    'stack ${_stackLabel(path)} listed by ${node.module.runtimeType} has no '
    'coordinator, so path-level navigation on it would skip every gate; '
    'create it with a coordinator of this tree.';

String _otherTree(
  StackPath path,
  RouteModuleTreeNode node,
  CoordinatorCore coordinator,
) =>
    'stack ${_stackLabel(path)} listed by ${node.module.runtimeType} belongs '
    'to ${coordinator.runtimeType}, which is not part of this tree; create it '
    'with a coordinator of this tree.';

String _unregistered(CoordinatorCore module, CoordinatorCore treeRoot) =>
    '${module.runtimeType} declares redirectRules and is used as a module '
    'of ${treeRoot.runtimeType}, but it is not registered in defineModules, '
    'so its rules could never run; return it from defineModules.';

String _skippedAtCommit(
  RouteTarget route,
  StackPath path,
  List<RouteModuleRedirectRule> skipped,
) =>
    '$route was committed into stack ${_stackLabel(path)}, but the redirect '
    'rules of ${skipped.map((module) => module.runtimeType).join(', ')}, '
    'which gate that stack, never ran for it. Give the route the layout of '
    'that stack, or navigate through the coordinator.';
