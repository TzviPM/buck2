# [RFC] Configuration Modifiers

## Why do we need new configuration setup?

A target usually needs to be built in multiple build settings.
For example, there may be different OS (ex. linux, mac, windows),
architectures (ex. x86, arm), and sanitizers
(ex. asan, tsan, ubsan) to use for a single target. Buck has 2 main ways of supporting customizations today:
1. Buckconfigs specified through `--config` or `-c` flags. They are global flags and are often aggregated in modefiles (`@<modefile>` on the command line).
2. Target platforms specified through `default_target_platform` attribute or `--target-platforms` flag), which become a target's "configuration". `--target-platforms` flags are also commonly specified via modefiles.

These methods are problematic for the following reasons.

1. *We have too many modefiles*. A project that needs customizations often ends
up adding its own set of modefiles, causing a continued rise in number of
custom modefiles in the repo. Internally, the number of modefiles in our
monorepo is currently on the order of **10,000s**.

1. *Changing buckconfigs invalidates Buck's state*. Changing buckconfigs or
modefiles of buckconfigs invalidates global state, which adds non-trivial Buck
overhead on every incremental build that changes state. This does not affect
target platforms.

1. *Different modefiles of buckconfigs cannot be used in same build*.
Users that need to run multi-configuration builds today often work around this
by writing scripts that wraps multiple buck build invocations of different
modes. This is slow because Buck state keeps getting repeatedly invalidated.
There is also no way to build a target in different modes (ex. dev and opt) at
the same time, so users that need to do this always have to do this
sequentially. This does not affect target platforms.

1. *Target platform generation is exponential in number of build settings*.
Suppose I want to customize targets based on 3 OSes, 2 architectures, and 3
compilers. With target platforms, I need to first generate all 18 permutations
of these settings as platform targets before using them. This is not scalable.

1. *Target platform does not compose well on command line*. Suppose I want to
use ASAN on top of some existing platform. It's not possible to say specify
ASAN on top of an existing platform on the command line. Instead, I must create
a new platform target with ASAN added to the existing platform before I can use
it.

1. *Poor user Experience*. When every project needs its own set of modes, it's
onerous for users to track what modes are needed to build what targets. Users
often don't realize when they are using the wrong or unnecessary command line
flags.

1. *Poor tooling integration*. Similar to user, it's just onerous for tooling
to keep track of what modes are needed to build a target with. Buckconfigs are
also bad for performance for tools like language servers because it's impossible
to request the builds of two modes in parallel when two targets needs different
modes.

1. *Antithetical to Buck's principles*. Buck's main strength is the ability to abstract away builds of different languages and libraries under one common syntax for the user. The need for project-custom flags goes against this principle.

The Modifier API introduces a unified way to specify build settings on a
project, target, and command line level. Like target platforms, it constructs Buck configurations so it supports multi-configuration builds. It
avoids modefile proliferation by allowing users to easily
set project-specific build settings like compiler and toolchain versions in
the repo rather than on the command line. It avoids scalability problems of
platform generation by being composition-first. The goals of this project is to:

1. *Make `buck build` work on any platform without the use of special flags*.
Today, building a mac target on mac often requires a mac mode,
and likewise for windows. Instead, `buck build` should always work
out of the box on any platform so that there's no need to specify mac mode on
macs or windows mode on windows.
1. *Define a small constrained set of common modifiers that can be used to build any target
in the repo*. This will include common options like mode (ex. dev, opt, release), OS (ex. linux, mac, iphoneos), and architecture (ex. x86, arm).
1. *Unblock cross-building for the majority of targets*. `host_info()` is
a hack to obtain information about the host machine that is the main blocker to
Buck2 cross-building (ex. building a mac or windows
target from linux) working everywhere. As an extension of "making `buck build`
work on any platform", modifiers should make it possible to kill off most use cases of `host_info` in the repo.
1. *Simplify building build tooling*. Because `buck build` works out of
the box, tools like language servers can build targets they need without using
project-specific modefiles or flags.
1. *Delete most modefiles from the repo*.
1. *Deprecate target platforms for modifiers as the sole way of configuring top-level
targets in Buck*.

## Configuration Background

*Feel free to skip this if you already understand Buck configurations.*

A configuration is a collection of `constraint_value` targets
(commonly referred to as constraints).
It defines the build settings used by a target.
A constraint value is keyed by a `constraint_setting`, so there can only
be one `constraint_value` of a `constraint_setting` in a configuration.

