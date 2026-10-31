# AdaScript compiler and runtime

Source: https://github.com/AdaEngine/gravity-lang
Revision: `26f80cc250d478b16dbbd21a3a517a669d13f616`
License: MIT (`LICENSE`)

This directory contains the pinned `src`, `binding` and `tools` trees, the upstream README,
license, Makefile and CMake entry point. The SwiftPM manifest exposes the runtime/compiler
libraries and macro; upstream examples, development tools and test projects are omitted.
The C VM, AOT compiler, ABI and macro sources are unchanged.

The subset manifest accepts SwiftSyntax 602 and 603 so its macros can share the
compiler support selected by AdaEngine and the pinned Swan dependency.

Local Swift binding fixes:

- `GSValue.swift`: copy Swift strings with the C VM's allocator and count UTF-8 bytes.
- `GravityCompiler.swift`: pass the source's UTF-8 byte count to the C compiler.
- `GravityVirtualMachine+Bridge.swift`: imported files also report UTF-8 bytes.
- `GravityVirtualMachine.swift`: global symbol lookups use UTF-8 key length.
- `NativeModule.swift`: validate string/list lengths with a failable `UInt32`
  conversion. Converting `UInt32.max` to `Int` traps on 32-bit WASM, including
  ordinary host getters returning vectors, parameter names and parameter IDs.

Byte counts matter for both non-ASCII text and CRLF: Swift counts a CRLF pair as
one Character, while the C lexer consumes two bytes. The previous count truncated
Windows source files and Cyrillic text.

Local CMake build settings require C11 for the VM's atomic GC callbacks and
enable `/experimental:c11atomics` when compiling with MSVC.

`ADAENGINE_GRAVITY_PACKAGE_PATH` still selects an external development checkout.
Changes here must preserve the pinned ABI and be verified through the real AdaScript
VM, AOT fixtures and engine integration tests.
