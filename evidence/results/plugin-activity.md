# Plugin activity in the agent runs

Captured by scripts/05-plugin-activity.py against real session logs.
These are the two dsh plugins we wrote; this is what they did.

## t3 — 27-file security review at 40,960 (the trim-heavy case)
```
session: /home/gwang/bonsai2-suite-ft/mtp1-40k/t3-notl-home
events : 220

=== trim (context-trim plugin) ===
  span elisions : 11
     1. shadowed=[29]  freed=2826 tokens
     2. shadowed=[30]  freed=5664 tokens
     3. shadowed=[37]  freed=4236 tokens
     4. shadowed=[50]  freed=2597 tokens
     5. shadowed=[51]  freed=2431 tokens
     6. shadowed=[62]  freed=2116 tokens
     7. shadowed=[63]  freed=6833 tokens
     8. shadowed=[82]  freed=2844 tokens
     9. shadowed=[124]  freed=2109 tokens
    10. shadowed=[142]  freed=2106 tokens
    11. shadowed=[159]  freed=3027 tokens
  total freed   : 36,789 tokens
  NOTE: 0 elisions is normal if the window had enough room --
        it means the context never hit the wall, not that trim is broken.

=== repeat detector (repeat-tool-breaker plugin) ===
  advisories    : 0
  hard blocks   : 0

=== compaction health ===
  ran    : 15
  failed : 2
    ERR: summary is not smaller than the shadowed content (1822 estimated framed tokens >= 1806)
    ERR: summary is not smaller than the shadowed content (2624 estimated framed tokens >= 2624)

=== tool use ===
  calls  : 31  {'bash': 2, 'read': 25, 'grep': 4}

=== outcome ===
  turn/end: {"turn": 1, "reason": {"kind": "completed"}}
```

## t5 — research task at 40,960 (completed, 46 tool calls)
```
session: /home/gwang/bonsai2-suite-ft/mtp1-40k/t5-home
events : 287

=== trim (context-trim plugin) ===
  span elisions : 4
     1. shadowed=[83]  freed=12512 tokens
     2. shadowed=[237]  freed=12510 tokens
     3. shadowed=[246]  freed=12510 tokens
     4. shadowed=[262]  freed=12510 tokens
  total freed   : 50,042 tokens
  NOTE: 0 elisions is normal if the window had enough room --
        it means the context never hit the wall, not that trim is broken.

=== repeat detector (repeat-tool-breaker plugin) ===
  advisories    : 0
  hard blocks   : 0

=== compaction health ===
  ran    : 6
  failed : 0

=== tool use ===
  calls  : 46  {'bash': 44, 'web_search_pro': 1, 'todo_write': 1}

=== outcome ===
  turn/end: {"turn": 1, "reason": {"kind": "completed"}}
```

## t5 — an earlier run where the guard DID fire

Same task, and here the model fixated on one host. The guard named it at
exactly the configured threshold (warnAt: 7).
```
=== repeat detector (repeat-tool-breaker plugin) ===
  advisories    : 1
    CONVERGENCE_CHECK: you are repeating yourself — host:archive-api.open-meteo.com has come up 7 times 
      -> fingerprint=host:archive-api.open-meteo.com  count=7
  hard blocks   : 0
```