For example, suppose `cfg//os:_` is a constraint setting with constraint
values `cfg//os:linux`, `cfg//os:macos`, and `cfg//os:windows`. Then
a configuration may contain either `cfg//os:linux`, `cfg//os:macos`,
or `cfg//os:windows` to indicate which OS a target is built for.

A constraint or a set of constraints can be selected on via `select()` to
customize a target's behavior. For example, the following adds a linux only
dep to a target.

```python
deps = select({
   "cfg//os:linux": [":linux_only_dep"],
   "DEFAULT": [],
})
```

Before building a target on the command line (known as the top-level target),
Buck needs to know its configuration in order to resolve selects. Modifiers
are a new way to resolve a target's configuration for every top-level target.

## API

Every top-level target starts with an empty configuration, and Buck will apply
a list of "modifiers" to obtain a configuration. A modifier is a modification
of a constraint from the existing configuration to obtain a new
 configuration.

The simplest modifier is a constraint value, which inserts
that value into the configuration for its respective constraint setting,
replacing any existing constraint value for that setting.
For example, specifying `cfg//os:linux` as a modifier will
insert `cfg//os:linux` into the configuration,
overriding any existing constraint value for the
`cfg//os:_` constraint setting.

Another type of modifier is a `modifier_select()` of a constraint value.
This can change the constraint value inserted based on the existing
configuration. For example, a modifier like
```python
modifier_select({
  "cfg//os:windows": "cfg//compiler:msvc",
  "DEFAULT": "cfg//compiler:clang",
})
```
will insert msvc constraint into the configuration if OS is windows or clang
constraint otherwise.
A `modifier_select()` behaves similarly to Buck's `select()` but can only
be used in a modifier.
A `modifier_select()` can only be used to modify a single constraint setting,
so the following example is not valid.
```python
# This fails because a modifier cannot modify both compiler and OS.
modifier_select({
  "cfg//os:windows": "cfg//compiler:msvc",
  "DEFAULT": "cfg//os:linux",
})
```

A modifier can be specified in a PACKAGE file, on a target, or on the command
line. This provides the flexibility needed to customize targets on a project,
target, or cli level.

### PACKAGE Modifier

