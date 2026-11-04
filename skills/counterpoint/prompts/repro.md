
## Repro: make blocker and major bugs executable

For a blocker or major finding whose bug shows when code runs (wrong output, crash, accepted bad input, broken edge case), add a "repro": a small self-contained test that demonstrates it. Every other finding (minor ones, docs, prose, analyses, anything not runnable) has "repro": null. Do not stretch: a repro that cannot fail for the right reason is worse than none.

- "file": a new file name (e.g. "repro_f1.py", "repro_f1.sh"). It is placed in the project root of a throwaway copy of the code you reviewed, so it can import or call the project's files by their relative paths.
- "content": the test. It must print exactly `COUNTERPOINT-REPRO: FAIL` and exit 1 while the bug is present, and print exactly `COUNTERPOINT-REPRO: PASS` and exit 0 once it is fixed. Anything else (a crash, a missing tool) counts as inconclusive, not as proof.
- "command": the shell command that runs it from that root; the test's path is in $REPRO (e.g. `python3 "$REPRO"`, `bash "$REPRO"`, `node "$REPRO"`).
- Use only what the project and a standard system already have: no installs, no network, no writes outside $TMPDIR, done in under 30 seconds.
- No repro when the bug only shows against state you cannot build in a temp directory: a real database and its applied migrations, a remote service, credentials, production data. A test that fakes that state badly fails after a correct fix and wastes the author's time. Set "repro" to null and start "evidence" with "Needs a live check:" followed by the query or step that shows it. The project facts, when given, say what a test can rely on.
