# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//cxx:cxx_toolchain_types.bzl", "PicBehavior")
load("@prelude//python:python.bzl", "PythonLibraryInfo")
load("@prelude//utils:utils.bzl", "expect")
load(
    ":link_info.bzl",
    "LibOutputStyle",
    "LinkInfo",  # @unused Used as a type
    "LinkInfos",
    "LinkStrategy",
    "Linkage",
    "LinkedObject",
    "MergedLinkInfo",
    "get_lib_output_style",
    "get_output_styles_for_linkage",
    _get_link_info = "get_link_info",
)

# A provider with information used to link a rule into a shared library.
# Potential omnibus roots must provide this so that omnibus can link them
# here, in the context of the top-level packaging rule.
LinkableRootInfo = provider(fields = [
    "link_infos",  # LinkInfos
    "name",  # [str, None]
    "deps",  # ["label"]
    "shared_root",  # SharedOmnibusRoot, either this or no_shared_root_reason is set.
    "no_shared_root_reason",  # OmnibusPrivateRootProductCause
])

# This annotation is added on an AnnotatedLinkableRoot to indicate what
# dependend resulted in it being discovered as an implicit root. For example,
# if Python library A depends on C++ library B, then in the
# AnnotatedLinkableRoot for B, we'll have A as the dependent.
LinkableRootAnnotation = record(
    dependent = field(typing.Any),
)

AnnotatedLinkableRoot = record(
    root = field(LinkableRootInfo),
    annotation = field([LinkableRootAnnotation, None], None),
)

###############################################################################
# Linkable Graph collects information on a node in the target graph that
# contains linkable output. This graph information may then be provided to any
# consumers of this target.
###############################################################################

_DisallowConstruction = record()

LinkableNode = record(
    # Attribute labels on the target.
    labels = field(list[str], []),
    # Preferred linkage for this target.
    preferred_linkage = field(Linkage, Linkage("any")),
    # Linkable deps of this target.
    deps = field(list[Label], []),
    # Exported linkable deps of this target.
    #
    # We distinguish between deps and exported deps so that when creating shared
    # libraries in a large graph we only need to link each library against its
    # deps and their (transitive) exported deps. This helps keep link lines smaller
    # and produces more efficient libs (for example, DT_NEEDED stays a manageable size).
    exported_deps = field(list[Label], []),
    # Link infos for all supported lib output styles supported by this node. This should have a value
    # for every output_style supported by the preferred linkage.
    link_infos = field(dict[LibOutputStyle, LinkInfos], {}),
    # Shared libraries provided by this target.  Used if this target is
    # excluded.
    shared_libs = field(dict[str, LinkedObject], {}),

    # Only allow constructing within this file.
    _private = _DisallowConstruction,
)

LinkableGraphNode = record(
    # Target/label of this node
    label = field(Label),

    # If this node has linkable output, it's linkable data
    linkable = field([LinkableNode, None], None),

    # All potential root notes for an omnibus link (e.g. C++ libraries,
    # C++ Python extensions).
    roots = field(dict[Label, AnnotatedLinkableRoot], {}),

    # Exclusions this node adds to the Omnibus graph
    excluded = field(dict[Label, None], {}),

    # Only allow constructing within this file.
    _private = _DisallowConstruction,
)

LinkableGraphTSet = transitive_set()

# The LinkableGraph for a target holds all the transitive nodes, roots, and exclusions
# from all of its dependencies.
#
# TODO(cjhopman): Rather than flattening this at each node, we should build up an actual
# graph structure.
LinkableGraph = provider(fields = [
    # Target identifier of the graph.
    "label",  # Label
    "nodes",  # "LinkableGraphTSet"
])

# Used to tag a rule as providing a shared native library that may be loaded
# dynamically, at runtime (e.g. via `dlopen`).
DlopenableLibraryInfo = provider(fields = [])

