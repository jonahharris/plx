/* plx 1.2.1 -> 1.2.2: no catalog changes.
 *
 * 1.2.2 is a code-only patch release (the loadable module, $libdir/plx): it lets
 * plxphp assign to a record field with the arrow form ($NEW->col = e) in a
 * trigger. None of this changes the SQL objects the extension defines, so this
 * update script only advances the recorded version. Installing the matching
 * $libdir/plx is what delivers the fix. */
