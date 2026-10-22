# Slots for your own scripts

A script that runs heavy work itself, outside `lanes-job run`, can hold a slot in the same pools, so it counts against
the same machine-wide limit.

```bash
lanes-job slot acquire <pool> [--pid <n>]   # prints the slot number it took; exit 75 when the pool is full
lanes-job slot release <pool> [--pid <n>]   # frees it; exit 0 even when that pid holds no slot
```

The holder is the pid (default: the calling shell). A lock whose process is gone is reclaimed by the next caller, so a
script that dies without releasing does not hold its slot forever.
