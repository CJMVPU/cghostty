% CGHOSTTY(5) Version @@VERSION@@ | cghostty terminal emulator configuration file

# NAME

**cghostty** - cghostty terminal emulator configuration file

# DESCRIPTION

Configure cghostty in the Settings window (Cmd+,). The application saves settings
to `$HOME/Library/Application Support/com.cjmvpu.cghostty/Settings/settings.json`.
Restart cghostty after saving to apply the changes. Debug builds use
`com.cjmvpu.cghostty.debug` instead of `com.cjmvpu.cghostty`.

On the first launch without stored settings, the application imports the old
`$HOME/Library/Application Support/com.cjmvpu.cghostty/config.ghostty` file and its
referenced configuration files. The import leaves those files unchanged;
subsequent launches use the stored settings. XDG configuration directories are
not searched.

Explicit command-line configuration files (`--config-file=/absolute/path/file`)
and theme files continue to use the `key = value` syntax below. These examples
describe that text format, not the application's settings JSON:

    # The syntax is "key = value". The whitespace around the equals doesn't matter.
    background = 282c34
    foreground= ffffff

    # Blank lines are ignored!

    keybind = ctrl+z=close_surface
    keybind = ctrl+d=new_split:right

Theme files can set any of the 256 indexed colors in `palette`. The first 16
entries contain eight regular and eight bright colors, illustrated below.
The `palette` key is only accepted in theme files:

    # The first 16 palette entries define the regular and bright ANSI colors.
    #
    # black
    palette = 0=#1d2021
    palette = 8=#7c6f64
    # red
    palette = 1=#cc241d
    palette = 9=#fb4934
    # green
    palette = 2=#98971a
    palette = 10=#b8bb26
    # yellow
    palette = 3=#d79921
    palette = 11=#fabd2f
    # blue
    palette = 4=#458588
    palette = 12=#83a598
    # purple
    palette = 5=#b16286
    palette = 13=#d3869b
    # aqua
    palette = 6=#689d6a
    palette = 14=#8ec07c
    # white
    palette = 7=#a89984
    palette = 15=#fbf1c7

You can view all available configuration options and their documentation by
executing the command `cghostty +show-config --default --docs`. Note that this will
output the full default configuration with docs to stdout, so you may want to
pipe that through a pager, an editor, etc.

Note: You'll see a lot of weird blank configurations like `font-family =`. This
is a valid syntax to specify the default behavior (no value). The `+show-config`
outputs it so it's clear that key is defaulting and also to have something to
attach the doc comment to.

You can also see and read all available configuration options in the source
Config structure. The available keys are the keys verbatim, and their possible
values are typically documented in the comments. You also can search for
public Ghostty configuration files for compatible examples and inspiration.

## Configuration Errors

The Settings window validates changes before saving. If stored settings cannot
be loaded, cghostty reports the problem and attempts to recover the previous
valid settings. Errors in explicitly loaded text configuration files are
reported as configuration diagnostics.

## Debugging Configuration

You can verify that configuration is being properly loaded by looking at the
debug output of cghostty.

In the debug output, you should see in the first 20 lines or so messages about
loading (or not loading) a configuration file, as well as any errors it may have
encountered. Configuration errors are also shown in a dedicated window.
cghostty does not treat configuration errors as fatal and
will fall back to default values for erroneous keys.

You can also view the full configuration cghostty is loading using `cghostty
+show-config` from the command-line. Use the `--help` flag to see additional options
for that command.

## Logging

cghostty can write logs to `stderr` and the macOS unified log. Unified logging
is enabled by default. Use the system `log` CLI to view release-build logs:

    log stream --level debug --predicate 'subsystem=="com.cjmvpu.cghostty"'

For Debug builds, use the subsystem `com.cjmvpu.cghostty.debug`.

cghostty's logging can be configured in two ways. The first is by what
optimization level cghostty is compiled with. If cghostty is compiled with `Debug`
optimizations debug logs will be output to `stderr`. If cghostty is compiled with
any other optimization the debug logs will not be output to `stderr`.

cghostty also checks the `CGHOSTTY_LOG` environment variable. It can be used
to control which destinations receive logs. cghostty currently defines two
destinations:

- `stderr` - logging to `stderr`.
- `macos` - logging to macOS's unified log.

Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `CGHOSTTY_LOG` to `true` will enable all
destinations. Setting `CGHOSTTY_LOG` to `false` will disable all destinations.
