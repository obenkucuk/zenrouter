part of 'base.dart';

/// The module tree of one tree root: every module registered through
/// `defineModules`, the stacks each one owns, and where a destination lands.
///
/// It answers every question about how modules relate, named generically so
/// any feature can ask them: parent and ancestry, which module owns a stack,
/// where a destination lands, and which modules of a kind scope a
/// destination ([scopeOf]). A feature keeps its own policy outside the tree
/// and asks it for the modules that mix the feature in.
///
/// The structure comes from the `defineModules` registry, which composition
/// never erases. The pointers composition does erase are not relied on:
/// [RouteModule.coordinator], [StackPath.coordinator] and
/// [CoordinatorCore.rootCoordinator] go one hop only, so a plain module or a
/// stack two levels down points at an intermediate module, and
/// [StackPath.proxyCoordinator] records only the coordinator a stack was
/// created with, often not the module that lists it. The tree follows
/// `coordinator` only to find the tree root, so every coordinator of the tree
/// gets the same answer.
///
/// Topology problems are data, in [problems]; the tree never throws for
/// them. Whether one is an error is for the feature reading the tree to
/// decide, and a tree in which no module opts in to a feature must keep
/// working as before.
///
/// Built once per tree root, on first use; see [of].
@internal
final class RouteModuleTree {
  RouteModuleTree._(this.root, this.nodes, this._nodeOf);

  /// Walks the registry of [root] in pre-order.
  ///
  /// Reads only the registry: the stacks are claimed on first use, so a tree
  /// whose ownership nobody asks about never reads [RouteModule.paths].
  static RouteModuleTree _build(CoordinatorCore root) {
    final nodes = <RouteModuleTreeNode>[];
    final nodeOf = Map<RouteModule, RouteModuleTreeNode>.identity();
    void visit(RouteModule module, RouteModuleTreeNode? parent) {
      final node = RouteModuleTreeNode._(module, parent, nodes.length);
      nodes.add(node);
      nodeOf[module] ??= node;
      if (module is CoordinatorModular) {
        for (final child in registeredModulesOf(module)) {
          visit(child, node);
        }
      }
      // Pre-order: the nodes below this one are the ones added since it.
      node._last = nodes.length - 1;
    }

    visit(root, null);
    return RouteModuleTree._(root, List.unmodifiable(nodes), nodeOf);
  }

  /// The tree [coordinator] belongs to, or `null` when [coordinator] or one
  /// of its ancestors is a test double (see [rootOf]).
  ///
  /// Every coordinator of a tree returns the same instance.
  static RouteModuleTree? of(CoordinatorCore coordinator) =>
      rootOf(coordinator)?._moduleTree;

  /// The tree root of [coordinator]: the coordinator used as `routerConfig`,
  /// reached by walking [RouteModule.coordinator] up to a standalone
  /// coordinator, however deep [coordinator] sits.
  ///
  /// `null` when [coordinator] or one of its ancestors is a test double that
  /// only implements the [CoordinatorCore] interface: it has none of the
  /// state, so it belongs to no module tree.
  ///
  /// Only the probe is guarded. The walk up the tree runs the `coordinator`
  /// getters of real modules, and an error there propagates.
  static CoordinatorCore? rootOf(CoordinatorCore coordinator) =>
      _isRealCoordinator(coordinator) ? coordinator._moduleTreeRoot : null;

  /// Whether [coordinator] is a real [CoordinatorCore] and not a test double
  /// that only implements its interface.
  ///
  /// Such doubles are common: upstream tests pass them to `resolve` and to
  /// guards (`_UnusedCoordinator` in zenrouter_core's
  /// test/mixin/redirect_test.dart and test/mixin/guard_rule_test.dart,
  /// `_ForeignCoordinator` in test/mixin/guard_test.dart, and the
  /// `implements CoordinatorCore` coordinator in zenrouter's
  /// test/coordinator/layout_test.dart), and so do Fake and mockito users.
  /// Reading a private member of another library on them throws
  /// [NoSuchMethodError]. The probe runs no user code, so a
  /// [NoSuchMethodError] from a real coordinator is never mistaken for one.
  static bool _isRealCoordinator(CoordinatorCore coordinator) {
    try {
      return coordinator._isCoordinatorCore;
    } on NoSuchMethodError {
      return false;
    }
  }

  /// The tree root: the coordinator used as `routerConfig`.
  final CoordinatorCore root;

  /// Every registered module, in pre-order: the root first, then each module
  /// followed by its sub-modules, in `defineModules` order. A module
  /// registered at two places has a node at each.
  final List<RouteModuleTreeNode> nodes;

  /// The first node of each module, by identity.
  final Map<RouteModule, RouteModuleTreeNode> _nodeOf;

  /// Whether [module] is registered in this tree.
  ///
  /// Compared by identity: coordinators extend `Equatable`, so two module
  /// coordinators of one type are `==`.
  bool contains(RouteModule module) => _nodeOf.containsKey(module);

