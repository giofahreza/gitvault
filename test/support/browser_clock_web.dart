// ignore_for_file: deprecated_member_use
import 'dart:js' as js;

/// Override only the isolated test page's wall clock, leaving timers intact.
void setBrowserClockOffset(Duration offset) {
  js.context.callMethod('eval', [
    '''
    (() => {
      const original = globalThis.__gitvaultTestDate || globalThis.Date;
      if (${offset.inMilliseconds} === 0) {
        globalThis.Date = original;
        delete globalThis.__gitvaultTestDate;
        return;
      }
      globalThis.__gitvaultTestDate = original;
      globalThis.Date = class extends original {
        constructor(...args) {
          super(...(args.length ? args : [original.now() + ${offset.inMilliseconds}]));
        }
        static now() { return original.now() + ${offset.inMilliseconds}; }
      };
    })()
  '''
  ]);
}
