# FILES

_\$HOME/Library/Application Support/com.cjmvpu.cghostty/Settings/settings.json_

: Application-managed settings. Use Settings (Cmd+,) to edit them; restart after
saving. Debug builds use `com.cjmvpu.cghostty.debug` instead of `com.cjmvpu.cghostty`.

_\$HOME/Library/Application Support/com.cjmvpu.cghostty/config.ghostty_

: Legacy configuration imported on the first application launch without stored
settings, together with its referenced files. The import leaves the source files
unchanged; subsequent launches use the application-managed settings.


# ENVIRONMENT

**TERM**

: Defaults to `xterm-ghostty`. Can be configured with the `term` configuration option.

**CGHOSTTY_RESOURCES_DIR**

: Where the cghostty resources can be found.

**XDG_STATE_HOME**

: Base directory for the SSH terminfo cache; defaults to `$HOME/.local/state`.
This does not select a configuration directory.


**CGHOSTTY_LOG**

: The `CGHOSTTY_LOG` environment variable can be used to control which
destinations receive logs. cghostty currently defines two destinations:

: - `stderr` - logging to `stderr`.
: - `macos` - logging to macOS's unified log.

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
