/* plx 1.1 -> 1.1.1: no catalog changes.
 *
 * 1.1.1 is a code-only patch release (the loadable module, $libdir/plx): it
 * restores compilation on PostgreSQL 13-15 (a guarded varatt.h include), fixes a
 * plxcobol crash on truncated input and several plxcobol parsing bugs. None of
 * these change the SQL objects the extension defines, so this update script only
 * advances the recorded version. Installing the matching $libdir/plx is what
 * delivers the fixes. */
