# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

def _toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    if ctx.attrs.dep != None:
        return ctx.attrs.dep.providers
    return [DefaultInfo()]

toolchain = rule(
    attrs = {"dep": attrs.option(attrs.exec_dep(), default = None)},
    impl = _toolchain_impl,
    is_toolchain_rule = True,
)

def _toolchain_alias_impl(ctx: AnalysisContext) -> list[Provider]:
    return ctx.attrs.actual.providers

toolchain_alias = rule(
    doc = """
toolchain_alias acts like alias but for toolchain rules.

The toolchain_alias itself is a toolchain rule and the `actual` argument is
expected to be a toolchain_rule as well.
    """,
    attrs = {"actual": attrs.toolchain_dep(doc = "The actual toolchain that is being aliased. This should be a toolchain rule.")},
    impl = _toolchain_alias_impl,
    is_toolchain_rule = True,
)
