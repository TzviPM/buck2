# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//:paths.bzl", "paths")
load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxPlatformInfo", "CxxToolchainInfo")
load(
    ":compile.bzl",
    "CxxSrcCompileCommand",  # @unused Used as a type
)
load(":cxx_context.bzl", "get_cxx_toolchain_info")

# Provider that exposes the compilation database information
CxxCompilationDbInfo = provider(fields = [
    "info",  # A map of the file (an `Artifact`) to its corresponding `CxxSrcCompileCommand`
    "platform",  # platform for this compilation database
    "toolchain",  # toolchain for this compilation database
])

def make_compilation_db_info(src_compile_cmds: list[CxxSrcCompileCommand], toolchainInfo: CxxToolchainInfo, platformInfo: CxxPlatformInfo) -> CxxCompilationDbInfo:
    info = {}
    for src_compile_cmd in src_compile_cmds:
        info.update({src_compile_cmd.src: src_compile_cmd})

    return CxxCompilationDbInfo(info = info, toolchain = toolchainInfo, platform = platformInfo)

def create_compilation_database(
        ctx: AnalysisContext,
        src_compile_cmds: list[CxxSrcCompileCommand],
        indentifier: str) -> DefaultInfo:
    mk_comp_db = get_cxx_toolchain_info(ctx).mk_comp_db[RunInfo]

    # Generate the per-source compilation DB entries.
    entries = {}
    other_outputs = []

    for src_compile_cmd in src_compile_cmds:
        cdb_path = paths.join(indentifier, "__comp_db__", src_compile_cmd.src.short_path + ".comp_db.json")
        if cdb_path not in entries:
            entry = ctx.actions.declare_output(cdb_path)
            cmd = cmd_args(mk_comp_db)
            cmd.add("gen")
            cmd.add(cmd_args(entry.as_output(), format = "--output={}"))
            cmd.add(src_compile_cmd.src.basename)
            cmd.add(cmd_args(src_compile_cmd.src).parent())
            cmd.add("--")
            cmd.add(src_compile_cmd.cxx_compile_cmd.base_compile_cmd)
            cmd.add(src_compile_cmd.cxx_compile_cmd.argsfile.cmd_form)
            cmd.add(src_compile_cmd.args)
            entry_identifier = paths.join(indentifier, src_compile_cmd.src.short_path)
            ctx.actions.run(cmd, category = "cxx_compilation_database", identifier = entry_identifier)

            # Add all inputs the command uses to runtime files.
            other_outputs.append(cmd)
            entries[cdb_path] = entry

    content = cmd_args()
    for v in entries.values():
        content.add(v)

    argfile = ctx.actions.declare_output(paths.join(indentifier, "comp_db.argsfile"))
    ctx.actions.write(argfile.as_output(), content)

    # Merge all entries into the actual compilation DB.
    db = ctx.actions.declare_output(paths.join(indentifier, "compile_commands.json"))
    cmd = cmd_args(mk_comp_db)
    cmd.add("merge")
    cmd.add(cmd_args(db.as_output(), format = "--output={}"))
    cmd.add(cmd_args(argfile, format = "@{}"))
    cmd.hidden(entries.values())
    ctx.actions.run(cmd, category = "cxx_compilation_database_merge", identifier = indentifier)

    return DefaultInfo(default_output = db, other_outputs = other_outputs)