def create_linkable_node(
        ctx: AnalysisContext,
        preferred_linkage: Linkage = Linkage("any"),
        deps: list[Dependency] = [],
        exported_deps: list[Dependency] = [],
        link_infos: dict[LibOutputStyle, LinkInfos] = {},
        shared_libs: dict[str, LinkedObject] = {}) -> LinkableNode:
    for output_style in get_output_styles_for_linkage(preferred_linkage):
        expect(
            output_style in link_infos,
            "must have {} link info".format(output_style),
        )
    return LinkableNode(
        labels = ctx.attrs.labels,
        preferred_linkage = preferred_linkage,
        deps = linkable_deps(deps),
        exported_deps = linkable_deps(exported_deps),
        link_infos = link_infos,
        shared_libs = shared_libs,
        _private = _DisallowConstruction(),
    )

def create_linkable_graph_node(
        ctx: AnalysisContext,
        linkable_node: [LinkableNode, None] = None,
        roots: dict[Label, AnnotatedLinkableRoot] = {},
        excluded: dict[Label, None] = {}) -> LinkableGraphNode:
    return LinkableGraphNode(
        label = ctx.label,
        linkable = linkable_node,
        roots = roots,
        excluded = excluded,
        _private = _DisallowConstruction(),
    )

def create_linkable_graph(
        ctx: AnalysisContext,
        node: [LinkableGraphNode, None] = None,
        deps: list[Dependency] = [],
        children: list[LinkableGraph] = []) -> LinkableGraph:
    all_children_graphs = filter(None, [x.get(LinkableGraph) for x in deps]) + children
    kwargs = {
        "children": [child_node.nodes for child_node in all_children_graphs],
    }
    if node:
        kwargs["value"] = node
    return LinkableGraph(
        label = ctx.label,
        nodes = ctx.actions.tset(LinkableGraphTSet, **kwargs),
    )

def get_linkable_graph_node_map_func(graph: LinkableGraph):
    def get_linkable_graph_node_map() -> dict[Label, LinkableNode]:
        nodes = graph.nodes.traverse()
        linkable_nodes = {}
        for node in filter(None, nodes):
            if node.linkable:
                linkable_nodes[node.label] = node.linkable
        return linkable_nodes

    return get_linkable_graph_node_map

def linkable_deps(deps: list[Dependency]) -> list[Label]:
    labels = []

    for dep in deps:
        dep_info = linkable_graph(dep)
        if dep_info != None:
            labels.append(dep_info.label)

    return labels

def linkable_graph(dep: Dependency) -> [LinkableGraph, None]:
    """
    Helper to extract `LinkableGraph` from a dependency which also
    provides `MergedLinkInfo`.
    """

    # We only care about "linkable" deps.
    if PythonLibraryInfo in dep or MergedLinkInfo not in dep or dep.label.sub_target == ["headers"]:
        return None

    expect(
        LinkableGraph in dep,
        "{} provides `MergedLinkInfo`".format(dep.label) +
        " but doesn't also provide `LinkableGraph`",
    )

    return dep[LinkableGraph]

def get_link_info(
        node: LinkableNode,
        output_style: LibOutputStyle,
        prefer_stripped: bool = False) -> LinkInfo:
    info = _get_link_info(
        node.link_infos[output_style],
        prefer_stripped = prefer_stripped,
    )
    return info

def get_deps_for_link(
        node: LinkableNode,
        strategy: LinkStrategy,
        pic_behavior: PicBehavior) -> list[Label]:
    """
    Return deps to follow when linking against this node with the given link
    style.
    """

    # Avoid making a copy of the list until we know have to modify it.
    deps = node.exported_deps

    # If we're linking statically, include non-exported deps.
    output_style = get_lib_output_style(strategy, node.preferred_linkage, pic_behavior)
    if output_style != LibOutputStyle("shared_lib") and node.deps:
        # Important that we don't mutate deps, but create a new list
        deps = deps + node.deps

    return deps
