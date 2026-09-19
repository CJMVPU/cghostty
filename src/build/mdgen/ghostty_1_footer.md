# FILES

_\$XDG_CONFIG_HOME/cghostty/config.ghostty_

: Location of the default configuration file.

_\$HOME/Library/Application Support/com.cjmvpu.cghostty/config.ghostty_

: **On macOS**, location of the default configuration file. This location takes
precedence over the XDG environment locations.


# ENVIRONMENT

**TERM**

: Defaults to `xterm-ghostty`. Can be configured with the `term` configuration option.

**CGHOSTTY_RESOURCES_DIR**

: Where the Ghostty resources can be found.

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/com.cjmvpu.cghostty**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.


**CGHOSTTY_LOG**

: The `CGHOSTTY_LOG` environment variable can be used to control which
destinations receive logs. Ghostty currently defines two destinations:

: - `stderr` - logging to `stderr`.
: - `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

: Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `CGHOSTTY_LOG` to `true` will enable all
destinations. Setting `CGHOSTTY_LOG` to `false` will disable all destinations.

# BUGS

See GitHub issues: <https://github.com/CJMVPU/cghostty/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
Ghostty contributors <https://github.com/ghostty-org/ghostty/graphs/contributors>

# SEE ALSO

**cghostty(5)**
