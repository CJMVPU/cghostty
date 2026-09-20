# Application translations

This directory retains translations for shared command descriptions. The macOS
native UI is maintained separately in `macos/`; this is not a GTK localization
pipeline. The gettext domain is `com.cjmvpu.cghostty`.

Run `zig build update-translations` to refresh the template and catalogs using
gettext. Do not restore upstream community automation or GTK source extraction.
The generator extracts the command palette directly and drops obsolete entries
after merging. Existing translations and translator credits remain intact;
removed UI strings remain available in Git history.
