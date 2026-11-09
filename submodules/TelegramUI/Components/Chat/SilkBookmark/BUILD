load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SilkBookmark",
    module_name = "SilkBookmark",
    srcs = glob(["Sources/**/*.swift"]),
    copts = [
        "-O",
        "-warnings-as-errors",
    ],
    deps = [],
    visibility = ["//visibility:public"],
)
