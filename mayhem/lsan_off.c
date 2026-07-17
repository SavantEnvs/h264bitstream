/*
 * lsan_off.c — the sanctioned build-time LeakSanitizer off-switch (SPEC §6.2 item 15).
 *
 * -fsanitize=address always bundles LeakSanitizer; this hook turns off ONLY the leak check.
 * ASan's memory-error detection and UBSan stay fully active. Leaks are not the bug class this
 * target fuzzes for, and libFuzzer's persistent mode reports a leak on any code path that skips
 * a free, so without the hook leak reports crowd out the memory-safety defects. build.sh links it
 * into the fuzz target and the standalone reproducer, so both share the same runtime config.
 */
int __lsan_is_turned_off(void)
{
  return 1;
}
