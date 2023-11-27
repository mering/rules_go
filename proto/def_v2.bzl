# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "//go:def.bzl",
    "GoArchive",
    "GoLibrary",
    "GoSource",
    "go_context",
)
load(
    "//proto:compiler.bzl",
    "GoProtoCompiler",
    "proto_path",
)
load(
    "//go/private:common.bzl",
    "GO_TOOLCHAIN",
)
load(
    "@rules_proto//proto:defs.bzl",
    "ProtoInfo",
)
load(
    "//go/private:providers.bzl",
    "GoProtoInfo",
)

GoProtoImports = provider()

def get_imports(target, attr, importpath):
    direct = dict()
    for src in target[ProtoInfo].check_deps_sources.to_list():
        direct["{}={}".format(proto_path(src, target[ProtoInfo]), importpath)] = True

    transitive = [
        dep[GoProtoImports].imports
        for dep in getattr(attr, "deps", [])
        if GoProtoImports in dep
    ]
    return depset(direct = direct.keys(), transitive = transitive)

def _library_to_source(_go, attr, source, merge):
    compiler = attr._compiler
    if GoSource in compiler:
        merge(source, compiler[GoSource])

def _filter_deps(deps, embed):
    if embed == None:
        return deps

    return [dep for dep in deps if dep[GoLibrary].importpath not in embed[GoLibrary].importpath]

def _compile_proto(ctx, target, attr, library_kwargs = {}):
    go = go_context(ctx)
    go_srcs = []
    proto_info = target[ProtoInfo]
    imports = get_imports(target, attr, go.importpath)
    compiler = ctx.attr._compiler[GoProtoCompiler]
    if proto_info.direct_sources:
        go_srcs.extend(compiler.compile(
            go,
            compiler = compiler,
            protos = [proto_info],
            imports = imports,
            importpath = go.importpath,
        ))

    go_deps = getattr(attr, "deps", []) + compiler.deps
    library = go.new_library(
        go,
        resolver = _library_to_source,
        srcs = go_srcs,
        deps = _filter_deps(go_deps, library_kwargs.get("embed", None)),
        #importpath_aliases = tuple([go.importpath.replace("_proto", "_go_proto")]),
        **library_kwargs
    )
    print(ctx.label.name, library)
    source = go.library_to_source(go, ctx.attr, library, False)
    archive = go.archive(go, source)
    return {
        "imports": GoProtoImports(
            imports = imports,
        ),
        "info": GoProtoInfo(
            library = library,
            source = source,
            archive = archive,
        ),
    }

def _go_proto_aspect_impl(target, ctx):
    providers = _compile_proto(ctx, target, ctx.rule.attr)

    return [
        providers["imports"],
        providers["info"],
    ]

_go_proto_aspect = aspect(
    _go_proto_aspect_impl,
    attrs = {
        "_compiler": attr.label(
            default = "//proto:go_proto",
        ),
        "_go_context_data": attr.label(
            default = "//:go_context_data",
        ),
    },
    attr_aspects = [
        "deps",
    ],
    required_providers = [ProtoInfo],
    provides = [GoProtoImports, GoProtoInfo],
    toolchains = [GO_TOOLCHAIN],
)

def _go_proto_library_impl(ctx):
    if len(ctx.attr.protos) != 1:
        fail("'protos' attribute must contain exactly one element. Got %s." % len(ctx.attr.protos))
    proto = ctx.attr.protos[0]

    go = go_context(ctx)

    direct = dict()
    for src in proto[ProtoInfo].check_deps_sources.to_list():
        direct["{}={}".format(proto_path(src, proto[ProtoInfo]), go.importpath)] = True
    imports = depset(direct = direct.keys(), transitive = [proto[GoProtoImports].imports])

    library = go.new_library(
        go,
        embed = proto[GoProtoInfo].archive,
        importpath = proto[GoProtoInfo].library.importpath,
        importpath_aliases = tuple([
            go.importpath,
        ]),
    )
    source = go.library_to_source(go, ctx.attr, library, False)
    archive = go.archive(go, source)

    return [
        #proto[GoProtoImports],
        GoProtoImports(imports = imports),
        library,
        source,
        archive,
    ]

go_proto_library = rule(
    implementation = _go_proto_library_impl,
    attrs = {
        "protos": attr.label_list(
            providers = [ProtoInfo],
            aspects = [_go_proto_aspect],
            mandatory = True,
        ),
        "_go_context_data": attr.label(
            default = "//:go_context_data",
        ),
    },
    provides = [
        GoProtoImports,  # This is used by go_grpc_library to determine importpaths for proto deps
        GoLibrary,
        GoSource,
        GoArchive,
    ],
    toolchains = [GO_TOOLCHAIN],
)

def _go_grpc_library_impl(ctx):
    if len(ctx.attr.protos) != 1:
        fail("protos attribute must be exactly one target")
    proto = ctx.attr.protos[0]
    if len(ctx.attr.deps) != 1:
        fail("deps attribute must be exactly one target")
    dep = ctx.attr.deps[0]

    # TODO try to embed the aspect provider like in rules, embed of embed might have been the problem why previous trial didn't work
    go = go_context(ctx)
    library_kwargs = {
        "embed": dep,
        "importpath": dep[GoLibrary].importpath,
        "importpath_aliases": dep[GoLibrary].importpath_aliases + tuple([
            go.importpath,
        ]),
    }
    providers = _compile_proto(ctx, proto, ctx.attr, library_kwargs)

    return [
        providers["info"].library,
        providers["info"].source,
        providers["info"].archive,
    ]

go_grpc_library = rule(
    implementation = _go_grpc_library_impl,
    attrs = {
        "protos": attr.label_list(
            providers = [ProtoInfo],
            mandatory = True,
        ),
        "deps": attr.label_list(
            providers = [GoLibrary],
        ),
        "importpath": attr.string(),
        "_compiler": attr.label(
            default = "//proto:go_grpc",
        ),
        "_go_context_data": attr.label(
            default = "//:go_context_data",
        ),
    },
    provides = [
        GoLibrary,
        GoSource,
        GoArchive,
    ],
    toolchains = [GO_TOOLCHAIN],
)
