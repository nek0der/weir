// WeirRustBridge.swift
// Weir — Typed Swift access to the Rust core ABI boundary.

import WeirRustBridge

enum WeirRustRuntime {
    static var abiVersion: UInt32 {
        weir_rust_abi_version()
    }
}

enum WeirRustTitleResolver {
    /// The longest title the Rust core returns (`MAX_TITLE_BYTES` in
    /// `weir-agent-core`); the two sides check it against
    /// `rust/fixtures/contract/shared-values.json`.
    static let outputCapacity = 4096

    static func resolve(
        providerSessionTitle: String?,
        providerGeneratedTitle: String?,
        firstPrompt: String?
    ) -> String? {
        var output = [UInt8](repeating: 0, count: outputCapacity)
        var outputLength = 0

        let result = withOptionalUTF8(providerSessionTitle) { providerSessionPointer, providerSessionLength in
            withOptionalUTF8(providerGeneratedTitle) { providerGeneratedPointer, providerGeneratedLength in
                withOptionalUTF8(firstPrompt) { firstPromptPointer, firstPromptLength in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        weir_resolve_title_v1(
                            providerSessionPointer,
                            providerSessionLength,
                            providerGeneratedPointer,
                            providerGeneratedLength,
                            firstPromptPointer,
                            firstPromptLength,
                            outputBuffer.baseAddress,
                            outputBuffer.count,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard result == Int32(WEIR_TITLE_RESOLVE_OK.rawValue),
              outputLength <= output.count
        else { return nil }
        return String(bytes: output[..<outputLength], encoding: .utf8)
    }

    /// Lends `value`'s UTF-8 to one call, as a null pointer when there is
    /// none. Nothing crosses the boundary to free: Rust only reads the
    /// pointer while `body` runs and copies what it keeps, and it writes the
    /// title into `output`, our own buffer. A call that hands bytes out
    /// instead goes through `RustBytes`, which frees them.
    private static func withOptionalUTF8<Result>(
        _ value: String?,
        _ body: (UnsafePointer<UInt8>?, Int) -> Result
    ) -> Result {
        guard let value else { return body(nil, 0) }
        return Array(value.utf8).withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }
}
