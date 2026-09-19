# Translation catalogs

Edit the relevant `.po` catalog and validate it with `msgfmt --check`.
`com.cjmvpu.cghostty.pot` is generated from shared command descriptions by
`zig build update-translations`. Keep the original translator credits.

Building the app compiles catalogs into the cghostty gettext domain. This does
not automatically localize the native Swift UI.