  /// The node of [module], or `null` when [module] is not registered here.
  /// For a module registered at two places, its first node in pre-order.
  RouteModuleTreeNode? nodeOf(RouteModule module) => _nodeOf[module];

  /// Whether some registered module is an [M], such as a module that mixes
  /// in [M]. Kept per type.
  bool declares<M extends Object>() =>
      _declared[M] ??= nodes.any((node) => node.module is M);

  final Map<Type, bool> _declared = {};

  /// The node that owns [path], or `null` when no module lists [path].
  ///
  /// Each node claims the stacks it lists in [RouteModule.paths], in
  /// pre-order, so the innermost claim wins: a module coordinator lists its
  /// sub-modules' stacks and the root lists every stack, but each stack ends
  /// with the deepest module listing it. A module that lists a stack of an
  /// ancestor takes it over. A listing reported in [problems] claims nothing.
  RouteModuleTreeNode? ownerOf(StackPath path) => _claims.owners[path];

  /// Every owned stack, in the order it was first claimed.
  Iterable<StackPath> get ownedPaths => _claims.owners.keys;

  /// The topology problems, in the order they were found: [RootStackListed]
  /// and [SiblingSharedStack] while the stacks are claimed, then
  /// [StackWithoutCoordinator] and [StackFromOtherTree] for the owned stacks.
  List<RouteModuleTreeProblem> get problems => _claims.problems;

  /// Whether [node] or a node below it owns a stack.
  bool subtreeOwnsAStack(RouteModuleTreeNode node) => _claims.owners.values.any(
    (owner) => identical(owner, node) || node.encloses(owner),
  );

  /// Stack ownership and its problems, claimed on first use.
  late final _Claims _claims = _claimStacks();

  _Claims _claimStacks() {
    final owners = Map<StackPath, RouteModuleTreeNode>.identity();
    final problems = <RouteModuleTreeProblem>[];
    for (final node in nodes) {
      for (final path in node.module.paths) {
        _claim(node, path, owners, problems);
      }
    }
    for (final MapEntry(key: path, value: node) in owners.entries) {
      final coordinator = path.coordinator;
      if (coordinator == null) {
        problems.add(StackWithoutCoordinator._(path, node));
      } else if (!identical(rootOf(coordinator), root)) {
        problems.add(StackFromOtherTree._(path, node, coordinator));
      }
    }
    return (owners: owners, problems: List.unmodifiable(problems));
  }

  /// Records [node] listing [path]: a claim, or a problem that claims nothing.
  ///
  /// Nodes come in pre-order, so a module lists a stack before any module
  /// below it does. A later listing by a module the owner encloses overwrites
  /// the claim, so the innermost claim wins; that is also how a module takes
  /// over a stack of an ancestor. A listing by any other module is a
  /// [SiblingSharedStack]. [RouteModuleTreeNode.encloses] is constant time,
  /// so a listing costs one map lookup.
  void _claim(
    RouteModuleTreeNode node,
    StackPath path,
    Map<StackPath, RouteModuleTreeNode> owners,
    List<RouteModuleTreeProblem> problems,
  ) {
    if (node.parent != null && identical(path, root.root)) {
      problems.add(RootStackListed._(path, node));
      return;
    }
    final previous = owners[path];
    if (previous != null &&
        !identical(previous, node) &&
        !previous.encloses(node)) {
      problems.add(SiblingSharedStack._(path, node, previous));
      return;
    }
    owners[path] = node;
  }

  /// The stack a coordinator operation would commit [destination] into: the
  /// stack its parent layout resolves to at the tree root, otherwise the root
  /// stack.
  ///
  /// Kept per layout key: a layout resolves to the stack it is bound on, so
  /// the first destination of a key finds the stack and later ones read it,
  /// without walking the active layouts or building a layout. Finding it may
  /// build a layout, which is discarded afterwards; a mounted layout is
  /// reused and never discarded. Throws [StateError] when [destination]
  /// names a layout the tree root cannot build.
  StackPath landingOf(RouteTarget destination) {
    if (destination is! RouteLayoutChild) return root.root;
    final key = destination.parentLayoutKey;
    if (key == null) return root.root;
    return _landings[key] ??= _findLanding(destination);
  }

  final Map<Object, StackPath> _landings = {};

  StackPath _findLanding(RouteLayoutChild destination) {
    final layout = destination.resolveParentLayout(root);
    if (layout == null) throw StateError(_noLayout(destination));
    try {
      return layout.resolvePath(root);
    } finally {
      if (layout.stackPath == null) layout.onDiscard();
    }
  }

  /// Every module from the tree root down to the owner of the stack
  /// [destination] lands in, root first, or `null` when no module lists that
  /// stack. Throws what [landingOf] throws.
  List<RouteModule>? ancestryOf(RouteTarget destination) =>
      ownerOf(landingOf(destination))?.ancestry;