In a PACKAGE file, modifiers can be specified using the `cfg_modifiers`
function and would apply to all targets covered under that PACKAGE. For
example, modifiers specified in `repo/PACKAGE` would apply to any target under
`repo//...`. Modifiers specified in `repo/foo/PACKAGE` would apply to any target under `repo//foo/...` (For resolution order, see "Modifier
Resolution" section).

The `cfg_modifiers` function takes as input
a dictionary of constraint setting to modifier for that setting.
For example, the following is an example that sets modifiers for OS and compiler settings in the repo's top PACKAGE file for all targets in repo.

```python
# repo/PACKAGE

cfg_modifiers({
  "cfg//os:_": "cfg//:linux",
  "cfg//compiler:_": modifier_select({
    "DEFAULT": "cfg//compiler:clang",
    "cfg//os:windows": "cfg//compiler:msvc",
  })
})
```

To make constraints easier to type, you can specify aliases for modifier targets
via Buck's target aliases.

For example, suppose the following aliases exist in `repo/.buckconfig`.

```ini
[alias]
  os = cfg//os:_
  linux = cfg//os:linux
  macos = cfg//os:macos
  windows = cfg//os:windows
  compiler = cfg//compiler:_
  clang = cfg//compiler:clang
  msvc = cfg//compiler:msvc
```
Then the same PACKAGE modifiers can be specified as follows.

```python
# repo/PACKAGE

cfg_modifiers({
  "os": "linux",
  "compiler": modifier_select({
    "DEFAULT": "clang",
    "windows": "msvc",
  })
})
```

### Target Modifier

On a target, modifiers can be specified on the `cfg_modifiers` attribute.
For example, the following specifies modifiers for `repo//foo:bar`.
```python
# repo/foo/BUCK

python_binary(
  name = "bar",
  # ...
  cfg_modifiers = {
    "cfg//os:_": "cfg//os:windows",
    # Target modifiers can also use aliases
    "compiler": "clang",
  },
)
```

### CLI Modifier

On the command line, modifiers are specified as
`buck2 build <target>?<modifiers separated by commas>`.

For example,
`buck2 build repo//foo:bar?cfg//sanitizer:asan` applies asan
modifier on the command line.
`buck2 build repo//foo:bar?cfg//os:linux,cfg//sanitizer:asan`
will apply linux and asan modifiers.
Aliases can also be used on command line, so
`buck2 build repo//foo:bar?asan` is valid.

Command line modifiers cannot be selects, although this may
be revisited if necessary.

Modifiers can be specified for any target pattern, so
`buck2 build repo//foo/...?asan` and
`buck2 build repo//foo:?asan` are also valid.
When specifying a subtarget and modifier with `?`,
subtarget should go before modifier,
ex. `buck2 build repo//foo:bar[comp-db]?asan`.

To specify modifiers to a list of target patterns on the command line,
you can use the `--modifier` or `-m` flag.
For example, `buck2 build repo//foo:bar repo//foo:baz -m release`
is equivalent to `buck2 build repo//foo:bar?release //foo:baz?release`.

`--modifier` flag can be specified multiple times to add multiple modifier, so
`buck2 build --modifier=linux --modifier=release repo//foo:bar`
is equivalent to `buck2 build repo//foo:bar?linux,release`.

It is prohibited to specify both `--modifier` flag and `?` in target pattern.
This restriction can be lifted in the future if there is a need.

When two modifiers of the same constraint setting are specified, then the later one overrides the earlier one. For example,
`buck2 build repo//foo:bar?dev,release` is equivalent to
`buck2 build repo//foo:bar?release`.

On command line, a `config_setting` target can be specified as a collection of
modifiers after `--modifier` or `?`. This will be equivalent to specifying each
constraint inside the `config_setting` as a separate modifier.

### Modifier Resolution

Modifiers are resolved in order of constraint setting, and for each constraint
setting, modifiers for that setting are resolved in order of PACKAGE, target,
and command line, with modifier from parent PACKAGE applied before child
PACKAGE. The end of this section will describe how Buck determines the order
of constraint setting to resolve.

Suppose modifiers for `repo//foo:bar` are specified as follows.

```python
# repo/PACKAGE

cfg_modifiers({
  "cfg//os:_": "cfg//:linux",
  "cfg//compiler:_": modifier_select({
    "DEFAULT": "cfg//compiler:clang",
    "cfg//os:windows": "cfg//compiler:msvc",
  })
})

# repo/foo/PACKAGE

cfg_modifiers({
  "cfg//os:_": "cfg//os:macos",
})

# repo/foo/BUCK

python_binary(
  name = "bar",
  # ...
  cfg_modifiers = {
    "cfg//os:_": "cfg//os:windows",
  },
)
```

At the beginning, the configuration will be empty.
When resolving modifiers, Buck will first resolve all modifiers for
`cfg//os:_` before resolving all modifiers for `cfg//compiler:_`.

For OS, the linux modifier from `repo/PACKAGE` will apply first, followed by
macos modifier from `repo/foo/PACKAGE` and windows modifier from
`repo//foo:bar`'s target modifiers, so `repo//foo:bar` will end up with
`cfg//os:windows` for `cfg//os:_` in its configuration. Next, to resolve
compiler modifier, the `modifier_select` from `repo/PACKAGE` will resolve to
`cfg//compiler:msvc` since existing configuration is windows and apply that as
the modifier. The target configuration for `repo//foo:bar` ends up with windows
and msvc.

However, suppose user invokes `repo//foo:bar?linux` on the command line. When
resolving OS modifier, the linux modifier from cli will override any existing
OS constraint and insert linux into the configuraiton. Then, when resolving the
compiler modifier, the `modifier_select` will resolve to `cfg//compiler:clang`,
giving clang and linux as the final configuration.

Because command line modifiers will apply at the end, they
are also known as required modifiers. Any modifier specified on the command line
will always override any modifier for the same constraint setting specified in
the repo.

The ordering of constraint setting to resolve modifiers is determined based on
dependency order of constraints specified in the keys of the `modifier_select`
specified. Because some modifiers select on other constraints, modifiers for
those constraints must be resolved first. In the previous example, because
compiler modifier selects on OS constraints, Buck will resolve all
OS modifiers before resolving compiler modifiers.
`modifier_select` that ends up with a cycle of selected constraints
(ex. compiler modifier selects on sanitizer but sanitizer modifier also selects
on compiler) will be an error.

### Modifier-Specific Selects

Modifiers have 3 types of select operators that allow for powerful compositions.
Each operation is a function that accepts a dictionary where the keys are
conditionals and values are modifiers.

1. `modifier_select`. Introduced in the previous sections, this is capable of
inserting constraints based on constraints in the existing configuration.

2. `rule_select`. This is capable of selecting based on the rule name (also
known as rule type). The keys are regex patterns to match against the rule
name or "DEFAULT". Partial matches are allowed.

3. `host_select`. This selects based on the host configuration,
whereas `modifier_select` selects based on the target configuration. This
host configuration is constructed when resolving modifiers. `host_select` is
important to making `buck build` work anywhere on any platform. For example,
when the OS to configure is not specified, it's best to assume that the user
wants to target the same OS as the host machine.

An example using `rule_select` and `host_select` is as follows.

```python
# root/PACKAGE

# We want OS to target the host machine by default.
# Ex. build linux on linux machine, build windows on windows machine,
# and build mac on mac machine.
# However, if the rule is apple or android specific, then we should
# always be building for apple/android as OS, no matter the host
# configuration.

cfg_modifiers({
  "cfg//os:_": rule_select({
    "apple_.*": "cfg//os:iphone",
    "android_.*": "cfg//os:android",
    "DEFAULT": host_select({
      "cfg//os:linux": "cfg//os:linux",
      "cfg//os:macos": "cfg//os:macos",
      "cfg//os:windows": "cfg//os:windows",
    })
  })
})
```

On select resolution, Buck's `select` currently requires unambiguous
keys in the dictionary and resolves to the key with the most refined match.
The select operators used in modifiers will diverge from this and implement
a "first-match" behavior, where select resolves to the first condition that evalutes to true in the dictionary.

### Legacy Target platform

Target platform (`--target-platforms` flag or `default_target_platform`
attribute) will be a deprecated way of specifying configuration and will be
killed once all use cases migrate to modifiers. To maintain backwards compatibility
with target platforms during the migration process, modifier resolution
will take into account the target platform specified. This allows for an easy
migration where modifiers can be introduced one at a time without reaching
feature parity of target platform.

If a target's modifiers resolve to an empty configuration, then Buck will reuse
the target platform as the configuration. If modifiers resolve to a non-empty
configuration, then Buck look for any constraint in the target platform not
covered by a constraint setting from the modifier configuration and add those
to the configuration.
For example, suppose in the previous example, the target platform for `repo//
foo:bar` includes `cfg//sanitizer:asan`, then this constraint will be inserted
into the configuration since no modifier covered the sanitizer constraint
setting.

## Debugging modifiers

Because many layers of modifiers can be applied before obtaining
a final configuration, it is important that modifier resolution is easy
to debug and understand. Here are some ways that modifier resolution
can be interpreted.

1. *`buck2 audit modifiers` command*. There will be a `buck2 audit modifiers`
command to show all PACKAGE, target, and required modifiers for a target. It
can also show configuration changes from modifier resolution process if
requested by the user.

2. *Starlark print statements or debugger*.
Modifier resolution process will be implemented in Starlark in prelude.
This means that any user can use any of the existing way to debug starlark
(ex. print statements, Starlark debugger in VSCode) to debug the resolution
process.

## How configuration modifiers differ from transitions

Modifiers are largely inspired by configuration transitions.
The difference between modifier and transition is that a transition can change
the configuration of any target in the graph, but a modifier can only change
the configuration of a top-level target. In other words, if you have target A
that depends on target B and you request a build of A, then A's target
configuration would be resolved via modifiers and propagated down to B, but dep
B would not do its own modifier resolution. When a top-level target goes through
a per-rule transition, that transition is applied after modifiers are resolved.

Below are some examples that show when to use modifier and when to use
transition.

1. *Python version* should be modeled as a transition and not modifier.
   Suppose we have `python_binary` A nested as a resource of
   another `python_binary` B. A should not inherit the python version
   from B, so a transition is needed to change A's python version
   when depended on by B.
2. *Library target* should use modifiers and not transitions.
   A C++ library target should always inherit the configuration
   of its parent C++ binary when it is used as a dep,
   but a top-level C++ library target can still have its configuration
   changed via modifiers when requested from command line.

In the future, we may add support for modifier transition, which can
transition via modifiers, but that is out of the scope of this RFC.
