# SPK286 Microcode

The authoritative microcode format is the project-owned `.mc` DSL described by
`SPK286_MICROCODE_FORMAT.md`. Phase 0 reserves this area but does not implement
the compiler or CPU microsequencer. Generated ROM files must be reproducible
and must not be edited by hand when the compiler is introduced.

The first microcode milestone is intentionally deferred until the architectural
state, fetch boundary, and test adapter contracts are established in Phase 1.