  /// The modules that are an [M], from the tree root down to the owner of the
  /// stack [destination] lands in, root first.
  ///
  /// Empty for a layout parent. Throws [StateError] when [destination] names
  /// a layout the tree root cannot build, and when it lands in a stack no
  /// module lists. The list is kept per owner and type, so asking again
  /// allocates nothing.
  List<M> scopeOf<M extends Object>(RouteTarget destination) {
    if (destination is RouteLayoutParent) return const <Never>[];
    final landing = landingOf(destination);
    final owner =
        ownerOf(landing) ?? (throw StateError(_unlisted(destination, landing)));
    return owner._scope<M>();
  }

  /// Runs [compute] once for [key] and keeps its result for this tree; a
  /// feature keeps a per-tree memo here instead of a field of its own. A
  /// [compute] that throws keeps nothing, so the next call runs it again.
  T _once<T>(Object key, T Function() compute) {
    if (_memos.containsKey(key)) return _memos[key] as T;
    final value = compute();
    _memos[key] = value;
    return value;
  }

  final Map<Object, Object?> _memos = {};

  String _noLayout(RouteLayoutChild destination) =>
      '$destination names parentLayoutKey ${destination.parentLayoutKey}, but '
      'the tree root ${root.runtimeType} has no layout constructor for it, so '
      'it would silently land on the root stack; register the layout on the '
      'tree root.';

  String _unlisted(RouteTarget destination, StackPath landing) =>
      '$destination lands in stack ${_stackLabel(landing)}, which no module of '
      "${root.runtimeType} lists in paths; list it in the owning module's "
      'paths.';
}

/// Who owns each stack of a [RouteModuleTree], and its topology problems.
typedef _Claims = ({
  Map<StackPath, RouteModuleTreeNode> owners,
  List<RouteModuleTreeProblem> problems,
});

/// [path] as messages name it: its debug label, quoted.
String _stackLabel(StackPath path) =>
    "'${path.debugLabel ?? path.runtimeType}'";

/// One registered module of a [RouteModuleTree].
@internal
final class RouteModuleTreeNode {
  RouteModuleTreeNode._(this.module, this.parent, this._index);

  /// The module, compared by identity.
  final RouteModule module;

  /// The node whose `defineModules` returned [module], or `null` for the
  /// tree root.
  final RouteModuleTreeNode? parent;

  /// This node's position in [RouteModuleTree.nodes].
  final int _index;

  /// The position of the last node below this one, or [_index] when no node
  /// is. Pre-order lists a node's subtree right after it, so the nodes below
  /// this one are exactly those at positions `_index + 1` to [_last].
  late final int _last;

  /// Every module from the tree root down to [module], root first.
  ///
  /// Unfiltered: [RouteModuleTree.scopeOf] keeps only the modules of a kind.
  late final List<RouteModule> ancestry = List.unmodifiable([
    ...?parent?.ancestry,
    module,
  ]);

  /// Whether [other] sits below this node. Both must belong to one tree.
  ///
  /// Constant time: two comparisons of pre-order positions instead of a walk
  /// up the parent links.
  bool encloses(RouteModuleTreeNode other) =>
      _index < other._index && other._index <= _last;

  /// The modules of [ancestry] that are an [M], kept per type.
  List<M> _scope<M extends Object>() =>
      (_scopes[M] ??= List<M>.unmodifiable(ancestry.whereType<M>())) as List<M>;

  final Map<Type, List<Object>> _scopes = {};
}

/// A topology problem of a [RouteModuleTree]: a stack listing it cannot take
/// as it is.
///
/// The tree reports it and keeps going; the feature reading the tree decides
/// whether it is an error.
@internal
sealed class RouteModuleTreeProblem {
  RouteModuleTreeProblem._(this.path, this.node);

  /// The stack listed.
  final StackPath path;

  /// The node whose listing of [path] is at fault.
  final RouteModuleTreeNode node;
}

/// [node], a module below the tree root, lists the root stack.
///
/// Only the tree root owns the root stack, so the listing claims nothing.
@internal
final class RootStackListed extends RouteModuleTreeProblem {
  RootStackListed._(super.path, super.node) : super._();
}

/// [node] lists a stack that [owner] claimed first, and neither encloses the
/// other.
///
/// The listing claims nothing: [owner] keeps the stack.
@internal
final class SiblingSharedStack extends RouteModuleTreeProblem {
  SiblingSharedStack._(super.path, super.node, this.owner) : super._();

  /// The node that claimed the stack first.
  final RouteModuleTreeNode owner;
}

/// The stack [node] owns has no coordinator.
@internal
final class StackWithoutCoordinator extends RouteModuleTreeProblem {
  StackWithoutCoordinator._(super.path, super.node) : super._();
}

/// The stack [node] owns belongs to [coordinator], which is not part of this
/// tree.
@internal
final class StackFromOtherTree extends RouteModuleTreeProblem {
  StackFromOtherTree._(super.path, super.node, this.coordinator) : super._();

  /// The stack's [StackPath.coordinator].
  final CoordinatorCore coordinator;
}
