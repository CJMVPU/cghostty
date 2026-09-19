#!/usr/bin/env nu

# Build the Apple Silicon cghostty app. Internal Swift module/scheme names
# remain Ghostty so the C bridge and existing tests keep a stable interface.
def main [
    --configuration: string = "Debug"
    --action: string = "build"
    --version: string = ""
    --skip-core
] {
    if (^uname -s | str trim) != "Darwin" or (^uname -m | str trim) != "arm64" {
        error make {msg: "cghostty builds require an Apple Silicon Mac (arm64)."}
    }
    if ((^sw_vers -productVersion | str trim | split row "." | first | into int) < 27) {
        error make {msg: "cghostty requires macOS 27 or newer to build and run."}
    }
    if $configuration not-in [Debug ReleaseLocal Release] {
        error make {msg: "Configuration must be Debug, ReleaseLocal, or Release."}
    }
    if $action not-in [build test clean] {
        error make {msg: "Action must be build, test, or clean."}
    }
    let root = ($env.FILE_PWD | path dirname)
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")
    let app_version = if $version == "" {
        open --raw ($root | path join "build.zig.zon")
            | parse --regex '\.version = "(?P<version>[^"]+)"'
            | get version.0
    } else { $version }
    let marketing_version = ($app_version | split row "-" | first | split row "+" | first)
    let optimize = if $configuration == "Debug" { "Debug" } else { "ReleaseFast" }
    if not $skip_core and $action != "clean" {
        cd $root
        ^zig build -Demit-macos-app=false $"-Doptimize=($optimize)" $"-Dversion-string=($app_version)"
        if $env.LAST_EXIT_CODE != 0 { exit $env.LAST_EXIT_CODE }
    }
    let skip_testing = if $action == "test" { [-skip-testing GhosttyUITests] } else { [] }
    (^env -i $"HOME=($env.HOME)" "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild -project $project -scheme Ghostty -configuration $configuration
        -destination "platform=macOS,arch=arm64"
        -derivedDataPath ($build_dir | path join "DerivedData")
        $"SYMROOT=($build_dir)" "ARCHS=arm64" "ONLY_ACTIVE_ARCH=YES"
        $"MARKETING_VERSION=($marketing_version)" $"CGHOSTTY_VERSION=($app_version)" ...$skip_testing $action)
    if $env.LAST_EXIT_CODE != 0 { exit $env.LAST_EXIT_CODE }
}
